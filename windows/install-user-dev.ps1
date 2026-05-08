# OpenClaw Installer for Windows
# Usage: powershell -c "irm https://openclaw.ai/install.ps1 | iex"
#        powershell -c "& ([scriptblock]::Create(((irm https://openclaw.ai/install.ps1).TrimStart([char]0xFEFF)))) -Tag beta -DryRun"
# 远程一键：字符串首字符若为 UTF-8 BOM（U+FEFF），5.1 下 iex 会误解析 param；须 TrimStart：
#   iex ((irm 'https://raw.githubusercontent.com/Zhangyao719/openclaw-installer/main/windows/install.ps1').TrimStart([char]0xFEFF))
#   iex ((iwr -UseBasicParsing 'https://raw.githubusercontent.com/Zhangyao719/openclaw-installer/main/windows/install.ps1').Content.TrimStart([char]0xFEFF))
# 勿用 `iwr ... | iex`（管道传入的是响应对象）。
#
# 流程总览（主入口：Main）
# 0 前置       — 参数、环境变量、退出码、横幅、PowerShell 版本、脚本执行策略、默认 GitDir
# 1 Node.js    — 1.1 检测版本；1.2 自动安装；1.3 设置 npm 淘宝镜像 1.4 已有安装 — 是否已存在 openclaw（升级判断）
# 2 Git        — 2.1 检测；2.2 进程 PATH；2.3 便携目录与 git.exe；2.4 启用便携；2.5 解析 MinGit；2.6 安装便携；2.7 确保可用
# 3 命令与 PATH — openclaw/npm/pnpm 路径、调用、全局 bin、补全 PATH、确保 pnpm
# 4 安装本体   — 4.1 npm 包说明；4.2 npm 全局安装；4.3 Git 源码克隆构建；4.4.1/4.4.2 遗留子模块目录解析与删除；
# 5 装后       — 5.1 doctor 迁移；5.2 网关服务刷新；5.3 onboard 向导；5.4 配置 Hooks；5.5 预装 Skills（全新安装）；
# 6 Main       — 主函数
# 7 Dashboard  — 获取并打开链接

param(
    [string]$Tag = "latest",
    [ValidateSet("npm", "git")]
    [string]$InstallMethod = "npm",
    [string]$GitDir,
    [switch]$NoGitUpdate,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# 0 前置
# -----------------------------------------------------------------------------

$script:InstallExitCode = 0

# 工具函数——记录失败退出码，供 Complete-Install 使用。
function Fail-Install {
    param([int]$Code = 1)

    $script:InstallExitCode = $Code
    return $false
}

# 工具函数——安装结束：失败时 exit 或抛错（是否为本脚本直接运行取决于 PSCommandPath）。
function Complete-Install {
    param([bool]$Succeeded)

    if ($Succeeded) {
        return
    }

    if ($PSCommandPath) {
        exit $script:InstallExitCode
    }

    throw "OpenClaw installation failed with exit code $($script:InstallExitCode)."
}

# 工具函数——向用户提出 Yes/No 问题，支持默认值，返回 $true 表示 Yes，$false 表示 No
function Ask-YesNo {
    param(
        [string]$Prompt,          # 要显示的提示文本
        [string]$Default = "Y"    # 默认选项，如果直接回车则采用此值（"Y" 或 "N"）
    )
    $hint = if ($Default -eq "Y") { "(Y/n)" } else { "(y/N)" }
    $answer = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    return $answer -match '^[Yy]'
}

# 获取当前 PowerShell 执行策略
function Get-ExecutionPolicyStatus {
    $policy = Get-ExecutionPolicy
    # Restricted: 几乎禁止脚本
    # AllSigned: npm 自带脚本往往未按本机信任链签名，实务上常等同于阻塞
    if ($policy -eq "Restricted" -or $policy -eq "AllSigned") {
        return @{ Blocked = $true; Policy = $policy } # 脚本执行受限
    }
    return @{ Blocked = $false; Policy = $policy } # 脚本执行不受限
}

# 确保 PowerShell 执行策略为 RemoteSigned
function Ensure-ExecutionPolicy {
    $status = Get-ExecutionPolicyStatus
    if ($status.Blocked) {
        Write-Host "PowerShell 执行策略已设置为: $($status.Policy)" -ForegroundColor Yellow
        Write-Host "这会阻止 npm.ps1 等脚本的运行。" -ForegroundColor Yellow
        Write-Host ""
        try {
            # Scope Process：只影响当前 powershell 进程，不写持久 Machine/User 策略，退出会话后即失效。
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -ErrorAction Stop
            Write-Host "[OK] 已将 PowerShell 执行策略设置为 RemoteSigned" -ForegroundColor Green
            return $true
        }
        catch {
            # 组策略或权限禁止改写时：提示用户在本进程或管理员下手动放宽。
            Write-Host "无法自动设置 PowerShell 执行策略" -ForegroundColor Red
            Write-Host ""
            Write-Host "要修复此问题，请运行:" -ForegroundColor Gray
            Write-Host "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "或者以管理员身份运行 PowerShell 并执行:" -ForegroundColor Gray
            Write-Host "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine" -ForegroundColor Cyan
            Write-Host ""
            return $false
        }
    }
    # 策略原本即宽松（如 RemoteSigned），无需改动。
    return $true
}

Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║                                                           ║" -ForegroundColor Cyan
Write-Host "  ║          🦞  OpenClaw Easy Deploy  🦞                     ║" -ForegroundColor Cyan
Write-Host "  ║                                                           ║" -ForegroundColor Cyan
Write-Host "  ║     让 OpenClaw 部署变得简单 - 零技术门槛，一键安装       ║" -ForegroundColor Cyan
Write-Host "  ║                                                           ║" -ForegroundColor Cyan
Write-Host "  ║                    猫鼬AI出品                             ║" -ForegroundColor Cyan
Write-Host "  ╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check if running in PowerShell
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "Error: PowerShell 5+ required" -ForegroundColor Red
    Complete-Install -Succeeded:$false
    return
}

Write-Host "[OK] Windows detected" -ForegroundColor Green

if (-not $PSBoundParameters.ContainsKey("InstallMethod")) {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCLAW_INSTALL_METHOD)) {
        $InstallMethod = $env:OPENCLAW_INSTALL_METHOD
    }
}
if (-not $PSBoundParameters.ContainsKey("GitDir")) {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCLAW_GIT_DIR)) {
        $GitDir = $env:OPENCLAW_GIT_DIR
    }
}
if (-not $PSBoundParameters.ContainsKey("NoGitUpdate")) {
    if ($env:OPENCLAW_GIT_UPDATE -eq "0") {
        $NoGitUpdate = $true
    }
}
if (-not $PSBoundParameters.ContainsKey("DryRun")) {
    if ($env:OPENCLAW_DRY_RUN -eq "1") {
        $DryRun = $true
    }
}

