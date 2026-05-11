$ErrorActionPreference = "Stop"
Get-ChildItem -Path (Join-Path $PSScriptRoot "../dist") -Filter *.ps1 -File | ForEach-Object {
    $c = Get-Content -Raw -LiteralPath $_.FullName
    $t = $null
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($c, [ref]$t, [ref]$e)
    if (@($e).Count -gt 0) {
        $e | ForEach-Object { Write-Error $_ }
        exit 1
    }
    Write-Host "OK $($_.Name)"
}
