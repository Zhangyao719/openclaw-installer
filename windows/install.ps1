# OpenClaw Installer for Windows (PowerShell)
# Usage: iwr -useb https://openclaw.ai/install.ps1 | iex
# Or: & ([scriptblock]::Create((iwr -useb https://openclaw.ai/install.ps1))) -NoOnboard

param(
    [ValidateSet("npm", "git")]
    [string]$InstallMethod = "npm",
    [string]$Tag = "latest",
    [string]$GitDir = "$env:USERPROFILE\openclaw",
    [switch]$NoOnboard,
    [switch]$NoSkills,
    [switch]$NoDashboard,
    [switch]$NoGitUpdate,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# 步骤 6 预装 Skills 列表（单 URL 分发：仅使用此内嵌数组，不读取仓库外部 YAML）
$script:SkillHubDefaultSkills = @(
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

$script:SkillHubKitTarUrl = 'https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/latest.tar.gz'

# -----------------------------------------------------------------------------
# 安装流程总览（主入口：Main）
# 0 前置       — 横幅、PowerShell 执行策略（否则 npm 脚本报错）
# 1 Node.js    — 1.1 检测版本 ≥22；1.2 缺失则 winget → choco → scoop 安装；1.3 设置 npm registry 镜像
# 2 Git        — 2.1 检测；2.2 缺失则 winget 安装（git 安装模式为硬性依赖）
# 3 OpenClaw   — 3.1 npm：全局 npm 包；3.2 git：克隆/更新仓库 + pnpm 构建 + 本地 wrapper
# 4 收尾       — 将 npm global prefix 写入用户 PATH
# 5 onboard    — 5.1 事前说明；5.2 执行 `openclaw onboard … --json`；5.3 解析 JSON 中 ok 为 true 则算成功
#                 -NoOnboard 时整步跳过；-DryRun 不执行、仅 [DRY RUN] 提示
# 6 SkillHub   — 6.1 官方安装包（tar）+ bash 执行 cli/install.sh；6.2 按内嵌列表 skillhub install；-NoSkills 整步跳过；-DryRun 仅提示
# 7 Dashboard  — 启动 `openclaw dashboard`，从输出解析带 `#token=` 的 Dashboard URL，弹窗后默认浏览器打开；-NoDashboard 跳过；-DryRun 仅提示
# -----------------------------------------------------------------------------

# Colors
$ACCENT = "`e[38;2;255;77;77m"    # coral-bright
$SUCCESS = "`e[38;2;0;229;204m"    # cyan-bright
$WARN = "`e[38;2;255;176;32m"     # amber
$ERROR_COLOR = "`e[38;2;230;57;70m"     # coral-mid
$MUTED = "`e[38;2;90;100;128m"    # text-muted
$NC = "`e[0m"                     # No Color

# 彩色日志输出（覆盖 Microsoft.PowerShell.Utility\Write-Host 的展示层）
function Write-Host {
    param([string]$Message, [string]$Level = "info")
    $msg = switch ($Level) {
        "success" { "$SUCCESS✓$NC $Message" }
        "warn" { "$WARN!$NC $Message" }
        "error" { "$ERROR_COLOR✗$NC $Message" }
        default { "$MUTED·$NC $Message" }
    }
    Microsoft.PowerShell.Utility\Write-Host $msg
}

# 打印安装器标题横幅
function Write-Banner {
    Write-Host ""
    Write-Host "${ACCENT}  🦞 OpenClaw 小龙虾安装神器——猫鼬 AI 出品$NC" -Level info
    Write-Host "${MUTED}  All your chats, one OpenClaw.$NC" -Level info
    Write-Host ""
}

# 判断当前执行策略是否会阻止脚本（如 npm.ps1）运行
function Get-ExecutionPolicyStatus {
    $policy = Get-ExecutionPolicy
    if ($policy -eq "Restricted" -or $policy -eq "AllSigned") {
        return @{ Blocked = $true; Policy = $policy }
    }
    return @{ Blocked = $false; Policy = $policy }
}

# 当前进程是否以管理员身份运行（本脚本未强制要求提权，仅能力探测）
function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 若为限制性策略，尝试将当前进程设为 RemoteSigned，保证后续 npm/git 可执行
function Ensure-ExecutionPolicy {
    $status = Get-ExecutionPolicyStatus
    if ($status.Blocked) {
        Write-Host "PowerShell 当前执行策略为: $($status.Policy)" -Level warn
        Write-Host "这会阻止 npm.ps1 等脚本运行。" -Level warn
        Write-Host ""
        
        # Try to set execution policy for current process
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -ErrorAction Stop
            Write-Host "已将当前进程的执行策略设置为 RemoteSigned" -Level success
            return $true
        }
        catch {
            Write-Host "无法自动设置执行策略" -Level error
            Write-Host ""
            Write-Host "要解决这个问题，请运行:" -Level info
            Write-Host "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process" -Level info
            Write-Host ""
            Write-Host "或者以管理员身份运行 PowerShell 并执行:" -Level info
            Write-Host "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine" -Level info
            return $false
        }
    }
    return $true
}

# --- 1. Node.js：版本读取 ---

# 返回已安装 Node 的主版本号字符串（无 v 前缀），未安装返回 $null
function Get-NodeVersion {
    try {
        $version = node --version 2>$null
        if ($version) {
            return $version -replace '^v', ''
        }
    }
    catch { }
    return $null
}

# 读取 npm 版本（本脚本内未做硬性门槛校验，仅供扩展）
function Get-NpmVersion {
    try {
        $version = npm --version 2>$null
        if ($version) {
            return $version
        }
    }
    catch { }
    return $null
}

# 1.1 Node 环境检测：需主版本 ≥22；不满足则调用 Install-Node
function Ensure-Node {
    $nodeVersion = Get-NodeVersion
    if ($nodeVersion) {
        $major = [int]($nodeVersion -split '\.')[0]
        if ($major -ge 22) {
            Write-Host "Node.js v$nodeVersion 已安装" -Level success
            return $true
        }
        Write-Host "Node.js v$nodeVersion 已安装，但需要 v22+ 版本" -Level warn
    }
    return Install-Node
}

# 1.2 安装 Node：依次尝试 winget(OpenJS.NodeJS.LTS) → choco → scoop，成功后刷新 PATH
function Install-Node {
    Write-Host "Node.js 未安装" -Level info
    Write-Host "正在安装 Node.js..." -Level info
    
    # 1.2.1 优先 winget（OpenJS.NodeJS.LTS）
    # Try winget first
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  使用 winget 安装 Node.js..." -Level info
        try {
            winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host "   winget 安装 Node.js 成功" -Level success
            return $true
        }
        catch {
            Write-Host "  Winget 安装失败: $_" -Level warn
        }
    }
    
    # 1.2.2 其次 Chocolatey（nodejs-lts）
    # Try chocolatey
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  使用 Chocolatey 安装 Node.js..." -Level info
        try {
            choco install nodejs-lts -y 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host "   Chocolatey 安装 Node.js 成功" -Level success
            return $true
        }
        catch {
            Write-Host "   Chocolatey 安装 Node.js 失败: $_" -Level warn
        }
    }
    
    # 1.2.3 再次 Scoop（nodejs-lts）
    # Try scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "  使用 Scoop 安装 Node.js..." -Level info
        try {
            scoop install nodejs-lts 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host "   Scoop 安装 Node.js 成功" -Level success
            return $true
        }
        catch {
            Write-Host "   Scoop 安装 Node.js 失败: $_" -Level warn
        }
    }
    
    Write-Host "无法自动安装 Node.js" -Level error
    Write-Host "请手动从 https://nodejs.org/zh-cn/download 安装 Node.js 22+ 版本" -Level info
    return $false
}

