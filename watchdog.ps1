# Applies Local Overrides, confirms the loaded CSS, then closes TH.GL DevTools.
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
    $route = if ($path -eq 'dashboard') { 'dashboard(?:/[^?#\s]*)?' } else { [regex]::Escape($path) + '/?' }
    $pattern = '^DevTools - app\.th\.gl/' + $route + '(?:[?#].*| - .*)?$'
    foreach ($window in (Windows)) {
        if ($window.Current.Name -match $pattern) { return $window }
    }
    return $null
}
function SendConsoleCommand($dev, [string]$command, $reloadState = $null) {
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
    $prompt.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($command)
    $prompt.SetFocus()
    Start-Sleep -Milliseconds 150
    if ([ThglForeground]::GetForegroundWindow() -ne [IntPtr]$dev.Current.NativeWindowHandle -or
        -not [System.Windows.Automation.Automation]::Compare(
            [System.Windows.Automation.AutomationElement]::FocusedElement, $prompt)) {
        throw 'Console did not retain focus'
    }
    # Only the guarded dispatch can become ambiguous; setup failures remain retryable.
    if ($reloadState) { $reloadState.ReloadRequested = $true }
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
}
function WaitConsoleText($dev, [string]$token) {
    for ($i = 0; $i -lt 20; $i++) {
        # Exact output text differs from the Console's quoted command echo.
        if (FindControl $dev $token ([System.Windows.Automation.ControlType]::Text)) { return }
        Start-Sleep -Milliseconds 300
    }
    throw 'Console confirmation not received; DevTools left open'
}
function OpenAndRefresh([string]$buttonName, [string]$path, $main, $state) {
    # A previous attempt may have opened DevTools before its Console was ready.
    $dev = FindDevTools $path
    if (-not $dev) {
        $mainPattern = $main.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        $mainPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
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
    $devHandle = $dev.Current.NativeWindowHandle
    $closed = $false
    try {
        $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
        if (-not $state.ReloadRequested) {
            $state.DocumentToken = [Guid]::NewGuid().ToString('N')
            $armed = 'THGL_ARM_' + $state.DocumentToken
            SendConsoleCommand $dev ("window.__thglCleanLayoutDocument='" + $state.DocumentToken + "';console.info('" + $armed + "')")
            WaitConsoleText $dev $armed
            SendConsoleCommand $dev 'location.reload()' $state
            Log "Reload requested $path"
        }
        $ack = 'THGL_CSS_' + [Guid]::NewGuid().ToString('N')
        $probe = "(()=>{let n=0;const t=setInterval(()=>{if(document.readyState==='complete'&&window.__thglCleanLayoutDocument!=='" +
            $state.DocumentToken + "'&&getComputedStyle(document.documentElement).getPropertyValue('--thgl-clean-layout').trim()==='1'){clearInterval(t);console.info('" +
            $ack + "');}else if(++n>=50){clearInterval(t);}},100);})()"
        SendConsoleCommand $dev $probe
        WaitConsoleText $dev $ack
        $state.CssConfirmed = $true
        $windowPattern.Close()
        for ($i = 0; $i -lt 20; $i++) {
            $remaining = @((Windows) | Where-Object { $_.Current.NativeWindowHandle -eq $devHandle })
            if ($remaining.Count -eq 0) { $closed = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $closed) { throw 'DevTools did not close' }
        Log "CSS confirmed; closed DevTools $path"
    } finally {
        if (-not $closed) {
            try { $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Minimized) }
            catch { Log "Could not minimize $($path): $($_.Exception.Message)" }
        }
    }
}
function EnsureView([string]$buttonName, [string]$path, $main, [long]$viewHandle) {
    $dev = FindDevTools $path
    $state = $refreshStates[$path]
    if (-not $state -or $state.ViewHandle -ne $viewHandle) {
        $state = @{Ready=$false; ViewHandle=$viewHandle; ReloadRequested=$false; CssConfirmed=$false; DocumentToken=$null; Failures=0; NextAttempt=[DateTime]::MinValue}
        $refreshStates[$path] = $state
    }
    # Reconcile an intentional close, including a close whose acknowledgement failed.
    if ($state.CssConfirmed -and -not $dev) { $state.Ready = $true; return }
    if ((Get-Date) -lt $state.NextAttempt) { return }
    try {
        OpenAndRefresh $buttonName $path $main $state
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

    $overlay = $null
    foreach ($window in (Windows)) {
        $name = $window.Current.Name
        if ($name -like '*AION 2 Interactive Map - The Hidden Gaming Lair*' -or
            $name -eq 'THGL Overlay') {
            $overlay = $window
            break
        }
    }
    $main = @((Windows) | Where-Object { $_.Current.ProcessId -eq $app.Id -and $_.Current.Name -eq 'The Hidden Gaming Lair' })
    if ($main.Count -ne 1) { return }
    EnsureView 'dashboard' 'dashboard' $main[0] $main[0].Current.NativeWindowHandle
    if ($overlay) { EnsureView 'aion2 (overlay)' 'apps/aion2/overlay' $main[0] $overlay.Current.NativeWindowHandle }
}

try {
    Log "Watchdog started (Once=$Once)"
    do {
        try { Tick } catch { LogRetry $_.Exception.Message }
        if (-not $Once) { Start-Sleep -Seconds 2 }
    } while (-not $Once)
} finally {
    if ($logStream) { $logStream.Dispose() }
}
