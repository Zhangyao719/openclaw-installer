param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Compress-BlankLines {
    param([string]$Text)
    $lines = $Text -split "`r?`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $lines.Count) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) {
            $j = $i
            while ($j -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$j])) { $j++ }
            $runLen = $j - $i
            if ($runLen -ge 3) {
                $out.Add("")
            }
            else {
                for ($k = $i; $k -lt $j; $k++) { $out.Add($lines[$k]) }
            }
            $i = $j
        }
        else {
            $out.Add($lines[$i])
            $i++
        }
    }
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[0])) { [void]$out.RemoveAt(0) }
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { [void]$out.RemoveAt($out.Count - 1) }
    return ($out -join "`n")
}

$rawBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SourcePath))
if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
    $content = [System.Text.Encoding]::UTF8.GetString($rawBytes, 3, $rawBytes.Length - 3)
}
else {
    $content = [System.Text.Encoding]::UTF8.GetString($rawBytes)
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    foreach ($e in $parseErrors) {
        Write-Error $e.Message
    }
    exit 1
}

$kindComment = [System.Management.Automation.Language.TokenKind]::Comment
$comments = @($tokens | Where-Object { $_.Kind -eq $kindComment } | Sort-Object { $_.Extent.StartOffset })
$outText = $content
foreach ($c in ($comments | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    $s = $c.Extent.StartOffset
    $len = $c.Extent.EndOffset - $s
    if ($len -gt 0 -and $s -ge 0 -and $s + $len -le $outText.Length) {
        $outText = $outText.Remove($s, $len)
    }
}
$outText = Compress-BlankLines -Text $outText
if (-not $outText.EndsWith("`n")) {
    $outText += "`n"
}

$resolvedDest = [System.IO.Path]::GetFullPath($DestPath)
$dir = [System.IO.Path]::GetDirectoryName($resolvedDest)
if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($resolvedDest, $outText, $utf8Bom)
