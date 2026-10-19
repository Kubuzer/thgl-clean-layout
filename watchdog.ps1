# Opens TH.GL's own DevTools when necessary so WebView2 Local Overrides apply.
# Windows PowerShell 5.1; requires an interactive desktop session.
#requires -Version 5.1
param([switch]$Once)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -eq 'Core') {
    throw 'The watchdog requires Windows PowerShell 5.1 and an interactive Windows desktop.'
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ThglForeground {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@

$rootPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'THGL-Clean-Layout'
$logPath = Join-Path $rootPath 'watchdog.log'
$lastErrors = @{}
$refreshStates = @{}
$appProcessIds = @{}
$appIdentity = $null
$logStream = $null

function Log([string]$message) {
    # Logging failure must not terminate the watchdog. Keep one bounded archive.
    try {
        foreach ($path in @($logPath, ($logPath + '.1'))) {
            $cursor = $path
            while ($cursor) {
                try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
                catch [System.Management.Automation.ItemNotFoundException] { $item = $null }
                if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Log path contains a symbolic link or junction.'
                }
                $parent = [IO.Directory]::GetParent($cursor)
                $cursor = if ($parent) { $parent.FullName } else { $null }
            }
        }
        if ($logStream -and $logStream.Length -ge 2MB) {
            $logStream.Dispose()
            $script:logStream = $null
        }
        if (-not $logStream) {
            New-Item -ItemType Directory -Path $rootPath -Force -ErrorAction Stop | Out-Null
            # Never append to a pre-existing path: a hard link is not a reparse point.
            # Rename it without reading/writing its contents, then create a new file.
            if (Test-Path -LiteralPath $logPath) {
                foreach ($path in @($logPath, ($logPath + '.1'))) {
                    if (Test-Path -LiteralPath $path -PathType Container) { throw 'Expected a log file, not a directory.' }
                }
                if (Test-Path -LiteralPath ($logPath + '.1')) { [IO.File]::Delete($logPath + '.1') }
                [IO.File]::Move($logPath, ($logPath + '.1'))
            }
            $script:logStream = [IO.File]::Open($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)
        $logStream.Write($bytes, 0, $bytes.Length)
        $logStream.Flush()
    } catch {
        if ($logStream) {
            try { $logStream.Dispose() } catch { }
            $script:logStream = $null
        }
        Write-Warning "Watchdog logging failed: $($_.Exception.Message)"
    }
}
function LogRetry([string]$reason) {
    if (-not $lastErrors.ContainsKey($reason) -or ((Get-Date) - $lastErrors[$reason]).TotalMinutes -gt 10) {
        if ($lastErrors.Count -ge 128 -and -not $lastErrors.ContainsKey($reason)) {
            $oldest = $lastErrors.GetEnumerator() | Sort-Object Value | Select-Object -First 1
            $lastErrors.Remove($oldest.Key)
        }
        Log "Retrying: $reason"
        $lastErrors[$reason] = Get-Date
    }
}
function GetAppProcessIds($app) {
    $ids = @{}
    $ids[[int]$app.Id] = $true
    # WebView2 windows can belong to child processes rather than THGLApp itself.
    $processes = @(Get-CimInstance Win32_Process -Filter ("SessionId = " + [int]$app.SessionId) -ErrorAction Stop)
    do {
        $added = $false
        foreach ($process in $processes) {
            $childId = [int]$process.ProcessId
            if ($ids.ContainsKey([int]$process.ParentProcessId) -and -not $ids.ContainsKey($childId)) {
                $ids[$childId] = $true
                $added = $true
            }
        }
    } while ($added)
    return $ids
}
function Windows {
    foreach ($window in [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($appProcessIds.ContainsKey([int]$window.Current.ProcessId)) { $window }
    }
}
function FindControl($parent, [string]$name, $kind) {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    foreach ($item in $parent.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        if ($item.Current.ControlType -eq $kind) { return $item }
    }
    return $null
}
function FindDevTools([string]$path) {
    $pattern = '^DevTools - app\.th\.gl/' + [regex]::Escape($path) + '/?(?:[?#].*| - .*)?$'
    foreach ($window in (Windows)) {
        if ($window.Current.Name -match $pattern) { return $window }
    }
    return $null
}
function OpenAndRefresh([string]$buttonName, [string]$path, $main) {
    # A previous attempt may have opened DevTools before its Console was ready.
    $dev = FindDevTools $path
    if (-not $dev) {
        $buttonType = [System.Windows.Automation.ControlType]::Button
        $button = FindControl $main $buttonName $buttonType
        if (-not $button) {
            $settings = FindControl $main 'Settings' ([System.Windows.Automation.ControlType]::Hyperlink)
            if ($settings) {
                $settings.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Start-Sleep -Milliseconds 400
                $button = FindControl $main $buttonName $buttonType
            }
        }
        if (-not $button) {
            $developer = FindControl $main 'Developer Tools' $buttonType
            if ($developer) {
                $developer.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Start-Sleep -Milliseconds 400
                $button = FindControl $main $buttonName $buttonType
            }
        }
        if (-not $button) { throw "TH.GL Developer Tools button unavailable: $buttonName" }
        $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 300
            $dev = FindDevTools $path
            if ($dev) { break }
        }
        if (-not $dev) { throw "DevTools did not open: $path" }
    }

    $windowPattern = $dev.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
    try {
        $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
        if (-not [ThglForeground]::SetForegroundWindow([IntPtr]$dev.Current.NativeWindowHandle)) {
            throw 'DevTools did not receive foreground focus'
        }
        Start-Sleep -Milliseconds 150
        $tab = FindControl $dev 'Console' ([System.Windows.Automation.ControlType]::TabItem)
        if (-not $tab) { throw 'Console tab not found' }
        $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Milliseconds 180
        $prompt = FindControl $dev 'Console prompt' ([System.Windows.Automation.ControlType]::Edit)
        if (-not $prompt) { throw 'Console prompt not found' }
        $prompt.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('location.reload()')
        $prompt.SetFocus()
        Start-Sleep -Milliseconds 150
        if ([ThglForeground]::GetForegroundWindow() -ne [IntPtr]$dev.Current.NativeWindowHandle -or
            -not [System.Windows.Automation.AutomationElement]::Compare(
                [System.Windows.Automation.AutomationElement]::FocusedElement, $prompt)) {
            throw 'Console did not retain focus'
        }
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Log "Refreshed $path"
    } finally {
        try { $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Minimized) }
        catch { Log "Could not minimize $($path): $($_.Exception.Message)" }
    }
    return $dev.Current.NativeWindowHandle
}
function EnsureView([string]$buttonName, [string]$path, $main) {
    $dev = FindDevTools $path
    $state = $refreshStates[$path]
    # Preserve already-open windows on startup; retry only work this watchdog began.
    if ($dev -and -not $state) { return }
    if ($state -and $state.Ready -and $dev -and $state.Handle -eq $dev.Current.NativeWindowHandle) { return }
    if (-not $state -or $state.Ready) {
        $state = @{Ready=$false; Handle=0; Failures=0; NextAttempt=[DateTime]::MinValue}
        $refreshStates[$path] = $state
    }
    if ((Get-Date) -lt $state.NextAttempt) { return }
    try {
        $state.Handle = OpenAndRefresh $buttonName $path $main
        $state.Ready = $true
        $state.Failures = 0
    } catch {
        $state.Failures++
        $delay = [Math]::Min(60, 7 * [Math]::Pow(2, [Math]::Min($state.Failures - 1, 4)))
        $state.NextAttempt = (Get-Date).AddSeconds($delay)
        LogRetry "$($path): $($_.Exception.Message)"
    }
}
function Tick {
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $app = Get-Process THGLApp -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId -and $_.MainWindowHandle -ne [IntPtr]::Zero } |
        Select-Object -First 1
    if (-not $app) {
        $script:refreshStates = @{}
        $script:appIdentity = $null
        $script:appProcessIds = @{}
        return
    }
    $identity = [string]$app.Id + ':' + $app.StartTime.Ticks
    if ($appIdentity -ne $identity) {
        $script:refreshStates = @{}
        $script:appIdentity = $identity
    }
    $script:appProcessIds = GetAppProcessIds $app

    $overlayPresent = $false
    foreach ($window in (Windows)) {
        $name = $window.Current.Name
        if ($name -like '*AION 2 Interactive Map - The Hidden Gaming Lair*' -or
            $name -eq 'THGL Overlay') {
            $overlayPresent = $true
            break
        }
    }
    $main = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
    EnsureView 'dashboard' 'dashboard' $main
    if ($overlayPresent) { EnsureView 'aion2 (overlay)' 'apps/aion2/overlay' $main }
}

try {
    Log "Watchdog started (Once=$Once)"
    do {
        try { Tick } catch { LogRetry $_.Exception.Message }
        if (-not $Once) { Start-Sleep -Seconds 7 }
    } while (-not $Once)
} finally {
    if ($logStream) { $logStream.Dispose() }
}
