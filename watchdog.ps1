# Opens TH.GL's own DevTools when necessary so WebView2 Local Overrides apply.
# Windows PowerShell 5.1; requires an interactive desktop session.
param([switch]$Once)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ThglForeground {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@

$rootPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'THGL-Clean-Layout'
$logPath = Join-Path $rootPath 'watchdog.log'
$lastErrors = @{}

function Log([string]$message) {
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $message)
}
function Windows {
    [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
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
    foreach ($window in (Windows)) {
        if ($window.Current.Name -like "DevTools - app.th.gl/$path*") { return $window }
    }
    return $null
}
function OpenAndRefresh([string]$buttonName, [string]$path, $main) {
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

    $dev = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        $dev = FindDevTools $path
        if ($dev) { break }
    }
    if (-not $dev) { throw "DevTools did not open: $path" }

    $windowPattern = $dev.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
    try {
        $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
        [void][ThglForeground]::SetForegroundWindow([IntPtr]$dev.Current.NativeWindowHandle)
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
        if ([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -ne 'Console prompt') {
            throw 'Console did not receive focus'
        }
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Log "Refreshed $path"
    } catch {
        Log "Refresh skipped ($path): $($_.Exception.Message)"
    } finally {
        $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Minimized)
    }
    Log "Opened and minimized $path"
}
function Tick {
    $app = Get-Process THGLApp -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $app -or $app.MainWindowHandle -eq [IntPtr]::Zero) { return }

    $dashboardMissing = -not (FindDevTools 'dashboard')
    $overlayPresent = $false
    foreach ($window in (Windows)) {
        $name = $window.Current.Name
        if ($name -like '*AION 2 Interactive Map - The Hidden Gaming Lair*' -or
            $name -eq 'THGL Overlay') {
            $overlayPresent = $true
            break
        }
    }
    $overlayMissing = $overlayPresent -and -not (FindDevTools 'apps/aion2/overlay')
    if (-not $dashboardMissing -and -not $overlayMissing) { return }

    $main = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
    if ($dashboardMissing) { OpenAndRefresh 'dashboard' 'dashboard' $main }
    if ($overlayMissing) { OpenAndRefresh 'aion2 (overlay)' 'apps/aion2/overlay' $main }
}

if (-not (Test-Path -LiteralPath $rootPath)) { New-Item -ItemType Directory -Path $rootPath -Force | Out-Null }
Log "Watchdog started (Once=$Once)"
do {
    try { Tick } catch {
        $reason = $_.Exception.Message
        if (-not $lastErrors.ContainsKey($reason) -or ((Get-Date) - $lastErrors[$reason]).TotalMinutes -gt 10) {
            Log "Retrying: $reason"
            $lastErrors[$reason] = Get-Date
        }
    }
    if (-not $Once) { Start-Sleep -Seconds 7 }
} while (-not $Once)