if ([string]::IsNullOrWhiteSpace($GitDir)) {
    $userHome = [Environment]::GetFolderPath("UserProfile")
    $GitDir = (Join-Path $userHome "openclaw")
}

# -----------------------------------------------------------------------------
# 1 Node.js
# -----------------------------------------------------------------------------

# 检测本机 Node 是否存在且主版本 >= 22。
function Check-Node {
    try {
        $nodeVersion = (node -v 2>$null)
        if ($nodeVersion) {
            $version = [int]($nodeVersion -replace 'v(\d+)\..*', '$1')
            if ($version -ge 22) {
                Write-Host "[OK] Node.js $nodeVersion found" -ForegroundColor Green
                return $true
            }
            else {
                Write-Host "[!] Node.js $nodeVersion found, but v22+ required" -ForegroundColor Yellow
                return $false
            }
        }
    }
    catch {
        Write-Host "[!] Node.js not found" -ForegroundColor Yellow
        return $false
    }
    return $false
}

# 依次尝试 winget / Chocolatey / Scoop 安装 Node LTS；失败则提示手动安装。
function Install-Node {
    Write-Host "[*] Installing Node.js..." -ForegroundColor Yellow

    # Try winget first (Windows 11 / Windows 10 with App Installer)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  Using winget..." -ForegroundColor Gray
        winget install OpenJS.NodeJS.LTS --source winget --accept-package-agreements --accept-source-agreements

        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        if (Check-Node) {
            Write-Host "[OK] Node.js installed via winget" -ForegroundColor Green
            return $true
        }
        Write-Host "[!] winget completed, but Node.js is still unavailable in this shell" -ForegroundColor Yellow
        Write-Host "Restart PowerShell and re-run the installer if Node.js was installed successfully." -ForegroundColor Yellow
        return $false
    }

    # Try Chocolatey
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  Using Chocolatey..." -ForegroundColor Gray
        choco install nodejs-lts -y

        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Host "[OK] Node.js installed via Chocolatey" -ForegroundColor Green
        return $true
    }

    # Try Scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "  Using Scoop..." -ForegroundColor Gray
        scoop install nodejs-lts
        Write-Host "[OK] Node.js installed via Scoop" -ForegroundColor Green
        return $true
    }

    # 引导手动安装
    Write-Host ""
    Write-Host "无法自动安装 Node.js，请手动安装："
    Write-Host "  1. 点击下载: https://registry.npmmirror.com/-/binary/node/v24.15.0/node-v24.15.0-x64.msi" -ForegroundColor Yellow
    Write-Host "  2. 运行 node-v24.15.0-x64.msi 安装包" -ForegroundColor Yellow
    Write-Host ""
    $open = Ask-YesNo "是否现在打开 Node.js 下载页面?"
    if ($open) {
        Start-Process "https://registry.npmmirror.com/-/binary/node/v24.15.0/node-v24.15.0-x64.msi"
    }
    return $false
}