$script:NpmRegistryMirrorUrl = "https://registry.npmmirror.com"

# 1.3 Node/npm 就绪后，将默认 registry 设为国内镜像（失败仅告警，不中断安装）
function Set-NpmRegistryMirror {
    param([string]$RegistryUrl = $script:NpmRegistryMirrorUrl)

    if ($DryRun) {
        Write-Host "[DRY RUN] Would set npm registry to $RegistryUrl" -Level info
        return
    }

    Write-Host "设置 npm 下载源为 $RegistryUrl..." -Level info
    $p = Start-Process -FilePath "npm.cmd" -ArgumentList @("config", "set", "registry", $RegistryUrl) -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Host "无法设置 npm 下载源 (exit $($p.ExitCode))" -Level warn
        return
    }
    Write-Host "npm 下载源设置成功" -Level success
}

# --- 2. Git ---

# 检测 git 是否在 PATH 中（返回 git --version 文本或 $null）
function Get-GitVersion {
    try {
        $version = git --version 2>$null
        if ($version) {
            return $version
        }
    }
    catch { }
    return $null
}

# 2.2 使用 winget 安装 Git.Git；失败则提示官网手动安装
function Install-Git {
    Write-Host "Git 未安装" -Level info
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  使用 winget 安装 Git..." -Level info
        try {
            winget install Git.Git --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host "  winget 安装 Git 成功" -Level success
            return $true
        }
        catch {
            Write-Host "  winget 安装 Git 失败" -Level warn
        }
    }
    
    Write-Host "请手动从 https://git-scm.com/install/windows 安装 Git" -Level error
    return $false
}

