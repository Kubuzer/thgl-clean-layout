# Logic regression tests with inert UI APIs; no real windows or keys are touched.
# Production logic is unchanged; UI namespaces are redirected to inert fixtures.
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
namespace THGLTest.Automation {
  public static class ControlType {
    public static readonly object Button = "Button", Hyperlink = "Hyperlink", TabItem = "TabItem", Edit = "Edit";
  }
  public static class InvokePattern { public static readonly object Pattern = "Invoke"; }
  public static class WindowPattern { public static readonly object Pattern = "Window"; }
  public static class SelectionItemPattern { public static readonly object Pattern = "Selection"; }
  public static class ValuePattern { public static readonly object Pattern = "Value"; }
  public enum WindowVisualState { Normal, Minimized }
  public enum TreeScope { Children, Descendants }
  public static class Condition { public static readonly object TrueCondition = new object(); }
  public static class AutomationElement {
    public static object RootElement, FocusedElement;
    public static object FromHandle(IntPtr h) { return new object(); }
  }
  public static class Automation {
    public static bool Compare(object a, object b) { return object.ReferenceEquals(a,b); }
  }
}
namespace THGLTest.Forms {
  public static class SendKeys {
    public static int Calls;
    public static void SendWait(string value) { Calls++; }
  }
}
public static class ThglForeground {
  public static bool KeepFocus = true;
  public static IntPtr Foreground;
  public static bool SetForegroundWindow(IntPtr h) { Foreground = KeepFocus ? h : IntPtr.Zero; return true; }
  public static IntPtr GetForegroundWindow() { return Foreground; }
}
'@

$repository = Split-Path -Parent $PSScriptRoot
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'watchdog.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions = $ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)
foreach ($name in @('LogRetry', 'GetAppProcessIds', 'Windows', 'FindDevTools', 'OpenAndRefresh', 'EnsureView', 'Tick')) {
    $definition = $definitions | Where-Object Name -eq $name
    $body = $definition.Extent.Text.Replace('[System.Windows.Automation.', '[THGLTest.Automation.').Replace('[System.Windows.Forms.', '[THGLTest.Forms.')
    . ([scriptblock]::Create($body))
}
$checks = 0
function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function ResetFixture {
    $script:refreshStates = @{}; $script:lastErrors = @{}; $script:appProcessIds = @{}
    $script:appIdentity = $null
    $script:windows = [Collections.Generic.List[object]]::new()
    $script:messages = [Collections.Generic.List[string]]::new()
    $script:ready = @{'dashboard'=$false; 'apps/aion2/overlay'=$true}
    $script:typed = @{}; $script:invokeCount = 0
    $script:hasApp = $true; $script:failDashboard = $false
    $script:keepPromptFocus = $true
    $script:app = [pscustomobject]@{
        Id=123; MainWindowHandle=[IntPtr]42; StartTime=[DateTime]'2026-01-01'
        SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId
    }
    [THGLTest.Forms.SendKeys]::Calls = 0
    [ThglForeground]::KeepFocus = $true
}
function NewWindow([string]$path, [int]$processId=222, [string]$title='') {
    if (-not $title) { $title = 'DevTools - app.th.gl/' + $path }
    $window = [pscustomobject]@{Path=$path; Current=[pscustomobject]@{
        Name=$title; ProcessId=$processId; NativeWindowHandle=(42 + $script:windows.Count)
    }}
    $window | Add-Member ScriptMethod GetCurrentPattern {
        param($pattern)
        $result = [pscustomobject]@{}
        $result | Add-Member ScriptMethod SetWindowVisualState {param($state)}
        return $result
    }
    return $window
}
function Log([string]$message) { $script:messages.Add($message) }
function Start-Sleep {param($Milliseconds,$Seconds)}
function Get-Process {
    param($Name,$ErrorAction)
    if ($script:hasApp) {
        # A process from another session must not win Select-Object -First 1.
        [pscustomobject]@{Id=999; SessionId=($script:app.SessionId+1); MainWindowHandle=[IntPtr]55; StartTime=$script:app.StartTime}
        $script:app
    }
}
function Get-CimInstance {
    param($ClassName,$Filter,$ErrorAction)
    if ($Filter -ne ('SessionId = ' + $script:app.SessionId)) { throw 'Session filter missing' }
    # Grandchild listed first exercises transitive rather than one-pass matching.
    [pscustomobject]@{ProcessId=333; ParentProcessId=222}
    [pscustomobject]@{ProcessId=222; ParentProcessId=123}
    [pscustomobject]@{ProcessId=999; ParentProcessId=1}
}
function FindControl {
    param($parent, [string]$name, $kind)
    if ($name -in @('dashboard', 'aion2 (overlay)')) {
        if ($name -eq 'dashboard' -and $script:failDashboard) { return $null }
        $path = if ($name -eq 'dashboard') { 'dashboard' } else { 'apps/aion2/overlay' }
        $button = [pscustomobject]@{Path=$path}
        $button | Add-Member ScriptMethod GetCurrentPattern {param($pattern); return $this}
        $button | Add-Member ScriptMethod Invoke {
            $script:invokeCount++
            $script:windows.Add((NewWindow $this.Path))
        }
        return $button
    }
    if ($name -in @('Settings', 'Developer Tools')) { return $null }
    if (-not $script:ready[$parent.Path]) { return $null }
    if ($name -eq 'Console') {
        $tab = [pscustomobject]@{}
        $tab | Add-Member ScriptMethod GetCurrentPattern {param($pattern); return $this}
        $tab | Add-Member ScriptMethod Select {}
        return $tab
    }
    if ($name -eq 'Console prompt') {
        $prompt = [pscustomobject]@{Path=$parent.Path}
        $prompt | Add-Member ScriptMethod GetCurrentPattern {param($pattern); return $this}
        $prompt | Add-Member ScriptMethod SetValue {param($value); $script:typed[$this.Path] = $value}
        $prompt | Add-Member ScriptMethod SetFocus {
            [THGLTest.Automation.AutomationElement]::FocusedElement = if ($script:keepPromptFocus) { $this } else { [pscustomobject]@{} }
        }
        return $prompt
    }
    throw "Unexpected lookup: $name"
}
$rootElement = [pscustomobject]@{}
$rootElement | Add-Member ScriptMethod FindAll {param($scope,$condition); return $script:windows.ToArray()}
[THGLTest.Automation.AutomationElement]::RootElement = $rootElement