# 将 npm 源切换为淘宝镜像；失败只警告，不阻断安装。
function Set-NpmRegistry {
    $registry = "https://registry.npmmirror.com/"
    Write-Host "[*] Setting npm registry to $registry ..." -ForegroundColor Yellow
    try {
        & (Get-NpmCommandPath) config set registry $registry
        Write-Host "[OK] npm registry set to $registry" -ForegroundColor Green
    }
    catch {
        Write-Host "[!] Failed to set npm registry: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}


# 判断是否已安装 OpenClaw
function Check-ExistingOpenClaw {
    if (Get-OpenClawCommandPath) {
        # PATH 上存在 openclaw 相关命令 -> 升级场景
        Write-Host "[*] Existing OpenClaw installation detected" -ForegroundColor Yellow
        return $true
    }
    # 不存在 -> 全新安装
    return $false
}

# -----------------------------------------------------------------------------
# 2 Git
# -----------------------------------------------------------------------------

# 检测当前进程能否调用 git。
function Check-Git {
    try {
        $null = Get-Command git -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# 将目录prepend到当前进程的 Path（不修改持久化环境变量）。
function Add-ToProcessPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathEntry
    )

    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return
    }

    $currentEntries = @($env:Path -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($currentEntries | Where-Object { $_ -ieq $PathEntry }) {
        return
    }

    $env:Path = "$PathEntry;$env:Path"
}

# 返回便携 Git 的安装根目录（LOCALAPPDATA 下固定路径）。
function Get-PortableGitRoot {
    $base = Join-Path $env:LOCALAPPDATA "OpenClaw\deps"
    return (Join-Path $base "portable-git")
}

# 在便携根目录下查找 git.exe 的实际路径。
function Get-PortableGitCommandPath {
    $root = Get-PortableGitRoot
    foreach ($candidate in @(
            (Join-Path $root "mingw64\bin\git.exe"),
            (Join-Path $root "cmd\git.exe"),
            (Join-Path $root "bin\git.exe"),
            (Join-Path $root "git.exe")
        )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

# 若已存在便携 Git，则注入 PATH 并确认 git 可用。
function Use-PortableGitIfPresent {
    $gitExe = Get-PortableGitCommandPath
    if (-not $gitExe) {
        return $false
    }

    $portableRoot = Get-PortableGitRoot
    foreach ($pathEntry in @(
            (Join-Path $portableRoot "mingw64\bin"),
            (Join-Path $portableRoot "usr\bin"),
            (Split-Path -Parent $gitExe)
        )) {
        if (Test-Path $pathEntry) {
            Add-ToProcessPath $pathEntry
        }
    }
    if (Check-Git) {
        return $true
    }
    return $false
}

# 从 GitHub API 解析最新 MinGit zip 的下载地址与文件名。
function Resolve-PortableGitDownload {
    $releaseApi = "https://api.github.com/repos/git-for-windows/git/releases/latest"
    $headers = @{
        "User-Agent" = "openclaw-installer"
        "Accept"     = "application/vnd.github+json"
    }
    $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers
    if (-not $release -or -not $release.assets) {
        throw "Could not resolve latest git-for-windows release metadata."
    }

    $asset = $release.assets |
    Where-Object { $_.name -match '^MinGit-.*-64-bit\.zip$' -and $_.name -notmatch 'busybox' } |
    Select-Object -First 1

    if (-not $asset) {
        throw "Could not find a MinGit zip asset in the latest git-for-windows release."
    }

    return @{
        Tag  = $release.tag_name
        Name = $asset.name
        Url  = $asset.browser_download_url
    }
}

# 下载并解压 MinGit 到用户目录下的便携路径；已存在则跳过下载。
function Install-PortableGit {
    if (Use-PortableGitIfPresent) {
        $portableVersion = (& git --version 2>$null)
        if ($portableVersion) {
            Write-Host "[OK] User-local Git already available: $portableVersion" -ForegroundColor Green
        }
        return
    }

    Write-Host "[*] Git not found; bootstrapping user-local portable Git..." -ForegroundColor Yellow

    $download = Resolve-PortableGitDownload
    $portableRoot = Get-PortableGitRoot
    $portableParent = Split-Path -Parent $portableRoot
    $tmpZip = Join-Path $env:TEMP $download.Name
    $tmpExtract = Join-Path $env:TEMP ("openclaw-portable-git-" + [guid]::NewGuid().ToString("N"))

    New-Item -ItemType Directory -Force -Path $portableParent | Out-Null
    if (Test-Path $portableRoot) {
        Remove-Item -Recurse -Force $portableRoot
    }
    if (Test-Path $tmpExtract) {
        Remove-Item -Recurse -Force $tmpExtract
    }
    New-Item -ItemType Directory -Force -Path $tmpExtract | Out-Null

    try {
        Write-Host "  Downloading $($download.Tag)..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $download.Url -OutFile $tmpZip
        Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
        Move-Item -Path (Join-Path $tmpExtract "*") -Destination $portableRoot -Force
    }
    finally {
        if (Test-Path $tmpZip) {
            Remove-Item -Force $tmpZip
        }
        if (Test-Path $tmpExtract) {
            Remove-Item -Recurse -Force $tmpExtract
        }
    }

    if (-not (Use-PortableGitIfPresent)) {
        throw "Portable Git bootstrap completed, but git is still unavailable."
    }

    $portableVersion = (& git --version 2>$null)
    Write-Host "[OK] User-local Git ready: $portableVersion" -ForegroundColor Green
}

# 确保 git 可用：系统 PATH、已有便携、或现场安装便携；仍失败则提示手动安装。
function Ensure-Git {
    if (Check-Git) { return $true }
    if (Use-PortableGitIfPresent) { return $true }
    try {
        Install-PortableGit
        if (Check-Git) {
            return $true
        }
    }
    catch {
        Write-Host "[!] Portable Git bootstrap failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Error: Git is required to install OpenClaw." -ForegroundColor Red
    Write-Host "Auto-bootstrap of user-local Git did not succeed." -ForegroundColor Yellow
    Write-Host "Install Git for Windows manually, then re-run this installer:" -ForegroundColor Yellow
    Write-Host "  https://git-scm.com/download/win" -ForegroundColor Cyan
    return $false
}

# -----------------------------------------------------------------------------
# 3 命令与 PATH
# -----------------------------------------------------------------------------

# 解析 openclaw / openclaw.cmd 在 PATH 上的完整路径。
function Get-OpenClawCommandPath {
    $openclawCmd = Get-Command openclaw.cmd -ErrorAction SilentlyContinue
    if ($openclawCmd -and $openclawCmd.Source) {
        return $openclawCmd.Source
    }

    $openclaw = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($openclaw -and $openclaw.Source) {
        return $openclaw.Source
    }

    return $null
}

# 通过已解析的路径调用 openclaw，传入剩余参数。
function Invoke-OpenClawCommand {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $commandPath = Get-OpenClawCommandPath
    if (-not $commandPath) {
        throw "openclaw command not found on PATH."
    }

    & $commandPath @Arguments
}

# 按候选命令名顺序查找第一个可用的可执行文件路径。
function Resolve-CommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            return $command.Source
        }
    }

    return $null
}

# 解析 npm 可执行文件路径（找不到则抛错）。
function Get-NpmCommandPath {
    $path = Resolve-CommandPath -Candidates @("npm.cmd", "npm.exe", "npm")
    if (-not $path) {
        throw "npm not found on PATH."
    }
    return $path
}

# 解析 corepack 可执行文件路径（可选，可能为 null）。
function Get-CorepackCommandPath {
    return (Resolve-CommandPath -Candidates @("corepack.cmd", "corepack.exe", "corepack"))
}

# 解析 pnpm 可执行文件路径（可选，可能为 null）。
function Get-PnpmCommandPath {
    return (Resolve-CommandPath -Candidates @("pnpm.cmd", "pnpm.exe", "pnpm"))
}

# 汇总 npm 全局可执行目录的可能路径（prefix、prefix/bin、APPDATA/npm）。
function Get-NpmGlobalBinCandidates {
    param(
        [string]$NpmPrefix
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($NpmPrefix)) {
        $candidates += $NpmPrefix
        $candidates += (Join-Path $NpmPrefix "bin")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $candidates += (Join-Path $env:APPDATA "npm")
    }

    return $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

# 若尚未找到 openclaw，根据 npm 全局目录尝试把含 openclaw.cmd 的路径写入用户 PATH。
function Ensure-OpenClawOnPath {
    if (Get-OpenClawCommandPath) {
        return $true
    }

    $npmPrefix = $null
    try {
        $npmPrefix = (& (Get-NpmCommandPath) config get prefix 2>$null).Trim()
    }
    catch {
        $npmPrefix = $null
    }

    $npmBins = Get-NpmGlobalBinCandidates -NpmPrefix $npmPrefix
    foreach ($npmBin in $npmBins) {
        if (-not (Test-Path (Join-Path $npmBin "openclaw.cmd"))) {
            continue
        }

        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if (-not ($userPath -split ";" | Where-Object { $_ -ieq $npmBin })) {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$npmBin", "User")
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host "[!] Added $npmBin to user PATH (restart terminal if command not found)" -ForegroundColor Yellow
        }
        return $true
    }

    Write-Host "[!] openclaw is not on PATH yet." -ForegroundColor Yellow
    Write-Host "Restart PowerShell or add the npm global install folder to PATH." -ForegroundColor Yellow
    if ($npmBins.Count -gt 0) {
        Write-Host "Expected path (one of):" -ForegroundColor Gray
        foreach ($npmBin in $npmBins) {
            Write-Host "  $npmBin" -ForegroundColor Cyan
        }
    }
    else {
        Write-Host "Hint: run \"npm config get prefix\" to find your npm global path." -ForegroundColor Gray
    }
    return $false
}

# 确保 pnpm 存在：优先 corepack；否则 npm 全局安装。
function Ensure-Pnpm {
    if (Get-PnpmCommandPath) {
        return
    }
    $corepackCommand = Get-CorepackCommandPath
    if ($corepackCommand) {
        try {
            & $corepackCommand enable | Out-Null
            & $corepackCommand prepare pnpm@latest --activate | Out-Null
            if (Get-PnpmCommandPath) {
                Write-Host "[OK] pnpm installed via corepack" -ForegroundColor Green
                return
            }
        }
        catch {
            # fallthrough to npm install
        }
    }
    Write-Host "[*] Installing pnpm..." -ForegroundColor Yellow
    $prevScriptShell = $env:NPM_CONFIG_SCRIPT_SHELL
    $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"
    try {
        & (Get-NpmCommandPath) install -g pnpm
    }
    finally {
        $env:NPM_CONFIG_SCRIPT_SHELL = $prevScriptShell
    }
    Write-Host "[OK] pnpm installed" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 4 安装 OpenClaw 本体
# -----------------------------------------------------------------------------

#将 Tag/显式 spec 转为 npm 可安装的包说明字符串。
function Resolve-NpmOpenClawInstallSpec {
    param(
        [string]$PackageName,
        [string]$RequestedTag
    )

    if ([string]::IsNullOrWhiteSpace($RequestedTag)) {
        return "$PackageName@latest"
    }

    $trimmedTag = $RequestedTag.Trim()
    if (
        $trimmedTag -match '^(https?|file):' -or
        $trimmedTag -match '^(git\+|github:)' -or
        $trimmedTag -match '^[A-Za-z]:[\\/]' -or
        $trimmedTag -match '^\\\\' -or
        $trimmedTag -match '^\.\.?[\\/]' -or
        $trimmedTag -match '\.tgz($|[?#])'
    ) {
        return $trimmedTag
    }

    return "$PackageName@$trimmedTag"
}

# 使用 npm 全局安装 OpenClaw（临时收紧 npm 输出与环境变量）。
function Install-OpenClaw {
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        $Tag = "latest"
    }
    if (-not (Ensure-Git)) {
        return $false
    }

    # Use openclaw package for beta, openclaw for stable
    $packageName = "openclaw"
    if ($Tag -eq "beta" -or $Tag -match "^beta\.") {
        $packageName = "openclaw"
    }
    $installSpec = Resolve-NpmOpenClawInstallSpec -PackageName $packageName -RequestedTag $Tag
    Write-Host "[*] 正在安装 OpenClaw ($installSpec)..." -ForegroundColor Yellow
    $prevLogLevel = $env:NPM_CONFIG_LOGLEVEL
    $prevUpdateNotifier = $env:NPM_CONFIG_UPDATE_NOTIFIER
    $prevFund = $env:NPM_CONFIG_FUND
    $prevAudit = $env:NPM_CONFIG_AUDIT
    $prevScriptShell = $env:NPM_CONFIG_SCRIPT_SHELL
    $prevNodeLlamaSkipDownload = $env:NODE_LLAMA_CPP_SKIP_DOWNLOAD
    $env:NPM_CONFIG_LOGLEVEL = "error"
    $env:NPM_CONFIG_UPDATE_NOTIFIER = "false"
    $env:NPM_CONFIG_FUND = "false"
    $env:NPM_CONFIG_AUDIT = "false"
    $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"
    $env:NODE_LLAMA_CPP_SKIP_DOWNLOAD = "1"
    try {
        $npmOutput = & (Get-NpmCommandPath) install -g "$installSpec" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[!] npm install failed" -ForegroundColor Red
            if ($npmOutput -match "spawn git" -or $npmOutput -match "ENOENT.*git") {
                Write-Host "Error: git is missing from PATH." -ForegroundColor Red
                Write-Host "Install Git for Windows, then reopen PowerShell and retry:" -ForegroundColor Yellow
                Write-Host "  https://git-scm.com/download/win" -ForegroundColor Cyan
            }
            else {
                Write-Host "Re-run with verbose output to see the full error:" -ForegroundColor Yellow
                Write-Host '  powershell -c "iex ((irm https://openclaw.ai/install.ps1).TrimStart([char]0xFEFF))"' -ForegroundColor Cyan
            }
            $npmOutput | ForEach-Object { Write-Host $_ }
            return $false
        }
    }
    finally {
        $env:NPM_CONFIG_LOGLEVEL = $prevLogLevel
        $env:NPM_CONFIG_UPDATE_NOTIFIER = $prevUpdateNotifier
        $env:NPM_CONFIG_FUND = $prevFund
        $env:NPM_CONFIG_AUDIT = $prevAudit
        $env:NPM_CONFIG_SCRIPT_SHELL = $prevScriptShell
        $env:NODE_LLAMA_CPP_SKIP_DOWNLOAD = $prevNodeLlamaSkipDownload
    }
    Write-Host "[OK] OpenClaw 已安装" -ForegroundColor Green
    return $true
}

# 克隆或更新仓库，pnpm 安装/构建/UI，生成 ~/.local/bin/openclaw.cmd 并写入 PATH。
function Install-OpenClawFromGit {
    param(
        [string]$RepoDir,
        [switch]$SkipUpdate
    )
    if (-not (Ensure-Git)) {
        return $false
    }
    Ensure-Pnpm

    $repoUrl = "https://github.com/openclaw/openclaw.git"
    Write-Host "[*] Installing OpenClaw from GitHub ($repoUrl)..." -ForegroundColor Yellow

    if (-not (Test-Path $RepoDir)) {
        git clone $repoUrl $RepoDir
    }

    if (-not $SkipUpdate) {
        if (-not (git -C $RepoDir status --porcelain 2>$null)) {
            git -C $RepoDir pull --rebase 2>$null
        }
        else {
            Write-Host "[!] Repo is dirty; skipping git pull" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[!] Git update disabled; skipping git pull" -ForegroundColor Yellow
    }

    Remove-LegacySubmodule -RepoDir $RepoDir

    $prevPnpmScriptShell = $env:NPM_CONFIG_SCRIPT_SHELL
    $pnpmCommand = Get-PnpmCommandPath
    if (-not $pnpmCommand) {
        throw "pnpm not found after installation."
    }
    $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"
    try {
        & $pnpmCommand -C $RepoDir install
        if (-not (& $pnpmCommand -C $RepoDir ui:build)) {
            Write-Host "[!] UI build failed; continuing (CLI may still work)" -ForegroundColor Yellow
        }
        & $pnpmCommand -C $RepoDir build
    }
    finally {
        $env:NPM_CONFIG_SCRIPT_SHELL = $prevPnpmScriptShell
    }

    $binDir = Join-Path $env:USERPROFILE ".local\\bin"
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    }
    $cmdPath = Join-Path $binDir "openclaw.cmd"
    $cmdContents = "@echo off`r`nnode ""$RepoDir\\dist\\entry.js"" %*`r`n"
    Set-Content -Path $cmdPath -Value $cmdContents -NoNewline

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not ($userPath -split ";" | Where-Object { $_ -ieq $binDir })) {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Host "[!] Added $binDir to user PATH (restart terminal if command not found)" -ForegroundColor Yellow
    }

    Write-Host "[OK] OpenClaw wrapper installed to $cmdPath" -ForegroundColor Green
    Write-Host "[i] This checkout uses pnpm. For deps, run: pnpm install (avoid npm install in the repo)." -ForegroundColor Gray
    return $true
}

# 解析遗留清理所用的仓库目录（环境变量 OPENCLAW_GIT_DIR 或 ~/openclaw）。
function Get-LegacyRepoDir {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCLAW_GIT_DIR)) {
        return $env:OPENCLAW_GIT_DIR
    }
    $userHome = [Environment]::GetFolderPath("UserProfile")
    return (Join-Path $userHome "openclaw")
}