# 2.1 Git 存在则通过；否则 Install-Git
function Ensure-Git {
    $gitVersion = Get-GitVersion
    if ($gitVersion) {
        Write-Host "Git $gitVersion 已安装" -Level success
        return $true
    }
    return Install-Git
}

# --- 通用工具：子进程输出捕获、路径与字符串 ---

# 读取文件并去掉末尾换行，不存在返回空串
function Read-TrimmedFileText {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path)) {
        return ""
    }

    return ((Get-Content -LiteralPath $Path -Raw) -replace "(\r?\n)+$", "")
}

# 将字符串转为 PowerShell 单引号安全字面量（单引号加倍）
function ConvertTo-PowerShellSingleQuotedLiteral {
    param([string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

# 同步启动外部程序并收集 stdout/stderr/ExitCode；对 .cmd/.bat 用嵌套 powershell 以便正确重定向
function Invoke-NativeCommandCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = ""
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $startFilePath = $FilePath
        $startArguments = $Arguments

        if ($FilePath -match '(?i)\.(cmd|bat)$') {
            # Start-Process cannot directly redirect stdio for command shims like
            # npm.cmd. Run them inside a nested PowerShell so the shim executes
            # normally while stdout/stderr still flow back to these temp files.
            $commandParts = @(
                ConvertTo-PowerShellSingleQuotedLiteral -Value $FilePath
            )
            foreach ($argument in $Arguments) {
                $commandParts += ConvertTo-PowerShellSingleQuotedLiteral -Value $argument
            }
            $commandScript = "& " + ($commandParts -join " ") + "`nexit `$LASTEXITCODE"
            $startFilePath = "powershell.exe"
            $startArguments = @(
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                $commandScript
            )
        }

        $startProcessArgs = @{
            FilePath               = $startFilePath
            ArgumentList           = $startArguments
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
        }
        if (![string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startProcessArgs.WorkingDirectory = $WorkingDirectory
        }

        $process = Start-Process @startProcessArgs

        return @{
            ExitCode = $process.ExitCode
            Stdout   = Read-TrimmedFileText -Path $stdoutPath
            Stderr   = Read-TrimmedFileText -Path $stderrPath
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

# npm 安装时使用的临时工作目录（避免污染当前目录）
function Get-NpmWorkingDirectory {
    $workingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-installer"
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    return $workingDirectory
}

# --- 3. 安装 OpenClaw ---

# 3.1 npm 方式：npm install -g <解析后的包说明>，stderr 不阻断成功安装
function Install-OpenClawNpm {
    param([string]$Target = "latest")

    $installSpec = Resolve-PackageInstallSpec -Target $Target
    
    Write-Host "全局安装 OpenClaw ($installSpec)..." -Level info
    
    try {
        # Run npm out-of-process so warning chatter on stderr does not get
        # promoted into a terminating PowerShell error while the install succeeds.
        $installResult = Invoke-NativeCommandCapture -FilePath "npm.cmd" -Arguments @(
            "install",
            "-g",
            $installSpec,
            "--no-fund",
            "--no-audit"
        ) -WorkingDirectory (Get-NpmWorkingDirectory)
        if ($installResult.Stdout) {
            Microsoft.PowerShell.Utility\Write-Host $installResult.Stdout
        }
        if ($installResult.Stderr) {
            Microsoft.PowerShell.Utility\Write-Host $installResult.Stderr
        }
        if ($installResult.ExitCode -ne 0) {
            Write-Host "全局安装 OpenClaw 失败，退出码：$($installResult.ExitCode)。" -Level error
            return $false
        }
        Write-Host "OpenClaw 全局安装完成" -Level success
        return $true
    }
    catch {
        Write-Host "npm 安装失败: $_" -Level error
        return $false
    }
}

# 3.2 git 方式：clone/pull 仓库，pnpm install + build，在用户目录生成 openclaw.cmd 并加入 PATH
function Install-OpenClawGit {
    param([string]$RepoDir, [switch]$Update)
    
    Write-Host "从 git 安装 OpenClaw..." -Level info
    
    # 3.2.1 克隆仓库或（可选）git pull 更新
    if (!(Test-Path $RepoDir)) {
        Write-Host "  克隆仓库..." -Level info
        git clone https://github.com/openclaw/openclaw.git $RepoDir 2>&1
    }
    elseif ($Update) {
        Write-Host "  更新仓库..." -Level info
        git -C $RepoDir pull --rebase 2>&1
    }
    
    # 3.2.2 若无 pnpm 则全局安装
    # Install pnpm if not present
    if (!(Get-Command pnpm -ErrorAction SilentlyContinue)) {
        Write-Host "  全局安装 pnpm..." -Level info
        npm install -g pnpm 2>&1
    }
    
    # 3.2.3 依赖安装与构建
    # Install dependencies
    Write-Host "  安装依赖..." -Level info
    pnpm install --dir $RepoDir 2>&1
    
    # Build
    Write-Host "  构建..." -Level info
    pnpm --dir $RepoDir build 2>&1
    
    # 3.2.4 生成 openclaw.cmd 包装并把 ~/.local/bin 加入 PATH
    # Create wrapper
    $wrapperDir = "$env:USERPROFILE\.local\bin"
    if (!(Test-Path $wrapperDir)) {
        New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null
    }

    $entryPath = Join-Path $RepoDir "dist\entry.js"
    @"
@echo off
node "$entryPath" %*
"@ | Out-File -FilePath "$wrapperDir\openclaw.cmd" -Encoding ASCII -Force
    Add-ToPath -Path $wrapperDir
    
    Write-Host "OpenClaw 下载并构建完成" -Level success
    return $true
}

# Target 是否为 URL、git 协议、github: 等“显式安装说明”
function Test-ExplicitPackageInstallSpec {
    param([string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $false
    }

    return $Target.Contains("://") -or
    $Target.Contains("#") -or
    $Target -match '^(file|github|git\+ssh|git\+https|git\+http|git\+file|npm):'
}

# 将 -Tag 转为 npm 可安装的包说明（latest / main / 版本号 / 显式 spec）
function Resolve-PackageInstallSpec {
    param([string]$Target = "latest")

    $trimmed = $Target.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return "openclaw@latest"
    }
    if ($trimmed.ToLowerInvariant() -eq "main") {
        return "github:openclaw/openclaw#main"
    }
    if (Test-ExplicitPackageInstallSpec -Target $trimmed) {
        return $trimmed
    }
    return "openclaw@$trimmed"
}

# 将目录追加到当前用户的 Path 环境变量（若尚未包含）
function Add-ToPath {
    param([string]$Path)
    
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$Path*") {
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$Path", "User")
        Write-Host "Added $Path to user PATH" -Level info
    }
}

# --- 5. onboard（需在步骤 4 写入用户 PATH 之后，当前进程才能找到 openclaw）---

# 从注册表合并 Machine + User 的 Path 到当前会话 $env:Path（步骤 4 刚改过 User PATH，本进程尚未自动继承）
function Refresh-SessionPathFromRegistry {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# 解析 openclaw 可执行路径：先 PATH 中查找，否则用 npm prefix 下的 openclaw.cmd
function Resolve-OpenClawExecutablePath {
    Refresh-SessionPathFromRegistry
    $cmd = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    $prefixResult = Invoke-NativeCommandCapture -FilePath "npm.cmd" -Arguments @("config", "get", "prefix") -WorkingDirectory (Get-NpmWorkingDirectory)
    if ($prefixResult.ExitCode -ne 0) {
        return $null
    }
    $prefix = $prefixResult.Stdout.Trim()
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $null
    }
    $candidate = Join-Path $prefix "openclaw.cmd"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return $null
}

# 5.2 调用官方 quickstart onboard（交互参数集 + --json）；返回是否判定成功（见下方 JSON.ok）
function Invoke-OpenClawOnboardQuickstart {
    $exe = Resolve-OpenClawExecutablePath
    if (!$exe) {
        Write-Host "未找到 openclaw 可执行文件，无法执行 onboard。" -Level warn
        return $false
    }

    # quickstart + gateway token + 安装 daemon + 跳过可选向导项；--json 便于解析结果
    $arguments = @(
        "onboard",
        "--accept-risk",
        "--flow", "quickstart",
        "--gateway-auth", "token",
        "--install-daemon",
        "--skip-channels",
        "--skip-skills",
        "--skip-search",
        "--skip-ui",
        "--json"
    )

    $result = Invoke-NativeCommandCapture -FilePath $exe -Arguments $arguments -WorkingDirectory (Get-NpmWorkingDirectory)
    if ($result.Stderr) {
        Microsoft.PowerShell.Utility\Write-Host $result.Stderr
    }

    # 5.3 从 stdout 解析 JSON：优先整段；失败则从首个 “{” 截取（兼容前缀日志）
    $text = $result.Stdout.Trim()
    $obj = $null
    try {
        $obj = $text | ConvertFrom-Json
    }
    catch {
        $i = $text.IndexOf("{")
        if ($i -ge 0) {
            try {
                $obj = $text.Substring($i) | ConvertFrom-Json
            }
            catch { }
        }
    }

    if ($null -eq $obj) {
        Write-Host "无法解析 onboard 的 JSON 输出。" -Level warn
        return $false
    }

    # 产品约定：根字段 ok 为 true 表示 onboard 成功
    if ($obj.ok -eq $true) {
        return $true
    }

    return $false
}

# --- 6. SkillHub（Main 成功后在脚本入口调用；失败仅告警，不改变 Complete-Install 判定）---

function Get-BashExecutablePath {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    foreach ($candidate in @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "$env:ProgramFiles(x86)\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
        )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

# 6.1 与官网 curl … \| bash 等价：下载 latest.tar.gz，解压后执行包内 cli/install.sh（需 Git Bash 等 bash.exe）
function Install-SkillHubOfficialKit {
    $bashExe = Get-BashExecutablePath
    if (!$bashExe) {
        Write-Host "未找到 bash（例如 Git for Windows 自带的 bash.exe），无法执行 SkillHub 官方 Linux 安装脚本。请先安装 Git： https://git-scm.com/install/windows" -Level warn
        return $false
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('skillhub-kit-' + [Guid]::NewGuid().ToString())
    $tarFile = Join-Path $tempRoot 'latest.tar.gz'
    $extractRoot = Join-Path $tempRoot 'extracted'
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

        Write-Host "正在下载 SkillHub 安装包..." -Level info
        Invoke-WebRequest -Uri $script:SkillHubKitTarUrl -OutFile $tarFile -UseBasicParsing

        $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
        if (!$tarCmd) {
            Write-Host "当前环境未找到 tar，无法解压 SkillHub 安装包。" -Level warn
            return $false
        }

        & $tarCmd.Source -xzf $tarFile -C $extractRoot
        if (-not $?) {
            Write-Host "解压 SkillHub 安装包失败。" -Level warn
            return $false
        }

        $installerScript = Get-ChildItem -Path $extractRoot -Recurse -Filter install.sh -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq 'cli' } |
            Select-Object -First 1
        if (!$installerScript) {
            Write-Host "解压结果中未找到 cli/install.sh。" -Level warn
            return $false
        }

        Write-Host "正在运行 SkillHub 官方安装脚本..." -Level info
        $proc = Start-Process -FilePath $bashExe -ArgumentList @($installerScript.FullName) -WorkingDirectory $extractRoot -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Host "SkillHub 官方安装脚本退出码：$($proc.ExitCode)" -Level warn
            return $false
        }
        return $true
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-SkillHubExecutablePath {
    Refresh-SessionPathFromRegistry
    $cmd = Get-Command skillhub -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    return $null
}

function Install-SkillHub {
    if ($NoSkills) {
        return
    }

    Write-Host ""
    Write-Host "${ACCENT}—— SkillHub / 预装 Skills ——$NC" -Level info

    if ($DryRun) {
        Write-Host "[DRY RUN] 将下载 SkillHub 官方安装包并运行 cli/install.sh；随后 skillhub install：" ($script:SkillHubDefaultSkills -join ', ') -Level info
        return
    }

    # 6.1：若无 skillhub 命令则执行官网套件安装
    $skillhubExe = Resolve-SkillHubExecutablePath
    if (!$skillhubExe) {
        if (!(Install-SkillHubOfficialKit)) {
            Write-Host "SkillHub CLI 未能安装，跳过预装 Skills。" -Level warn
            return
        }
        Refresh-SessionPathFromRegistry
        $skillhubExe = Resolve-SkillHubExecutablePath
    }

    if (!$skillhubExe) {
        Write-Host "安装包已执行完毕，但仍无法在 PATH 中找到 skillhub，跳过预装 Skills。" -Level warn
        return
    }

    # 6.2：按内嵌列表安装到 OpenClaw 约定目录（由 skillhub 负责）
    $ok = 0
    $failedSkills = @()
    foreach ($skillId in $script:SkillHubDefaultSkills) {
        if ([string]::IsNullOrWhiteSpace($skillId)) {
            continue
        }
        Write-Host "skillhub install $skillId ..." -Level info
        $r = Invoke-NativeCommandCapture -FilePath $skillhubExe -Arguments @('install', $skillId.Trim()) -WorkingDirectory (Get-NpmWorkingDirectory)
        if ($r.Stdout) {
            Microsoft.PowerShell.Utility\Write-Host $r.Stdout
        }
        if ($r.Stderr) {
            Microsoft.PowerShell.Utility\Write-Host $r.Stderr
        }
        if ($r.ExitCode -eq 0) {
            $ok++
        }
        else {
            $failedSkills += $skillId
            Write-Host "skillhub install $skillId 失败（退出码 $($r.ExitCode)）。" -Level warn
        }
    }

    Write-Host "SkillHub 预装结束：成功 $ok 个；失败 $($failedSkills.Count) 个。" -Level $(if ($failedSkills.Count -eq 0) { 'success' } else { 'warn' })
}

# --- 7. Dashboard（openclaw dashboard 长期驻留；异步读 stdout/stderr 捕获第一行 Dashboard URL）---

function Test-DashboardUrlLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    $clean = $Line -replace '\x1b\[[0-9;]*m', ''
    if ($clean -match '(?i)Dashboard URL:\s*(https?://\S+)') {
        $u = $Matches[1].Trim()
        if ($u -match '(?i)#token=') {
            return $u
        }
    }
    return $null
}

function Invoke-OpenClawDashboardBrowser {
    if ($NoDashboard) {
        return
    }

    if ($DryRun) {
        Write-Host "[DRY RUN] 将启动 openclaw dashboard，解析 Dashboard URL 后弹窗并打开浏览器。" -Level info
        return
    }

    Refresh-SessionPathFromRegistry
    $exe = Resolve-OpenClawExecutablePath
    if (!$exe) {
        Write-Host "未找到 openclaw，无法启动 Dashboard。" -Level warn
        return
    }

    Write-Host "正在启动 OpenClaw Dashboard（后台进程）…" -Level info

    $script:DashboardUrlCaptured = $null
    $dataHandler = [System.Diagnostics.DataReceivedEventHandler]{
        param($sender, [System.Diagnostics.DataReceivedEventArgs]$e)
        if ($e.Data) {
            $u = Test-DashboardUrlLine -Line $e.Data
            if ($u) {
                $script:DashboardUrlCaptured = $u
            }
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = 'dashboard'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true
    $proc.OutputDataReceived += $dataHandler
    $proc.ErrorDataReceived += $dataHandler

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        if (-not [string]::IsNullOrWhiteSpace($script:DashboardUrlCaptured)) {
            break
        }
        if ($proc.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if ([string]::IsNullOrWhiteSpace($script:DashboardUrlCaptured)) {
        Write-Host "未能及时解析 Dashboard URL（请确认 gateway 已就绪）。" -Level warn
        if (!$proc.HasExited) {
            $proc.Kill()
        }
        return
    }

    $dashUrl = $script:DashboardUrlCaptured

    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "小龙虾已经启动，地址为：`n$dashUrl`n`n点击「确定」后在浏览器中打开该地址。",
        'OpenClaw Dashboard',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )

    Start-Process -FilePath $dashUrl
}

$script:InstallExitCode = 0

# 记录失败退出码（供 Complete-Install / 被 dot-source 时处理）
function Fail-Install {
    param([int]$Code = 1)

    $script:InstallExitCode = $Code
    return $false
}

# 安装结束：失败时 exit 或 throw（取决于是否通过 PSCommandPath 调用）
function Complete-Install {
    param([bool]$Succeeded)

    if ($Succeeded) {
        return
    }

    if ($PSCommandPath) {
        exit $script:InstallExitCode
    }

    throw "OpenClaw 安装失败，退出码：$($script:InstallExitCode)。"
}

# Main
function Main {
    Write-Banner
    
    Write-Host "检测到 Windows 系统" -Level success
    
    # 0 前置：执行策略（必须在任何 npm 调用之前）
    # Check and handle execution policy FIRST, before any npm calls
    if (!(Ensure-ExecutionPolicy)) {
        Write-Host ""
        Write-Host "由于执行策略的限制，安装无法继续进行。" -Level error
        return (Fail-Install)
    }
    
    # 1 Node.js：Ensure-Node（含 1.1 检测与 1.2 自动安装）
    if (!(Ensure-Node)) {
        return (Fail-Install)
    }

    # 1.3 设置 npm registry 镜像
    Set-NpmRegistryMirror

    # 根据`-InstallMethod`参数选择安装方式
    # `git` 模式下需硬性安装 Git
    # `npm` 模式下仅警告，不中断安装
    if ($InstallMethod -eq "git") {
        # 2 安装 Git
        if (!(Ensure-Git)) {
            return (Fail-Install)
        }

        if ($DryRun) {
            Write-Host "[DRY RUN] Would install OpenClaw from git to $GitDir" -Level info
        }
        else {
            try {
                npm uninstall -g openclaw 2>$null | Out-Null
            }
            catch { }
            # 3.2 从 GitHub 克隆/更新 + pnpm 构建 + wrapper
            if (!(Install-OpenClawGit -RepoDir $GitDir -Update:(-not $NoGitUpdate))) {
                return (Fail-Install)
            }
        }
    }
    else {
        # npm 方式：建议有 Git（部分依赖可能用到）
        # 仅检测 Git 并警告，不中断安装
        if (!(Ensure-Git)) {
            Write-Host "未检测到 Git，npm 安装可能会失败，建议安装 Git 并重新运行安装脚本。" -Level warn
        }

        if ($DryRun) {
            Write-Host "[DRY RUN] Would install OpenClaw via npm ($((Resolve-PackageInstallSpec -Target $Tag)))" -Level info
        }
        else {
            $gitWrapper = "$env:USERPROFILE\.local\bin\openclaw.cmd"
            if (Test-Path $gitWrapper) {
                Remove-Item -Force $gitWrapper
                Write-Host "Removed git wrapper (switching to npm)" -Level info
            }
            # 3.1 全局 npm 安装 openclaw 包
            if (!(Install-OpenClawNpm -Target $Tag)) {
                return (Fail-Install)
            }
        }
    }

    # 4 收尾：把 npm 全局 prefix 加入用户 PATH，便于直接运行 openclaw
    try {
        $prefixResult = Invoke-NativeCommandCapture -FilePath "npm.cmd" -Arguments @(
            "config",
            "get",
            "prefix"
        ) -WorkingDirectory (Get-NpmWorkingDirectory)
        $npmPrefix = $prefixResult.Stdout
        if ($prefixResult.ExitCode -eq 0 -and $npmPrefix) {
            Add-ToPath -Path "$npmPrefix"
        }
    }
    catch { }
    Write-Host ""
    Write-Host "🦞 OpenClaw 安装成功!" -Level success

    # 5 onboard：-NoOnboard 时整步跳过；有提示、有执行、有结果分支（安装整体仍可能 return $true）
    $onboardOk = $null
    if (!$NoOnboard) {
        if ($DryRun) {
            # 5.0 仅演示将执行的子命令，不修改环境
            Write-Host ""
            Write-Host "[DRY RUN] 将执行 openclaw onboard（quickstart，--json）。" -Level info
        }
        else {
            # 5.1 让用户在自动执行前准备 API Key 等
            Write-Host ""
            Write-Host "即将调用 OpenClaw 官方引导进行配置。请提前准备好模型相关信息（例如 API Key）。" -Level info
            # 5.2～5.3 见 Invoke-OpenClawOnboardQuickstart 内注释
            $onboardOk = Invoke-OpenClawOnboardQuickstart
        }
    }

    # 收尾文案：安装成功始终打印；onboard 仅在执行过时附加成功或失败说明（不把 onboard 失败当作安装失败）
    if ($null -ne $onboardOk) {
        if ($onboardOk) {
            Write-Host "🦞 OpenClaw 配置成功。" -Level success
        }
        else {
            Write-Host "安装已完成，但 onboard 配置未成功。请稍后手动执行 openclaw onboard 完成配置。" -Level warn
        }
    }
    return $true
}

# 脚本入口：执行 Main；Complete-Install 仅反映 Main
$mainResults = @(Main)
$installSucceeded = $mainResults.Count -gt 0 -and $mainResults[-1] -eq $true
Complete-Install -Succeeded:$installSucceeded

# SkillHub 与 Skills 预装
if ($installSucceeded -and !$NoSkills) {
    Install-SkillHub
}

# Dashboard 启动，浏览器打开解析带 token 的 URL
if ($installSucceeded -and !$NoDashboard) {
    Invoke-OpenClawDashboardBrowser
}