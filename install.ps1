# Install or remove TH.GL Clean Layout. -StageOnly is for isolated QA; no scheduled task.
#requires -Version 5.1
param(
    [switch]$Uninstall,
    [switch]$StageOnly,
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'THGL-Clean-Layout')
)
$ErrorActionPreference = 'Stop'
$taskName = 'THGL Clean Layout'
$pathComparison = [StringComparison]::Ordinal
if ([IO.Path]::DirectorySeparatorChar -eq '\') { $pathComparison = [StringComparison]::OrdinalIgnoreCase }

function GetFileSystemPath([string]$Path) {
    $provider = $null; $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'Only filesystem paths are supported.' }
    $full = [IO.Path]::GetFullPath($resolved)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd([char[]]'\/') }
    return $full
}
# Inspect ancestors too: Documents or the install root itself may be a junction.
function AssertSafePath([string]$Path, [switch]$Leaf) {
    $cursor = $Path
    $first = $true
    while ($cursor) {
        try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { $item = $null }
        if ($item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a symbolic link or junction: $cursor"
            }
            if ($first -and $Leaf -and $item.PSIsContainer) { throw "Expected a file: $cursor" }
            if (-not $first -and -not $item.PSIsContainer) { throw "Expected a directory: $cursor" }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($parent) { $parent.FullName } else { $null }
        $first = $false
    }
}
$InstallRoot = GetFileSystemPath $InstallRoot
if ($InstallRoot -eq [IO.Path]::GetPathRoot($InstallRoot)) { throw 'InstallRoot must be a dedicated directory.' }
AssertSafePath $InstallRoot
$manifestPath = Join-Path $InstallRoot 'manifest.json'
$watchdogPath = Join-Path $InstallRoot 'watchdog.ps1'
if (-not $StageOnly) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -eq 'Core') {
        throw 'Use Windows PowerShell 5.1 on Windows, or -StageOnly for isolated QA.'
    }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run Windows PowerShell as Administrator to register/remove the auto-start task.'
    }
    $defaultRoot = GetFileSystemPath (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'THGL-Clean-Layout')
    if (-not $InstallRoot.Equals($defaultRoot, $pathComparison)) {
        throw 'Custom -InstallRoot is supported only with -StageOnly, including uninstall.'
    }
    $protectedRoot = GetFileSystemPath (Join-Path $env:ProgramFiles 'THGL-Clean-Layout')
    AssertSafePath $protectedRoot
    $watchdogPath = Join-Path $protectedRoot 'watchdog.ps1'
}
AssertSafePath $manifestPath -Leaf
AssertSafePath $watchdogPath -Leaf