# 删除仓库内旧版 Peekaboo 子模块目录（若存在）。
function Remove-LegacySubmodule {
    param(
        [string]$RepoDir
    )
    if ([string]::IsNullOrWhiteSpace($RepoDir)) {
        $RepoDir = Get-LegacyRepoDir
    }
    $legacyDir = Join-Path $RepoDir "Peekaboo"
    if (Test-Path $legacyDir) {
        Write-Host "[!] Removing legacy submodule checkout: $legacyDir" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $legacyDir
    }
}

# -----------------------------------------------------------------------------
# 5 装后处理
# -----------------------------------------------------------------------------

# 非交互运行 openclaw doctor，用于配置迁移（忽略错误）。
function Run-Doctor {
    Write-Host "[*] 运行 doctor 程序以迁移设置..." -ForegroundColor Yellow
    try {
        Invoke-OpenClawCommand doctor --non-interactive
    }
    catch {
        # Ignore errors from doctor
    }
    Write-Host "[OK] Migration complete" -ForegroundColor Green
}

# 通过 daemon status --json 判断网关服务是否已加载。
function Test-GatewayServiceLoaded {
    try {
        $statusJson = (Invoke-OpenClawCommand daemon status --json 2>$null)
        if ([string]::IsNullOrWhiteSpace($statusJson)) {
            return $false
        }
        $parsed = $statusJson | ConvertFrom-Json
        if ($parsed -and $parsed.service -and $parsed.service.loaded) {
            return $true
        }
    }
    catch {
        return $false
    }
    return $false
}

