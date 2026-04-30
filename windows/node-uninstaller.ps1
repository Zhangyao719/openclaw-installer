param(
    [switch]$Elevated,
    [switch]$FromTemp,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# 与安装器共用的 PATH 与广播
. "$PSScriptRoot\path-utils.ps1"

$InstallDir = Join-Path (Get-ProgramFilesNodeInstallRoot) "nodejs"
$InstallerDir = Join-Path $InstallDir "installer"
$UninstallRegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OpenClawNodeJs"
$NodeRegKey = "HKLM:\SOFTWARE\Node.js"

function Test-IsAdmin {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedSelf {
    [CmdletBinding()]
    param(
        [switch]$FromTempFlag,
        [switch]$QuietFlag
    )

    $elevatedSpawnArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Elevated"
    )
    if ($FromTempFlag) { $elevatedSpawnArgs += "-FromTemp" }
    if ($QuietFlag) { $elevatedSpawnArgs += "-Quiet" }

    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList $elevatedSpawnArgs -Verb RunAs | Out-Null
    }
    catch {
        throw "Administrator rights required (UAC cancelled or elevation failed)."
    }
}

# 从安装目录运行时：先复制到 %TEMP% 再启动新进程，否则无法删除安装目录下的自身脚本
if (-not $FromTemp -and $PSCommandPath.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    $tempDir = Join-Path $env:TEMP ("node-uninstaller-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $tempScript = Join-Path $tempDir "node-uninstaller.ps1"
    Copy-Item -Path $PSCommandPath -Destination $tempScript -Force
    # 临时副本必须带上 path-utils.ps1（与本脚本同目录 dot-source）
    $utilsSrc = Join-Path $PSScriptRoot "path-utils.ps1"
    if (Test-Path $utilsSrc) {
        Copy-Item -Path $utilsSrc -Destination (Join-Path $tempDir "path-utils.ps1") -Force
    }
    $spawnArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$tempScript`"",
        "-FromTemp"
    )
    if ($Quiet) { $spawnArgs += "-Quiet" }
    Start-Process -FilePath "powershell.exe" -ArgumentList $spawnArgs | Out-Null
    exit 0
}

if (-not (Test-IsAdmin)) {
    Start-ElevatedSelf -FromTempFlag:$FromTemp -QuietFlag:$Quiet
    exit 0
}

try {
    # 先改 PATH/广播，再删目录（避免后续工具找不到路径时的困惑；删目录失败时 PATH 已收敛）
    Remove-PathEntryIfExists -Scope Machine -Entry $InstallDir
    Remove-PathEntryIfExists -Scope User -Entry (Join-Path $env:APPDATA "npm")
    Send-EnvironmentChangeBroadcast

    if (Test-Path $UninstallRegKey) {
        Remove-Item -Path $UninstallRegKey -Recurse -Force
    }
    if (Test-Path $NodeRegKey) {
        Remove-Item -Path $NodeRegKey -Recurse -Force
    }

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }

    if (-not $Quiet) {
        Write-Output "Node.js uninstalled."
    }
}
finally {
    # -FromTemp：删除临时目录中的卸载脚本副本
    if ($FromTemp -and (Test-Path $PSCommandPath)) {
        Remove-Item -Path $PSCommandPath -Force -ErrorAction SilentlyContinue
    }
}