# 1. Retry a failed refresh on the existing window; do not repeatedly reload.
ResetFixture
Tick
Assert (-not $refreshStates['dashboard'].Ready) 'Transient Console failure must stay pending'
Assert ($invokeCount -eq 1 -and [THGLTest.Forms.SendKeys]::Calls -eq 0) 'First attempt did not fail safely'
Tick
Assert ($invokeCount -eq 1) 'Backoff did not suppress an immediate retry'
$ready['dashboard'] = $true
$refreshStates['dashboard'].NextAttempt = [DateTime]::MinValue
Tick
Assert ($refreshStates['dashboard'].Ready) 'Refresh did not recover on the already-open window'
Assert ($invokeCount -eq 1 -and [THGLTest.Forms.SendKeys]::Calls -eq 1) 'Recovery reopened a window or missed the key'
Tick
Assert ([THGLTest.Forms.SendKeys]::Calls -eq 1) 'Completed refresh repeated'

# 2. Restrict both process ancestry and the title path boundary.
ResetFixture
$script:appProcessIds = GetAppProcessIds $app
$windows.Add((NewWindow 'dashboard' 999))
$windows.Add((NewWindow 'dashboard' 222 'DevTools - app.th.gl/dashboard-lookalike'))
$windows.Add((NewWindow 'dashboard' 333))
$found = FindDevTools 'dashboard'
Assert ($found.Current.ProcessId -eq 333) 'Foreign process or path suffix was accepted'
Assert ($appProcessIds.ContainsKey(333) -and -not $appProcessIds.ContainsKey(999)) 'Process ancestry is incorrect'

# Dashboard navigation changes the DevTools title without changing the view.
foreach ($title in @(
    'DevTools - app.th.gl/dashboard',
    'DevTools - app.th.gl/dashboard/',
    'DevTools - app.th.gl/dashboard?test=1',
    'DevTools - app.th.gl/dashboard#test',
    'DevTools - app.th.gl/dashboard - TH.GL',
    'DevTools - app.th.gl/dashboard/settings',
    'DevTools - app.th.gl/dashboard/games/aion2',
    'DevTools - app.th.gl/dashboard/games/aion2?test=1#map'
)) {
    ResetFixture
    $script:appProcessIds = GetAppProcessIds $app
    $windows.Add((NewWindow 'dashboard' 222 $title))
    Assert ($null -ne (FindDevTools 'dashboard')) "Dashboard title not recognized: $title"
}
foreach ($title in @(
    'DevTools - app.th.gl/apps/aion2/overlay-lookalike',
    'DevTools - app.th.gl/apps/aion2/overlay/settings'
)) {
    ResetFixture
    $script:appProcessIds = GetAppProcessIds $app
    $windows.Add((NewWindow 'overlay' 222 $title))
    Assert ($null -eq (FindDevTools 'apps/aion2/overlay')) "Unexpected overlay route accepted: $title"
}

