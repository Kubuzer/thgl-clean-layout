# All HTTP is synthetic. Failures exercise the real installer's rollback paths.
$ErrorActionPreference = 'Stop'
function Invoke-WebRequest {
    param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $MaximumRedirection)
    if ($MaximumRedirection -ne 0) { throw 'Fixture requires redirects disabled.' }
    $small = "https://static.th.gl/_next/static/chunks/small$env:THGL_TEST_PHASE.css"
    $large = 'https://static.th.gl/_next/static/chunks/large.css'
    switch ($Uri) {
        'https://app.th.gl/dashboard' { return @{Content = "<link href='$large'><link href='$small'>"} }
        $small {
            $content = 'body { color: black; }'
            $type = 'text/css; charset=utf-8'
            if ($env:THGL_TEST_RESPONSE -eq 'changed') { $content = 'body { color: red; }' }
            if ($env:THGL_TEST_RESPONSE -eq 'html') { $content = '<!doctype html><title>Maintenance</title>'; $type = 'text/html' }
            if ($env:THGL_TEST_RESPONSE -eq 'empty') { $content = '' }
            if ($env:THGL_TEST_RESPONSE -eq 'wrong-type') { $type = 'application/octet-stream' }
            return @{Content = $content; Headers = @{'Content-Type'=$type}}
        }
        $large { return @{Content = ('/* larger shared stylesheet */' * 20); Headers = @{'Content-Type'='text/css'}} }
        default { throw "Unexpected request: $Uri" }
    }
}
function New-Item {
    param($ItemType, $Path, [switch]$Force)
    if ($env:THGL_TEST_FAIL_WRITE -eq '1' -and $Path -eq $env:THGL_TEST_ROOT) {
        throw 'Injected watchdog write failure'
    }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function Remove-Item {
    param($LiteralPath, [switch]$Force, $ErrorAction)
    if ($env:THGL_TEST_FAIL_DELETE -eq '1' -and (Split-Path -Leaf $LiteralPath) -eq 'small1.css') {
        throw 'Injected CSS deletion failure'
    }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
$arguments = @{StageOnly=$true; InstallRoot=$env:THGL_TEST_ROOT}
if ($env:THGL_TEST_UNINSTALL -eq '1') { $arguments.Uninstall = $true }
& (Join-Path $env:THGL_TEST_REPO 'install.ps1') @arguments
