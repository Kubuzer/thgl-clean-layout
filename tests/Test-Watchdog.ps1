# Logic regression tests with inert UI APIs; no real windows or keys are touched.
# Production logic is unchanged; UI namespaces are redirected to inert fixtures.
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
namespace THGLTest.Automation {
  public static class ControlType {
    public static readonly object Button = "Button", Hyperlink = "Hyperlink", TabItem = "TabItem", Edit = "Edit", Text = "Text";
  }
  public static class InvokePattern { public static readonly object Pattern = "Invoke"; }
  public static class WindowPattern { public static readonly object Pattern = "Window"; }
  public static class SelectionItemPattern { public static readonly object Pattern = "Selection"; }
  public static class ValuePattern { public static readonly object Pattern = "Value"; }
  public enum WindowVisualState { Normal, Minimized }
  public enum TreeScope { Children, Descendants }
  public static class Condition { public static readonly object TrueCondition = new object(); }
  public static class AutomationElement {
    public static object RootElement, FocusedElement, NameProperty;
    public static object FromHandle(IntPtr h) { return new object(); }
  }
  public class PropertyCondition {
    public string Name;
    public PropertyCondition(object property, string name) { Name = name; }
  }
  public static class Automation {
    public static bool Compare(object a, object b) { return object.ReferenceEquals(a,b); }
  }
}
namespace THGLTest.Forms {
  public static class SendKeys {
    public static int Calls;
    public static Action OnSend;
    public static void SendWait(string value) { Calls++; if (OnSend != null) OnSend(); }
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
foreach ($name in @('LogRetry', 'GetAppProcessIds', 'Windows', 'FindDevTools', 'SendConsoleCommand', 'WaitConsoleText', 'OpenAndRefresh', 'EnsureView', 'Tick')) {
    $definition = $definitions | Where-Object Name -eq $name
    $body = $definition.Extent.Text.Replace('[System.Windows.Automation.', '[THGLTest.Automation.').Replace('[System.Windows.Forms.', '[THGLTest.Forms.')
    . ([scriptblock]::Create($body))
}
$realFindControl = [scriptblock]::Create('param($parent, [string]$name, $kind)' + ($definitions | Where-Object Name -eq 'FindControl').Body.Extent.Text.Trim('{}').Replace('System.Windows.Automation.', 'THGLTest.Automation.'))
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
    $script:mainRestores = 0
    $script:closeCount = 0; $script:reloadCounts = @{}
    $script:documentTokens = @{}; $script:outputs = @{}
    $script:cssLoaded = $true; $script:reloadCompletes = $true; $script:documentComplete = $true
    $script:echoOnly = $false; $script:closeWorks = $true
    $script:failReloadFocus = $false
    $script:commandPath = $null; $script:nextHandle = 100
    $script:app = [pscustomobject]@{
        Id=123; MainWindowHandle=[IntPtr]42; StartTime=[DateTime]'2026-01-01'
        SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId
    }
    $script:windows.Add((NewWindow 'controller' 123 'Controller'))
    $script:main = NewWindow 'main' 123 'The Hidden Gaming Lair'
    $script:windows.Add($main)
    [THGLTest.Forms.SendKeys]::Calls = 0
    [ThglForeground]::KeepFocus = $true
}
function NewWindow([string]$path, [int]$processId=222, [string]$title='') {
    if (-not $title) { $title = 'DevTools - app.th.gl/' + $path }
    $window = [pscustomobject]@{Path=$path; Closed=$false; Snapshot=[pscustomobject]@{
        Name=$title; ProcessId=$processId; NativeWindowHandle=($script:nextHandle++)
    }}
    $window | Add-Member ScriptProperty Current {
        if ($this.Closed) { throw 'Stale Current access after Close' }
        return $this.Snapshot
    }
    $window | Add-Member ScriptMethod GetCurrentPattern {
        param($pattern)
        $result = [pscustomobject]@{Path=$this.Path; Window=$this}
        $result | Add-Member ScriptMethod SetWindowVisualState {
            param($state)
            if ($this.Path -eq 'main') { $script:mainRestores++ }
        }
        $result | Add-Member ScriptMethod Close {
            $script:closeCount++
            if ($script:closeWorks) {
                $script:windows.Remove($this.Window) | Out-Null
                $this.Window.Closed = $true
            }
        }
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
    if ($kind -eq [THGLTest.Automation.ControlType]::Text) {
        $outputParent = [pscustomobject]@{Path=$parent.Path}
        $outputParent | Add-Member ScriptMethod FindAll {
            param($scope,$condition)
            foreach ($text in @($script:outputs[$this.Path])) {
                if ($text -eq $condition.Name) { [pscustomobject]@{Current=[pscustomobject]@{Name=$text; ControlType=[THGLTest.Automation.ControlType]::Text}} }
            }
        }
        return (& $script:realFindControl $outputParent $name $kind)
    }
    if ($name -in @('dashboard', 'aion2 (overlay)')) {
        if ($parent.Current.Name -ne 'The Hidden Gaming Lair' -or $parent.Current.ProcessId -ne $app.Id) { return $null }
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
        $prompt | Add-Member ScriptMethod SetValue {param($value); $script:typed[$this.Path] = $value; $script:commandPath = $this.Path}
        $prompt | Add-Member ScriptMethod SetFocus {
            [THGLTest.Automation.AutomationElement]::FocusedElement = if ($script:keepPromptFocus -and
                -not ($script:failReloadFocus -and $script:typed[$this.Path] -eq 'location.reload()')) { $this } else { [pscustomobject]@{} }
        }
        return $prompt
    }
    throw "Unexpected lookup: $name"
}
function InvokeFixtureCommand {
    $path = $script:commandPath
    $command = $script:typed[$path]
    if ($command -match "^window\.__thglCleanLayoutDocument='([a-f0-9]+)';console\.info\('(THGL_ARM_[a-f0-9]+)'\)$") {
        $script:documentTokens[$path] = $Matches[1]
        $script:outputs[$path] = @($(if ($script:echoOnly) { "'" + $Matches[2] + "'" } else { $Matches[2] }))
    } elseif ($command -eq 'location.reload()') {
        $script:reloadCounts[$path] = 1 + $script:reloadCounts[$path]
        if ($script:reloadCompletes) { $script:documentTokens.Remove($path); $script:outputs.Remove($path) }
    } elseif ($command -match "console\.info\('(THGL_CSS_[a-f0-9]+)'\)") {
        $token = $Matches[1]
        # Inert browser simulation: production command must contain every proof guard.
        if ($command -notmatch "document\.readyState==='complete'" -or
            $command -notmatch "window\.__thglCleanLayoutDocument!==('[a-f0-9]+')" -or
            $command -notmatch "getPropertyValue\('--thgl-clean-layout'\)\.trim\(\)==='1'") { throw 'Missing CSS/new-document proof guard' }
        if ($script:cssLoaded -and $script:documentComplete -and -not $script:documentTokens.ContainsKey($path)) {
            $script:outputs[$path] = @($(if ($script:echoOnly) { "'" + $token + "'" } else { $token }))
        }
    } else { throw "Unexpected fixture Console command: $command" }
}
[THGLTest.Forms.SendKeys]::OnSend = { InvokeFixtureCommand }
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
Assert ($invokeCount -eq 1 -and $reloadCounts['dashboard'] -eq 1 -and $closeCount -eq 1) 'Recovery reopened a window, missed reload, or did not close'
Tick
Assert ($reloadCounts['dashboard'] -eq 1 -and $invokeCount -eq 1) 'Intentionally closed view reopened'

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

# 3. Explicit auto-close includes an already-open DevTools window.
ResetFixture
$ready['dashboard'] = $true
$windows.Add((NewWindow 'dashboard' 222 'DevTools - app.th.gl/dashboard/games/aion2'))
Tick
Assert ($invokeCount -eq 0 -and $reloadCounts['dashboard'] -eq 1 -and $closeCount -eq 1) 'Existing DevTools was reopened or not processed'
Assert ($appIdentity.StartsWith('123:')) 'Another session was selected'
Assert ($mainRestores -eq 0) 'Dashboard was restored despite existing DevTools'

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
$windows.Add($main)
$app.StartTime = $app.StartTime.AddMinutes(1)
$ready['dashboard'] = $true
$keepPromptFocus = $true
[ThglForeground]::KeepFocus = $true
Tick
Assert ($refreshStates['dashboard'].Ready) 'Restarted application did not attach'
Assert ($mainRestores -gt 0) 'Dashboard was not restored before opening missing DevTools'

# A same-title window outside the app must not replace a missing dashboard.
ResetFixture
$windows.Remove($main) | Out-Null
$windows.Add((NewWindow 'main' 999 'The Hidden Gaming Lair'))
Tick
Assert ($invokeCount -eq 0 -and [THGLTest.Forms.SendKeys]::Calls -eq 0) 'Controller or foreign dashboard was used'

# CSS acknowledgement is required; the first reload is not replayed on retry.
ResetFixture
$ready['dashboard'] = $true
$cssLoaded = $false
Tick
Assert (-not $refreshStates['dashboard'].Ready -and $closeCount -eq 0) 'Missing CSS acknowledgement closed DevTools'
$cssLoaded = $true
$refreshStates['dashboard'].NextAttempt = [DateTime]::MinValue
Tick
Assert ($refreshStates['dashboard'].Ready -and $reloadCounts['dashboard'] -eq 1 -and $closeCount -eq 1) 'CSS readiness retry repeated reload or failed to close'

# A setup/focus failure before reload dispatch must remain recoverable.
ResetFixture
$ready['dashboard'] = $true
$failReloadFocus = $true
Tick
Assert (-not $refreshStates['dashboard'].ReloadRequested -and -not $reloadCounts['dashboard']) 'Reload was recorded before guarded dispatch'
$failReloadFocus = $false
$refreshStates['dashboard'].NextAttempt = [DateTime]::MinValue
Tick
Assert ($refreshStates['dashboard'].Ready -and $reloadCounts['dashboard'] -eq 1) 'Reload setup failure could not recover'

# The old document, incomplete loading, and quoted command echoes cannot prove readiness.
foreach ($failure in @('old-document', 'loading', 'echo')) {
    ResetFixture
    $ready['dashboard'] = $true
    if ($failure -eq 'old-document') { $reloadCompletes = $false }
    if ($failure -eq 'loading') { $documentComplete = $false }
    if ($failure -eq 'echo') { $echoOnly = $true }
    Tick
    Assert (-not $refreshStates['dashboard'].Ready -and $closeCount -eq 0) "Unproven readiness accepted: $failure"
}

# A close that did not remove the actual window is not reported complete.
ResetFixture
$ready['dashboard'] = $true
$closeWorks = $false
Tick
Assert (-not $refreshStates['dashboard'].Ready -and $closeCount -eq 1) 'Failed close was marked complete'
$windows.Remove((FindDevTools 'dashboard')) | Out-Null
Tick
Assert ($refreshStates['dashboard'].Ready -and $invokeCount -eq 1) 'Ambiguous close was replayed instead of reconciled'

# Completed state belongs to the view HWND, not the temporary DevTools HWND.
ResetFixture
$ready['dashboard'] = $true
$overlay = NewWindow 'overlay' 222 'THGL Overlay'
$windows.Add($overlay)
Tick
Assert ($refreshStates['apps/aion2/overlay'].Ready -and $closeCount -eq 2) 'Both views were not closed after confirmation'
Tick
Assert ($invokeCount -eq 2) 'Closed overlay DevTools reopened every tick'
$windows.Remove($overlay) | Out-Null
$overlay = NewWindow 'overlay' 222 'THGL Overlay'
$windows.Add($overlay)
Tick
Assert ($reloadCounts['apps/aion2/overlay'] -eq 2 -and $reloadCounts['dashboard'] -eq 1) 'Recreated overlay did not invalidate only its own completed state'
$windows.Remove($overlay) | Out-Null
Tick
Assert ($refreshStates.ContainsKey('apps/aion2/overlay')) 'Hidden overlay lost completed state'
$windows.Add($overlay)
Tick
Assert ($reloadCounts['apps/aion2/overlay'] -eq 2) 'Same overlay HWND reloaded after hide/show'
$main.Current.NativeWindowHandle++
Tick
Assert ($reloadCounts['dashboard'] -eq 2) 'Recreated dashboard retained completed state'
$app.StartTime = $app.StartTime.AddMinutes(1)
Tick
Assert ($reloadCounts['dashboard'] -eq 3) 'App restart retained intentional-close state'

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
Write-Host "$checks assertions passed (inert Windows APIs; no real browser execution)."