# 3. Starting the watchdog must preserve an already-open view.
ResetFixture
$windows.Add((NewWindow 'dashboard' 222 'DevTools - app.th.gl/dashboard/games/aion2'))
Tick
Assert ($invokeCount -eq 0 -and [THGLTest.Forms.SendKeys]::Calls -eq 0) 'Existing user window was reloaded on startup'
Assert ($appIdentity.StartsWith('123:')) 'Another session was selected'

# 4. A dashboard error must not starve the overlay.
ResetFixture
$failDashboard = $true
$windows.Add((NewWindow 'overlay' 222 'THGL Overlay'))
Tick
Assert (-not $refreshStates['dashboard'].Ready) 'Dashboard failure was lost'
Assert ($refreshStates['apps/aion2/overlay'].Ready) 'Dashboard failure blocked overlay'

# 5. Loss of foreground focus must prevent Enter from being sent.
ResetFixture
$ready['dashboard'] = $true
[ThglForeground]::KeepFocus = $false
Tick
Assert (-not $refreshStates['dashboard'].Ready) 'Focus failure was marked successful'
Assert ([THGLTest.Forms.SendKeys]::Calls -eq 0) 'Enter was sent without foreground focus'

# Foreground alone is insufficient when a different control retains keyboard focus.
ResetFixture
$ready['dashboard'] = $true
$keepPromptFocus = $false
Tick
Assert (-not $refreshStates['dashboard'].Ready) 'Prompt focus loss was marked successful'
Assert ([THGLTest.Forms.SendKeys]::Calls -eq 0) 'Enter was sent to a different focused control'

# 6. Missing/restarted application invalidates previous state.
$hasApp = $false
Tick
Assert ($refreshStates.Count -eq 0 -and $appProcessIds.Count -eq 0) 'Exited application retained state'
$hasApp = $true
$windows.Clear()
$app.StartTime = $app.StartTime.AddMinutes(1)
$ready['dashboard'] = $true
$keepPromptFocus = $true
[ThglForeground]::KeepFocus = $true
Tick
Assert ($refreshStates['dashboard'].Ready) 'Restarted application did not attach'

# 7. Distinct errors cannot grow the retry log dictionary without bound.
ResetFixture
for ($index=0; $index -lt 140; $index++) { LogRetry "fixture error $index" }
Assert ($lastErrors.Count -eq 128) 'Error cache is unbounded'

# 8. Exercise the actual logger's rotation and error isolation with local files.
. ([scriptblock]::Create(($definitions | Where-Object Name -eq 'Log').Extent.Text))
$rootPath = Join-Path ([IO.Path]::GetTempPath()) ('thgl-logger-' + [Guid]::NewGuid().ToString('N'))
$logPath = Join-Path $rootPath 'watchdog.log'
$script:logStream = $null
try {
    New-Item -ItemType Directory -Path $rootPath | Out-Null
    [IO.File]::WriteAllBytes($logPath, [byte[]]::new(2MB))
    Log 'rotation probe'
    Assert ((Test-Path -LiteralPath ($logPath+'.1')) -and (Get-Item -LiteralPath $logPath).Length -lt 1KB) 'Log did not rotate'
    $logStream.Dispose(); $script:logStream = $null
    Remove-Item -LiteralPath $logPath
    New-Item -ItemType Directory -Path $logPath | Out-Null
    Log 'expected write failure' 3>$null
    Assert (Test-Path -LiteralPath $logPath -PathType Container) 'Logger failure was not isolated'
    Remove-Item -LiteralPath $logPath

    # 9. A pre-existing hard link must never receive appended log data.
    $external = Join-Path $rootPath 'external-canary.txt'
    [IO.File]::WriteAllText($external, 'preserve external canary')
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $null = & cmd /c mklink /H $logPath $external
    } else { $null = & ln $external $logPath }
    if ($LASTEXITCODE -ne 0) { throw 'Could not create hard link for regression test' }
    Log 'hard-link regression'
    Assert ([IO.File]::ReadAllText($external) -eq 'preserve external canary') 'Logger wrote through a hard link'
    $logStream.Dispose(); $script:logStream = $null
    Assert ([IO.File]::ReadAllText($logPath) -match 'hard-link regression') 'New log was not written'
    Assert ([IO.File]::ReadAllText($logPath+'.1') -eq 'preserve external canary') 'Previous hard link contents changed'
} finally {
    if ($logStream) { $logStream.Dispose(); $script:logStream = $null }
    Remove-Item -LiteralPath $rootPath -Recurse -Force
}
Write-Host "$checks assertions passed in 9 watchdog scenarios (inert Windows APIs)."