function GetManagedCssPath($Value) {
    # Do not coerce arrays: PowerShell member enumeration can make boolean[] truthy.
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw 'Invalid overrideFile in manifest.' }
    if ($Value -match '(^|[\\/])\.{1,2}([\\/]|$)') { throw 'Parent/relative segments are not allowed in overrideFile.' }
    $full = GetFileSystemPath $Value
    $prefix = $InstallRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, $pathComparison)) { throw 'overrideFile is outside InstallRoot.' }
    $relative = $full.Substring($prefix.Length)
    if ($relative -cnotmatch '^static\.th\.gl[\\/]_next[\\/]static[\\/]chunks[\\/][A-Za-z0-9_-]+\.css$') {
        throw 'overrideFile is not a managed TH.GL stylesheet.'
    }
    AssertSafePath $full -Leaf
    return $full
}
function ReadManifest {
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    if ((Get-Item -LiteralPath $manifestPath).Length -gt 1MB) { throw 'Manifest is too large.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest -isnot [pscustomobject]) { throw 'Manifest must be a JSON object.' }
    if ($null -ne $manifest.schemaVersion -and
        (($manifest.schemaVersion -isnot [int] -and $manifest.schemaVersion -isnot [long]) -or $manifest.schemaVersion -ne 2)) {
        throw 'Unsupported manifest version.'
    }
    $manifest.overrideFile = GetManagedCssPath $manifest.overrideFile
    if ($manifest.schemaVersion -eq 2) {
        foreach ($field in @('overrideSha256', 'watchdogSha256')) {
            if ($manifest.$field -isnot [string] -or $manifest.$field -notmatch '^[a-fA-F0-9]{64}$') {
                throw "Invalid $field in manifest."
            }
        }
    }
    return $manifest
}
function AssertUnchangedFile([string]$Path, $Hash, [switch]$LegacyCss) {
    AssertSafePath $Path -Leaf
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($Hash) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) {
            throw "File was modified; preserve or move it before retrying: $Path"
        }
    } elseif ($LegacyCss -and -not (Select-String -LiteralPath $Path -SimpleMatch '/* THGL Clean Layout: local rules */' -Quiet)) {
        throw "Legacy stylesheet is not recognizable; preserve or move it before retrying: $Path"
    }
}
$old = ReadManifest
if ($old) {
    AssertUnchangedFile $old.overrideFile $old.overrideSha256 -LegacyCss
    AssertUnchangedFile $watchdogPath $old.watchdogSha256
}
$task = $null; $taskXml = $null; $taskWasRunning = $false; $taskChanged = $false
if (-not $StageOnly) {
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    $taskArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watchdogPath + '"'
    $taskExecutable = Join-Path $PSHOME 'powershell.exe'
    if ($task) {
        if (@($task).Count -ne 1 -or @($task.Actions).Count -ne 1 -or
            $task.Actions[0].Execute -ne $taskExecutable -or $task.Actions[0].Arguments -ne $taskArguments) {
            throw 'Task name is used by a different command. Refusing to replace/remove it.'
        }
        $taskXml = Export-ScheduledTask -TaskName $taskName -TaskPath '\'
        $taskWasRunning = $task.State -eq 'Running'
    }
}
if ($Uninstall -and -not $old) {
    if ($task) { throw 'Manifest is missing; no task or files were removed. Restore the manifest before retrying.' }
    Write-Host 'No manifest found; no files were removed. You can revoke the DevTools folder permission.'
    return
}
if (-not $old -and (Test-Path -LiteralPath $watchdogPath)) {
    throw "Refusing to overwrite an unrecognized watchdog: $watchdogPath"
}

# An in-process undo journal restores files when a later write/task operation fails.
# Recheck paths on use; do not follow links introduced since the initial validation.
$journal = [Collections.Generic.List[object]]::new()
function RememberFile([string]$Path) {
    AssertSafePath $Path -Leaf
    foreach ($entry in $journal) { if ($entry.Path.Equals($Path, $pathComparison)) { return } }
    $exists = Test-Path -LiteralPath $Path
    $bytes = $null
    if ($exists) { $bytes = [IO.File]::ReadAllBytes($Path) }
    $journal.Add([pscustomobject]@{Path=$Path; Exists=$exists; Bytes=$bytes; Changed=$false})
}
function WriteAtomic([string]$Path, [byte[]]$Bytes) {
    AssertSafePath $Path -Leaf
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    AssertSafePath $Path -Leaf
    $temporary = Join-Path $parent ('.thgl-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
        AssertSafePath $Path -Leaf
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            AssertSafePath $temporary -Leaf
            Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
        }
    }
}
function WriteManaged([string]$Path, [byte[]]$Bytes) {
    RememberFile $Path
    WriteAtomic $Path $Bytes
    foreach ($entry in $journal) { if ($entry.Path.Equals($Path, $pathComparison)) { $entry.Changed = $true } }
}
function RemoveManaged([string]$Path, [switch]$DiscardContent) {
    # Logs are disposable. Never read/copy a user-writable log into the journal:
    # it could be a hard link whose target has different read permissions.
    if ($DiscardContent) { AssertSafePath $Path -Leaf }
    else { RememberFile $Path }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $DiscardContent) {
            foreach ($entry in $journal) { if ($entry.Path.Equals($Path, $pathComparison)) { $entry.Changed = $true } }
        }
    }
    if (Test-Path -LiteralPath $Path) { throw "File was not removed: $Path" }
}
function PreserveLegacy([string]$Path) {
    if ($old -and $old.schemaVersion -ne 2 -and (Test-Path -LiteralPath $Path)) {
        $backup = Join-Path (Join-Path $InstallRoot 'backups') ([Guid]::NewGuid().ToString('N') + '-' + (Split-Path -Leaf $Path))
        WriteManaged $backup ([IO.File]::ReadAllBytes($Path))
        Write-Host "Legacy file preserved: $backup"
    }
}
function RemoveEmptyDirectory([string]$Path) {
    AssertSafePath $Path
    if ((Test-Path -LiteralPath $Path) -and -not (Get-ChildItem -LiteralPath $Path -Force)) {
        Remove-Item -LiteralPath $Path -ErrorAction Stop
    }
}