# 若网关已在运行，则强制重装配置并尝试重启服务。
function Refresh-GatewayServiceIfLoaded {
    if (-not (Get-OpenClawCommandPath)) {
        return
    }
    if (-not (Test-GatewayServiceLoaded)) {
        return
    }

    Write-Host "[*] Refreshing loaded gateway service..." -ForegroundColor Yellow
    try {
        Invoke-OpenClawCommand gateway install --force | Out-Null
    }
    catch {
        Write-Host "[!] Gateway service refresh failed; continuing." -ForegroundColor Yellow
        return
    }

    try {
        Invoke-OpenClawCommand gateway restart | Out-Null
        Invoke-OpenClawCommand gateway status --json | Out-Null
        Write-Host "[OK] Gateway service refreshed" -ForegroundColor Green
    }
    catch {
        Write-Host "[!] Gateway service restart failed; continuing." -ForegroundColor Yellow
    }
}

# 用 `openclaw health --json` 检测网关是否健康运行：
#   - 命令退出码非零 → 不健康
#   - JSON 中 ok 字段为 false → 不健康
function Test-GatewayHealthy {
    $commandPath = Get-OpenClawCommandPath
    if (-not $commandPath) {
        return $false
    }

    $ErrorActionPreference = "Continue"
    $output = & $commandPath health --json 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"

    if ($exitCode -ne 0) {
        return $false
    }

    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    try {
        $json = $text | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains "ok") {
            return ($json.ok -eq $true)
        }
        return $true
    }
    catch {
        return $false
    }
}

# onboard 向导
function Invoke-OnboardWizard {
    $choiceToApiKeyParam = @{
        'custom-api-key'       = '--custom-api-key'
        'moonshot-api-key'     = '--moonshot-api-key'
        'moonshot-api-key-cn'  = '--moonshot-api-key'
        'kimi-code-api-key'    = '--kimi-code-api-key'
        'zai-api-key'          = '--zai-api-key'
        'zai-coding-global'    = '--zai-api-key'
        'zai-coding-cn'        = '--zai-api-key'
        'zai-global'           = '--zai-api-key'
        'zai-cn'               = '--zai-api-key'
        'minimax-global-api'   = '--minimax-api-key'
        'minimax-global-oauth' = '--minimax-api-key'
        'minimax-cn-oauth'     = '--minimax-api-key'
        'minimax-cn-api'       = '--minimax-api-key'
        'openai-codex'         = '--openai-api-key'
        'openai-api-key'       = '--openai-api-key'
    }

    $groups = [ordered]@{
        '自定义'         = @('custom-api-key')
        'MoonShot'    = @('moonshot-api-key', 'moonshot-api-key-cn')
        'Kimi Coding' = @('kimi-code-api-key')
        '智谱 (ZAI)'    = @('zai-api-key', 'zai-coding-global', 'zai-coding-cn', 'zai-global', 'zai-cn')
        'MiniMax'     = @('minimax-global-api', 'minimax-global-oauth', 'minimax-cn-oauth', 'minimax-cn-api')
        'OpenAI'      = @('openai-codex', 'openai-api-key')
    }

    $allChoices = [System.Collections.Generic.List[string]]::new()
    foreach ($g in $groups.Values) {
        foreach ($c in $g) { $allChoices.Add($c) }
    }

    Write-Host ""
    Write-Host "━━━ 选择模型认证方式 ━━━" -ForegroundColor Cyan
    $idx = 1
    foreach ($groupName in $groups.Keys) {
        Write-Host ""
        Write-Host "  [$groupName]" -ForegroundColor Yellow
        foreach ($choice in $groups[$groupName]) {
            Write-Host ("  {0,2}. {1}" -f $idx, $choice)
            $idx++
        }
    }
    Write-Host ""

    $selectedChoice = $null
    while ($null -eq $selectedChoice) {
        $raw = Read-Host "请输入编号 (1-$($allChoices.Count))"
        if ($raw -match '^\d+$') {
            $n = [int]$raw
            if ($n -ge 1 -and $n -le $allChoices.Count) {
                $selectedChoice = $allChoices[$n - 1]
            }
        }
        if ($null -eq $selectedChoice) {
            Write-Host "[!] 请输入 1 到 $($allChoices.Count) 之间的数字。" -ForegroundColor Yellow
        }
    }
    Write-Host "[OK] 已选择：$selectedChoice" -ForegroundColor Green

    $apiKeyParam = $choiceToApiKeyParam[$selectedChoice]

    $apiKey = ""
    while ([string]::IsNullOrWhiteSpace($apiKey)) {
        $apiKey = Read-Host "请输入 API Key ($apiKeyParam)"
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Write-Host "[!] API Key 不能为空。" -ForegroundColor Yellow
        }
    }

    $extraArgs = @("--auth-choice", $selectedChoice, $apiKeyParam, $apiKey)

    if ($selectedChoice -eq 'custom-api-key') {
        $baseUrl = ""
        while ([string]::IsNullOrWhiteSpace($baseUrl)) {
            $baseUrl = Read-Host "请输入 Custom Base URL (--custom-base-url)"
            if ([string]::IsNullOrWhiteSpace($baseUrl)) {
                Write-Host "[!] Base URL 不能为空。" -ForegroundColor Yellow
            }
        }

        $modelId = ""
        while ([string]::IsNullOrWhiteSpace($modelId)) {
            $modelId = Read-Host "请输入 Custom Model ID (--custom-model-id)"
            if ([string]::IsNullOrWhiteSpace($modelId)) {
                Write-Host "[!] Model ID 不能为空。" -ForegroundColor Yellow
            }
        }

        $extraArgs += @("--custom-base-url", $baseUrl, "--custom-model-id", $modelId)
    }

    Write-Host ""
    Write-Host "开始执行官方非交互式 onboard 向导，这可能需要几分钟..." -ForegroundColor Cyan
    Write-Host ""

    $onboardArgs = @(
        "onboard",
        "--non-interactive",
        "--accept-risk",
        "--reset",
        "--reset-scope", "full",
        "--flow", "quickstart",
        "--install-daemon",
        "--skip-channels",
        "--skip-skills",
        "--skip-search",
        "--skip-ui",
        "--json"
    ) + $extraArgs

    Invoke-OpenClawCommand @onboardArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "[!] onboard 失败（退出码 $LASTEXITCODE），将跳过 Hooks 与 Skills 安装。" -ForegroundColor Red
        return $false
    }
    return $true
}

