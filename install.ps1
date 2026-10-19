# Install or remove TH.GL Clean Layout. -StageOnly is for isolated QA; no scheduled task.
param(
    [switch]$Uninstall,
    [switch]$StageOnly,
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'THGL-Clean-Layout')
)
$ErrorActionPreference = 'Stop'
$taskName = 'THGL Clean Layout'
$manifestPath = Join-Path $InstallRoot 'manifest.json'
# The elevated task's script must NOT live in a user-writable Documents folder.
$protectedRoot = Join-Path $env:ProgramFiles 'THGL-Clean-Layout'
$watchdogPath = Join-Path $protectedRoot 'watchdog.ps1'

function CheckAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = [Security.Principal.WindowsPrincipal]::new($id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Run PowerShell as Administrator to register/remove the auto-start task.' }
}
function RemoveManagedFiles {
    if (Test-Path -LiteralPath $manifestPath) {
        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($m.overrideFile -and $m.overrideFile.StartsWith($InstallRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $m.overrideFile -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($name in @('manifest.json', 'watchdog.log')) {
        Remove-Item -LiteralPath (Join-Path $InstallRoot $name) -Force -ErrorAction SilentlyContinue
    }
    if (-not $StageOnly) {
        Remove-Item -LiteralPath $watchdogPath -Force -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $protectedRoot) -and
            -not (Get-ChildItem -LiteralPath $protectedRoot -Force)) {
            Remove-Item -LiteralPath $protectedRoot
        }
    } else {
        Remove-Item -LiteralPath (Join-Path $InstallRoot 'watchdog.ps1') -Force -ErrorAction SilentlyContinue
    }
    $cssRoot = Join-Path $InstallRoot 'static.th.gl'
    if (Test-Path -LiteralPath $cssRoot) {
        # Only empty directories are removed. Preserve unknown user-created files.
        Get-ChildItem -LiteralPath $cssRoot -Directory -Recurse | Sort-Object FullName -Descending |
            ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) {
                Remove-Item -LiteralPath $_.FullName -Force }
            }
        if (-not (Get-ChildItem -LiteralPath $cssRoot -Force)) { Remove-Item -LiteralPath $cssRoot }
    }
    if ((Test-Path -LiteralPath $InstallRoot) -and
        -not (Get-ChildItem -LiteralPath $InstallRoot -Force)) {
        Remove-Item -LiteralPath $InstallRoot
    }
}

if ($Uninstall) {
    if (-not $StageOnly) {
        CheckAdmin
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            if (@($existing.Actions | Where-Object { $_.Arguments -notlike '*THGL-Clean-Layout*watchdog.ps1*' }).Count) {
                throw 'Task name is used by a different command. Refusing to remove it.'
            }
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    }
    RemoveManagedFiles
    Write-Host 'Uninstalled. You can also remove the folder permission in DevTools > Sources > Overrides.'
    exit 0
}

if (-not $StageOnly) {
    CheckAdmin
    $defaultRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'THGL-Clean-Layout'
    if ($InstallRoot -ne $defaultRoot) { throw 'Custom -InstallRoot is supported only with -StageOnly.' }
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing -and @($existing.Actions | Where-Object { $_.Arguments -notlike '*THGL-Clean-Layout*watchdog.ps1*' }).Count) {
        throw 'Task name is used by a different command. Refusing to overwrite it.'
    }
}
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$watchdogSource = Join-Path $sourceDir 'watchdog.ps1'
$cssSource = Join-Path $sourceDir 'clean-layout.css'
foreach ($file in @($watchdogSource, $cssSource)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing repository file: $file" }
}

# Choose a stylesheet referenced by BOTH pages. TH.GL rotates hashed filenames on updates.
$pages = @('https://app.th.gl/dashboard', 'https://app.th.gl/apps/aion2/overlay')
$pattern = 'https://static\.th\.gl/_next/static/chunks/[A-Za-z0-9_-]+\.css'
$sets = @()
foreach ($page in $pages) {
    $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 25).Content
    $links = @([regex]::Matches($html, $pattern) | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($links.Count -eq 0) { throw "No stylesheet links found at $page. TH.GL may have changed." }
    $sets += ,$links
}
$common = @($sets[0] | Where-Object { $sets[1] -contains $_ })
if ($common.Count -eq 0) { throw 'Dashboard and overlay have no common stylesheet.' }

# Use the smallest common stylesheet to minimize the locally overridden third-party code.
$bestUrl = $null
$bestContent = $null
foreach ($url in $common) {
    $content = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25).Content
    if (-not $bestContent -or $content.Length -lt $bestContent.Length) {
        $bestUrl = $url
        $bestContent = $content
    }
}
$uri = [Uri]$bestUrl
$relative = $uri.AbsolutePath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
$overridePath = Join-Path (Join-Path $InstallRoot $uri.Host) $relative
$rules = Get-Content -LiteralPath $cssSource -Raw
$combined = $bestContent.TrimEnd() + "`r`n`r`n/* THGL Clean Layout: local rules */`r`n" + $rules

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
}
# Remove the previous generated CSS (if the hash has changed).
if (Test-Path -LiteralPath $manifestPath) {
    $old = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($old.overrideFile -and $old.overrideFile -ne $overridePath -and
        $old.overrideFile.StartsWith($InstallRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $old.overrideFile -Force -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Path (Split-Path -Parent $overridePath) -Force | Out-Null
[IO.File]::WriteAllText($overridePath, $combined, [Text.UTF8Encoding]::new($false))
if ($StageOnly) {
    Copy-Item -LiteralPath $watchdogSource -Destination (Join-Path $InstallRoot 'watchdog.ps1') -Force
} else {
    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    Copy-Item -LiteralPath $watchdogSource -Destination $watchdogPath -Force
}
@{ overrideFile = $overridePath; sourceUrl = $bestUrl; installedAt = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if (-not $StageOnly) {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument (
        '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watchdogPath + '"')
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing -and @($existing.Actions | Where-Object { $_.Arguments -notlike '*THGL-Clean-Layout*watchdog.ps1*' }).Count) {
        throw 'Task name is already used by a different command. Refusing to replace it.'
    }
    if ($existing) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Keep TH.GL dashboard and AION 2 overlay CSS Local Overrides active.' | Out-Null
    Start-ScheduledTask -TaskName $taskName
}
Write-Host ''
Write-Host '================ TH.GL Clean Layout ================'
Write-Host 'The CSS override file was created automatically.'
Write-Host 'You do NOT need to add or drag files into DevTools.'
Write-Host ''
Write-Host 'SELECT THIS FOLDER in DevTools > Sources > Overrides:'
Write-Host "  $InstallRoot"
Write-Host ''
Write-Host 'File created inside that folder:'
Write-Host "  $overridePath"
Write-Host ''
if ($StageOnly) {
    Write-Host 'Stage-only test completed. No scheduled task created.'
} else {
    Write-Host 'Next: TH.GL > Settings > Developer Tools > dashboard'
    Write-Host '  Sources > left-side More tabs > Overrides > Select folder for overrides'
    Write-Host '  Choose the folder above > Select Folder > Allow > check Local overrides.'
    Write-Host '  Then start AION 2 and repeat for aion2 (overlay) using the SAME folder.'
    Write-Host '  If Local overrides is already checked and the correct folder is shown, skip it.'
    Write-Host 'Auto-start task installed. See README for the full guide.'
}
Write-Host '===================================================='