$utf8 = [Text.UTF8Encoding]::new($false)
if (-not $Uninstall) {
    $sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $watchdogSource = Join-Path $sourceDir 'watchdog.ps1'
    $cssSource = Join-Path $sourceDir 'clean-layout.css'
    foreach ($file in @($watchdogSource, $cssSource)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing repository file: $file" }
    }
    $pages = @('https://app.th.gl/dashboard', 'https://app.th.gl/apps/aion2/overlay')
    $pattern = 'https://static\.th\.gl/_next/static/chunks/[A-Za-z0-9_-]+\.css'
    $sets = @()
    foreach ($page in $pages) {
        $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 0).Content
        $links = @([regex]::Matches($html, $pattern) | ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($links.Count -eq 0) { throw "No stylesheet links found at $page. TH.GL may have changed." }
        $sets += ,$links
    }
    $common = @($sets[0] | Where-Object { $sets[1] -contains $_ })
    if ($common.Count -eq 0 -or $common.Count -gt 32) { throw 'Unexpected number of shared stylesheets.' }
    $bestUrl = $null; $bestContent = $null
    foreach ($url in $common) {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 0
        $contentType = [string]$response.Headers['Content-Type']
        $content = $response.Content
        if ($content -is [byte[]]) { $content = $utf8.GetString($content) }
        if ($content -isnot [string] -or [string]::IsNullOrWhiteSpace($content) -or $content.Length -gt 4MB -or
            $contentType -notmatch '^text/css(?:\s*;|$)' -or $content.TrimStart() -match '^<') {
            throw "Expected a nonempty CSS response from $url; previous installation was not changed."
        }
        if ($null -eq $bestContent -or $content.Length -lt $bestContent.Length) {
            $bestUrl = $url; $bestContent = $content
        }
    }
    $uri = [Uri]$bestUrl
    $relative = $uri.AbsolutePath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
    $overridePath = GetManagedCssPath (Join-Path (Join-Path $InstallRoot $uri.Host) $relative)
    if ((Test-Path -LiteralPath $overridePath) -and
        (-not $old -or -not $overridePath.Equals($old.overrideFile, $pathComparison))) {
        throw "Refusing to overwrite an unrecognized stylesheet: $overridePath"
    }
    $rules = Get-Content -LiteralPath $cssSource -Raw -Encoding UTF8
    $combined = $bestContent.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine +
        '/* THGL Clean Layout: local rules */' + [Environment]::NewLine + $rules
}
try {
    if ($taskWasRunning) { Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop }
    if ($old) {
        AssertUnchangedFile $old.overrideFile $old.overrideSha256 -LegacyCss
        AssertUnchangedFile $watchdogPath $old.watchdogSha256
        PreserveLegacy $old.overrideFile
        PreserveLegacy $watchdogPath
    }
    if ($Uninstall) {
        RemoveManaged $old.overrideFile
        RemoveManaged $watchdogPath
        RemoveManaged (Join-Path $InstallRoot 'watchdog.log') -DiscardContent
        RemoveManaged (Join-Path $InstallRoot 'watchdog.log.1') -DiscardContent
        RemoveManaged $manifestPath
        if ($task) {
            $taskChanged = $true
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        }
    } else {
        WriteManaged $overridePath ($utf8.GetBytes($combined))
        WriteManaged $watchdogPath ([IO.File]::ReadAllBytes($watchdogSource))
        $manifest = @{
            schemaVersion = 2; overrideFile = $overridePath; sourceUrl = $bestUrl
            overrideSha256 = (Get-FileHash -LiteralPath $overridePath -Algorithm SHA256).Hash
            watchdogSha256 = (Get-FileHash -LiteralPath $watchdogPath -Algorithm SHA256).Hash
            installedAt = (Get-Date).ToString('o')
        }
        WriteManaged $manifestPath ($utf8.GetBytes(($manifest | ConvertTo-Json)))
        if ($old -and -not $old.overrideFile.Equals($overridePath, $pathComparison)) { RemoveManaged $old.overrideFile }
        if (-not $StageOnly) {
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $action = New-ScheduledTaskAction -Execute $taskExecutable -Argument $taskArguments
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
            $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            $taskChanged = $true
            $registration = @{
                TaskName=$taskName; TaskPath='\'; Action=$action; Trigger=$trigger
                Principal=$principal; Settings=$settings; Force=$true; ErrorAction='Stop'
                Description='Keep TH.GL dashboard and AION 2 overlay CSS Local Overrides active.'
            }
            Register-ScheduledTask @registration | Out-Null
            Start-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
        }
    }
} catch {
    $failure = $_
    if ($taskChanged) {
        try { Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop }
        catch { Write-Warning "Could not stop the replacement task: $($_.Exception.Message)" }
    }
    # Restore files before restarting the previous task. Never conceal rollback failures.
    for ($index = $journal.Count - 1; $index -ge 0; $index--) {
        $entry = $journal[$index]
        if (-not $entry.Changed) { continue }
        try {
            if ($entry.Exists) { WriteAtomic $entry.Path $entry.Bytes }
            else {
                AssertSafePath $entry.Path -Leaf
                if (Test-Path -LiteralPath $entry.Path) { Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop }
            }
        } catch { Write-Warning "Rollback failed for $($entry.Path): $($_.Exception.Message)" }
    }
    if (-not $StageOnly) {
        try {
            if ($taskChanged) {
                if ($taskXml) { Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $taskXml -Force -ErrorAction Stop | Out-Null }
                else { Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
            }
            if ($taskWasRunning) { Start-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop }
        } catch { Write-Warning "Task rollback failed: $($_.Exception.Message)" }
    }
    throw $failure
}
# Only prune the known stylesheet directory chain; never recurse through unknown files/links.
if ($old) {
    $directory = Split-Path -Parent $old.overrideFile
    while ($directory.StartsWith($InstallRoot + [IO.Path]::DirectorySeparatorChar, $pathComparison)) {
        RemoveEmptyDirectory $directory
        $directory = Split-Path -Parent $directory
    }
}
if ($Uninstall) {
    if (-not $StageOnly) { RemoveEmptyDirectory $protectedRoot }
    RemoveEmptyDirectory $InstallRoot
    Write-Host 'Uninstalled. Legacy backups and unrelated files are preserved. Revoke the folder permission in DevTools > Sources > Overrides.'
    return
}
Write-Host ''
Write-Host 'The CSS override file was created automatically. Do not add or drag files into DevTools.'
Write-Host 'SELECT THIS FOLDER in DevTools > Sources > Overrides:'
Write-Host "  $InstallRoot"
Write-Host "CSS: $overridePath"
if ($StageOnly) { Write-Host 'Stage-only test completed. No scheduled task created.' }
else {
    Write-Host 'Open TH.GL > Settings > Developer Tools > dashboard.'
    Write-Host 'Sources > Overrides > Select folder for overrides > select the folder above > Allow.'
    Write-Host 'Then repeat for aion2 (overlay), using the SAME folder. Keep Local overrides enabled.'
    Write-Host 'Auto-start task installed. See README for the full guide.'
}