function Test-OpenClawSkipHooksEnv {
    return ($env:OPENCLAW_SKIP_HOOKS -eq "1")
}

function Test-HooksConsoleUiAvailable {
    try {
        if ([Console]::IsInputRedirected) {
            return $false
        }
        if ([Console]::IsOutputRedirected) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

# 返回待 enable 的 hook 技术名列表；空列表表示跳过或不选任何 hook。
function Invoke-HooksSelectionUi {
    $items = @(
        @{ Slug = "session-memory"; Line = "session-memory — /new、/reset 时保存会话摘要到 memory/" }
        @{ Slug = "bootstrap-extra-files"; Line = "bootstrap-extra-files — 引导时按 glob 额外注入 AGENTS.md 等" }
        @{ Slug = "command-logger"; Line = "command-logger — 将所有 slash 命令写入 commands.log" }
        @{ Slug = "compaction-notifier"; Line = "compaction-notifier — 会话压缩开始/结束时在聊天中提示" }
        @{ Slug = "boot-md"; Line = "boot-md — 网关启动后执行工作区 BOOT.md" }
        @{ Slug = "_skip"; Line = "跳过 — 暂不启用上述内置 Hooks（与其它选项互斥）" }
    )

    $count = $items.Count
    $selected = New-Object bool[] $count
    $cursor = 0
    $skipIndex = $count - 1

    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "━━━ 选择要启用的内置 Hooks（空格多选，回车确认）━━━" -ForegroundColor Cyan
        Write-Host ""

        for ($i = 0; $i -lt $count; $i++) {
            $arrow = if ($i -eq $cursor) { ">" } else { " " }
            $box = if ($selected[$i]) { "[x]" } else { "[ ]" }
            Write-Host ("  {0} {1} {2}" -f $arrow, $box, $items[$i].Line)
        }

        Write-Host ""
        Write-Host "↑↓ 移动焦点 │ 空格 选中/取消 │ 回车 确认" -ForegroundColor Gray

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            "UpArrow" {
                $cursor = ($cursor + $count - 1) % $count
            }
            "DownArrow" {
                $cursor = ($cursor + 1) % $count
            }
            "Spacebar" {
                if ($cursor -eq $skipIndex) {
                    $flip = -not $selected[$skipIndex]
                    for ($j = 0; $j -lt $count; $j++) {
                        $selected[$j] = $false
                    }
                    $selected[$skipIndex] = $flip
                }
                else {
                    $selected[$skipIndex] = $false
                    $selected[$cursor] = -not $selected[$cursor]
                }
            }
            "Enter" {
                $slugs = [System.Collections.Generic.List[string]]::new()
                if (-not $selected[$skipIndex]) {
                    for ($j = 0; $j -lt $skipIndex; $j++) {
                        if ($selected[$j]) {
                            $slugs.Add($items[$j].Slug)
                        }
                    }
                }
                return @([string[]]$slugs.ToArray())
            }
            Default { }
        }
    }
}

function Invoke-HooksConfigureStep {
    if (Test-OpenClawSkipHooksEnv) {
        Write-Host "[*] 已设置 OPENCLAW_SKIP_HOOKS=1，跳过 Hooks 配置。" -ForegroundColor Gray
        return
    }

    if (-not (Test-HooksConsoleUiAvailable)) {
        Write-Host "[*] 未检测到交互式终端（输入或输出已重定向），跳过 Hooks 配置。" -ForegroundColor Gray
        return
    }

    if (-not (Get-OpenClawCommandPath)) {
        Write-Host "[!] 未找到 openclaw 命令，跳过 Hooks 配置。" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "即将配置内置 Hooks（可在无 TTY 或 OPENCLAW_SKIP_HOOKS=1 时自动跳过）。" -ForegroundColor Cyan

    $prevVisible = $true
    try {
        $prevVisible = [Console]::CursorVisible
        [Console]::CursorVisible = $false
    }
    catch {
        # 部分宿主不支持
    }

    $toEnable = @()
    try {
        $toEnable = Invoke-HooksSelectionUi
    }
    finally {
        try {
            [Console]::CursorVisible = $prevVisible
        }
        catch {
            # ignore
        }
    }

    Write-Host ""

    if ($toEnable.Count -eq 0) {
        Write-Host "[OK] 已跳过 Hooks 启用。" -ForegroundColor Green
        return
    }

    Write-Host "[*] 正在启用选中的 Hooks..." -ForegroundColor Yellow
    $failed = @()

    foreach ($slug in $toEnable) {
        Write-Host "  hooks enable $slug ..." -ForegroundColor Gray
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            Invoke-OpenClawCommand hooks enable $slug
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[!] hooks enable $slug 失败（退出码 $LASTEXITCODE）" -ForegroundColor Yellow
                $failed += $slug
            }
        }
        catch {
            Write-Host "[!] hooks enable ${slug}: $($_.Exception.Message)" -ForegroundColor Yellow
            $failed += $slug
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
    }

    if ($failed.Count -eq 0) {
        Write-Host "[OK] 所选 Hooks 已全部启用。" -ForegroundColor Green
    }
    else {
        Write-Host "[!] 部分 Hooks 启用失败: $($failed -join ', ')" -ForegroundColor Yellow
    }
}

