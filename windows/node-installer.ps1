param(
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"

# PATH 与环境广播等共用逻辑
. "$PSScriptRoot\path-utils.ps1"

$NodeVersion = "24.15.0"
$NodePublisher = "Node.js Foundation"
$NodeZipUrl = "https://registry.npmmirror.com/-/binary/node/v24.15.0/node-v24.15.0-win-x64.zip"
$InstallDir = Join-Path (Get-ProgramFilesNodeInstallRoot) "nodejs"
$InstallerDir = Join-Path $InstallDir "installer"
$UninstallRegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OpenClawNodeJs"
$NodeRegKey = "HKLM:\SOFTWARE\Node.js"

# 安装 Machine 路径与卸载入口需要管理员
function Test-IsAdmin {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 非管理员：拉起新的提升进程（当前进程退出；勿用 $args 作变量名）
function Start-ElevatedSelf {
    [CmdletBinding()]
    param()
    $elevatedSpawnArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Elevated"
    )
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList $elevatedSpawnArgs -Verb RunAs | Out-Null
    }
    catch {
        throw "Administrator rights required (UAC cancelled or elevation failed)."
    }
}

if (-not (Test-IsAdmin)) {
    Start-ElevatedSelf
    exit 0
}

# 旧版 Windows/默认 TLS 可能拉不下 HTTPS
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
}

# 临时目录：成功后 finally 删除；异常时也清理
$tempRoot = Join-Path -Path $env:TEMP -ChildPath ("node-installer-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path -Path $tempRoot -ChildPath "node.zip"
$extractDir = Join-Path -Path $tempRoot -ChildPath "extract"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    # PS 5.1：UseBasicParsing 减少 IE 引擎依赖
    Invoke-WebRequest -Uri $NodeZipUrl -OutFile $zipPath -UseBasicParsing

    # PS 5+ 自带 Expand-Archive；极旧环境回退 .NET ZipFile
    if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    }
    else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
    }

    $rootEntries = Get-ChildItem -Path $extractDir
    if ($rootEntries.Count -ne 1 -or -not $rootEntries[0].PSIsContainer) {
        throw "Unexpected ZIP layout (expected one top-level folder)."
    }

    $packageRoot = $rootEntries[0].FullName

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $packageRoot "*") -Destination $InstallDir -Recurse -Force

    # 安装目录内保留脚本副本：卸载不依赖仓库路径；path-utils 供卸载器 dot-source
    New-Item -ItemType Directory -Path $InstallerDir -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot "node-installer.ps1") -Destination (Join-Path $InstallerDir "node-installer.ps1") -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "node-uninstaller.ps1") -Destination (Join-Path $InstallerDir "node-uninstaller.ps1") -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "path-utils.ps1") -Destination (Join-Path $InstallerDir "path-utils.ps1") -Force

    $uninstallScriptPath = Join-Path $InstallerDir "node-uninstaller.ps1"
    $uninstallCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScriptPath`""

    # 「应用和功能」列表与静默卸载字符串
    New-Item -Path $UninstallRegKey -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "DisplayName" -Value "Node.js" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "DisplayVersion" -Value $NodeVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "Publisher" -Value $NodePublisher -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "InstallLocation" -Value $InstallDir -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "UninstallString" -Value $uninstallCmd -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "QuietUninstallString" -Value "$uninstallCmd -Quiet" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $UninstallRegKey -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null

    New-Item -Path $NodeRegKey -Force | Out-Null
    New-ItemProperty -Path $NodeRegKey -Name "InstallPath" -Value $InstallDir -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $NodeRegKey -Name "Version" -Value $NodeVersion -PropertyType String -Force | Out-Null

    # node.exe：Machine；npm 全局 bin：User（与官方 zip 行为一致）
    Add-PathEntryIfMissing -Scope Machine -Entry $InstallDir
    Add-PathEntryIfMissing -Scope User -Entry (Join-Path $env:APPDATA "npm")
    Send-EnvironmentChangeBroadcast

    if (-not (Test-Path (Join-Path $InstallDir "node.exe"))) {
        throw "node.exe missing after install."
    }

    Write-Output ("Node.js v{0} installed." -f $NodeVersion)
}
finally {
    # 清理下载与解压目录（不论成功失败）
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