# 从 ClawHub 逐个安装预设 Skills；单个失败只警告不阻断；升级场景不调用。
function Install-Skills {
    $skills = @(
        'self-improving-agent',
        'data-analyst',
        'find-skills',
        'humanizer',
        'markdown-converter',
        'memory-setup',
        'multi-search-engine',
        'nano-pdf',
        'ontology',
        'proactive-agent',
        'skill-vetter',
        'summarize'
    )

    $failed = @()

    Write-Host "[*] Installing Skills..." -ForegroundColor Yellow
    foreach ($slug in $skills) {
        Write-Host "  Installing $slug..." -ForegroundColor Gray
        try {
            Invoke-OpenClawCommand skills install $slug
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[!] Failed to install skill '$slug' (exit code $LASTEXITCODE)" -ForegroundColor Yellow
                $failed += $slug
            }
        }
        catch {
            Write-Host "[!] Failed to install skill '$slug': $($_.Exception.Message)" -ForegroundColor Yellow
            $failed += $slug
        }
    }

    if ($failed.Count -eq 0) {
        Write-Host "[OK] All $($skills.Count) skills installed" -ForegroundColor Green
    }
    else {
        Write-Host "[!] $($skills.Count - $failed.Count)/$($skills.Count) skills installed; failed: $($failed -join ', ')" -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# 6 Main：总控（串联前面的步骤，都在此依次执行）
# -----------------------------------------------------------------------------

function Main {
    # Process 0：前置环境校验
    if ($InstallMethod -ne "npm" -and $InstallMethod -ne "git") {
        Write-Host "Error: invalid -InstallMethod (use npm or git)." -ForegroundColor Red
        return (Fail-Install -Code 2)
    }

    # 须在 DryRun、Remove-LegacySubmodule、Check-Node、Install-OpenClaw 等之前执行：任何分支都可能触发 npm/pnpm。
    if (-not (Ensure-ExecutionPolicy)) {
        Write-Host ""
        Write-Host "由于执行策略的限制，安装无法继续进行。" -ForegroundColor Red
        return (Fail-Install)
    }

    if ($DryRun) {
        Write-Host "[OK] Dry run" -ForegroundColor Green
        Write-Host "[OK] Install method: $InstallMethod" -ForegroundColor Green
        if ($InstallMethod -eq "git") {
            Write-Host "[OK] Git dir: $GitDir" -ForegroundColor Green
            if ($NoGitUpdate) {
                Write-Host "[OK] Git update: disabled" -ForegroundColor Green
            }
            else {
                Write-Host "[OK] Git update: enabled" -ForegroundColor Green
            }
        }
        Write-Host "[OK] Onboard: 正式安装时将询问是否执行" -ForegroundColor Green
        return $true
    }

    Remove-LegacySubmodule -RepoDir $RepoDir

    # 检查是否已经存在 openclaw
    $isUpgrade = Check-ExistingOpenClaw

    # Process 1: Node.js
    if (-not (Check-Node)) {
        if (-not (Install-Node)) {
            return (Fail-Install)
        }

        # Verify installation
        if (-not (Check-Node)) {
            Write-Host ""
            Write-Host "Error: Node.js installation may require a terminal restart" -ForegroundColor Red
            Write-Host "Please close this terminal, open a new one, and run this installer again." -ForegroundColor Yellow
            return (Fail-Install)
        }
    }

    # Process 1.3: 设置 npm 淘宝镜像
    Set-NpmRegistry

    $finalGitDir = $null

    # Process 4: 安装 OpenClaw（git/npm 安装两个分支）（包含 Process 2、Process 3）
    if ($InstallMethod -eq "git") {
        try {
            $npmCommand = Get-NpmCommandPath
            if ($npmCommand) {
                & $npmCommand uninstall -g openclaw 2>$null | Out-Null
                Write-Host "[OK] Removed npm global install if present" -ForegroundColor Green
            }
        }
        catch { }
        $finalGitDir = $GitDir
        # 使用 git 安装 OpenClaw
        if (-not (Install-OpenClawFromGit -RepoDir $GitDir -SkipUpdate:$NoGitUpdate)) {
            return (Fail-Install)
        }
    }
    else {
        $gitWrapper = Join-Path (Join-Path $env:USERPROFILE ".local\\bin") "openclaw.cmd"
        if (Test-Path $gitWrapper) {
            Remove-Item -Force $gitWrapper
            Write-Host "[OK] Removed git wrapper (switching to npm)" -ForegroundColor Green
        }
        if (-not (Install-OpenClaw)) {
            return (Fail-Install)
        }
    }

    if (-not (Ensure-OpenClawOnPath)) {
        Write-Host "安装已完成，但 OpenClaw 未能添加到系统路径 PATH 中。" -ForegroundColor Yellow
        Write-Host "请打开一个新的终端，然后运行: openclaw doctor" -ForegroundColor Cyan
        return
    }

    Refresh-GatewayServiceIfLoaded

    # Process 5: 如果升级或用 git 安装，则调用 Run-Doctor 进行自检或迁移操作
    # 确保在升级或源码安装后运行必要的自检和升级逻辑，防止遗留问题。
    if ($isUpgrade -or $InstallMethod -eq "git") {
        Run-Doctor
    }

    # 获取已安装的 OpenClaw 版本
    $installedVersion = $null
    try {
        $installedVersion = (Invoke-OpenClawCommand --version 2>$null).Trim()
    }
    catch {
        $installedVersion = $null
    }
    if (-not $installedVersion) {
        try {
            $npmList = & (Get-NpmCommandPath) list -g --depth 0 --json 2>$null | ConvertFrom-Json
            if ($npmList -and $npmList.dependencies -and $npmList.dependencies.openclaw -and $npmList.dependencies.openclaw.version) {
                $installedVersion = $npmList.dependencies.openclaw.version
            }
        }
        catch {
            $installedVersion = $null
        }
    }

    Write-Host ""
    if ($installedVersion) {
        Write-Host "OpenClaw ($installedVersion) 安装成功!" -ForegroundColor Green
    }
    else {
        Write-Host "OpenClaw 安装成功!" -ForegroundColor Green
    }
    Write-Host ""
    
    if ($isUpgrade) {
        # 升级成功后的提示语
        $updateMessages = @(
            "升级成功！新技能已解锁，不用谢。",
            "代码焕然一新，小龙虾依旧。有没有想我？",
            "更新完成，我学会了一些新招式。"
        )
        Write-Host (Get-Random -InputObject $updateMessages) -ForegroundColor Gray
        Write-Host ""
    }
    else {
        # 全新安装成功后的提示语
        $completionMessages = @(
            "小龙虾到岗，从此你的终端不再一样！",
            "我上线啦，准备一起搞事情吧！",
            "安装好啦，你的效率马上变得有点不一样了。"
        )
        Write-Host (Get-Random -InputObject $completionMessages) -ForegroundColor Gray
        Write-Host ""
    }

    if ($InstallMethod -eq "git") {
        Write-Host "Source checkout: $finalGitDir" -ForegroundColor Cyan
        Write-Host "Wrapper: $env:USERPROFILE\\.local\\bin\\openclaw.cmd" -ForegroundColor Cyan
        Write-Host ""
    }

    # Process 5.3: onboard
    $onboardRan = $false
    $onboardOk = $false

    if ($isUpgrade) {
        Write-Host "升级完成，您可以运行 " -NoNewline
        Write-Host "openclaw doctor" -ForegroundColor Cyan -NoNewline
        Write-Host " 检查是否有其他迁移操作需要执行。"
        Write-Host ""

        if (Ask-YesNo -Prompt "是否开始 onboard 向导（警告：会清空当前所有配置）？" -Default "N") {
            $onboardRan = $true
            $onboardOk = Invoke-OnboardWizard
        }
    }
    else {
        Write-Host "即将开始 onboard 向导，请提前准备模型相关配置。" -ForegroundColor Cyan
        $onboardRan = $true
        $onboardOk = Invoke-OnboardWizard
    }

    if ($onboardRan) {
        if ($onboardOk) {
            Invoke-HooksConfigureStep

            # Process 5.4: 预装 Skills
            if ($isUpgrade) {
                Write-Host ""
                if (Ask-YesNo -Prompt "是否安装预设 Skills（注意：可能会覆盖当前配置）？" -Default "Y") {
                    Write-Host "即将开始预安装常用 Skills..." -ForegroundColor Cyan
                    Install-Skills
                }
            }
            else {
                Write-Host ""
                Write-Host "即将开始预安装常用 Skills..." -ForegroundColor Cyan
                Install-Skills
            }
        }
    }
    else {
        if ($isUpgrade) {
            Write-Host ""
            if (Ask-YesNo -Prompt "是否安装预设 Skills（注意：可能会覆盖当前配置）？" -Default "Y") {
                Write-Host "即将开始预安装常用 Skills..." -ForegroundColor Cyan
                Install-Skills
            }
        }
    }

    return $true
}

# 入口：执行 Main，失败则 Complete-Install 退出或抛错。
$mainResults = @(Main)
$installSucceeded = $mainResults.Count -gt 0 -and $mainResults[-1] -eq $true
Complete-Install -Succeeded:$installSucceeded

# -----------------------------------------------------------------------------
# 7 Dashboard 启动，浏览器打开解析带 token 的 URL
# -----------------------------------------------------------------------------
function Invoke-OpenClawDashboardBrowser {
    Write-Host ""
    $openclawPath = Get-OpenClawCommandPath
    if (-not $openclawPath) {
        Write-Host "[!] openclaw command not found; cannot launch dashboard." -ForegroundColor Yellow
        return
    }

    $stdoutPath = Join-Path $env:TEMP ("openclaw-dashboard-" + [guid]::NewGuid().ToString("N") + ".out.log")
    $stderrPath = Join-Path $env:TEMP ("openclaw-dashboard-" + [guid]::NewGuid().ToString("N") + ".err.log")
    $dashboardUrl = $null
    $timeoutSeconds = 20
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $dashboardProcess = $null

    Write-Host "[*] Launching OpenClaw dashboard..." -ForegroundColor Yellow
    try {
        $dashboardProcess = Start-Process `
            -FilePath $openclawPath `
            -ArgumentList @("dashboard") `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500

            if (Test-Path $stdoutPath) {
                $stdoutContent = Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue
                if ($stdoutContent -match 'Dashboard URL:\s*(https?://\S*#token=\S+)') {
                    $dashboardUrl = $Matches[1]
                    break
                }
            }

            if ($dashboardProcess.HasExited) {
                break
            }
        }

        if (-not $dashboardUrl) {
            Write-Host "[!] Could not retrieve dashboard URL with token within $timeoutSeconds seconds." -ForegroundColor Yellow
            Write-Host "Run \"openclaw dashboard\" manually and copy the \"Dashboard URL:\" line." -ForegroundColor Yellow
            return
        }

        Add-Type -AssemblyName PresentationFramework | Out-Null
        $message = "已获取 Dashboard 地址：`n`n$dashboardUrl`n`n点击确定后将在浏览器中打开。"
        $result = [System.Windows.MessageBox]::Show(
            $message,
            "OpenClaw Dashboard",
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Information
        )

        if ($result -eq [System.Windows.MessageBoxResult]::OK) {
            Start-Process $dashboardUrl | Out-Null
            Write-Host "[OK] Dashboard URL opened in browser." -ForegroundColor Green
        }
        else {
            Write-Host "[!] Dashboard open canceled by user." -ForegroundColor Yellow
        }
    }
    finally {
        if ($dashboardProcess -and -not $dashboardProcess.HasExited) {
            $dashboardProcess.Kill()
        }
        if (Test-Path $stdoutPath) {
            Remove-Item -Force $stdoutPath
        }
        if (Test-Path $stderrPath) {
            Remove-Item -Force $stderrPath
        }
    }
}

if ($installSucceeded -and !$NoDashboard) {
    Write-Host ""
    Write-Host "即将启动 Dashboard，准备检查网关健康状态..." -ForegroundColor Cyan
    if (Test-GatewayHealthy) {
        Invoke-OpenClawDashboardBrowser
    }
    else {
        Write-Host "[!] 当前网关异常，您可以执行 openclaw gateway status 进行检查当前状态。" -ForegroundColor Red
    }
}
