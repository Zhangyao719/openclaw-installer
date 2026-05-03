# OpenClaw Installer for Windows (PowerShell)
# Usage: iwr -useb https://openclaw.ai/install.ps1 | iex
# Or: & ([scriptblock]::Create((iwr -useb https://openclaw.ai/install.ps1))) -NoOnboard

param(
    [ValidateSet("npm", "git")]
    [string]$InstallMethod = "npm",
    [string]$Tag = "latest",
    [string]$GitDir = "$env:USERPROFILE\openclaw",
    [switch]$NoOnboard,
    [switch]$NoGitUpdate,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# 安装流程总览（主入口：Main）
# 0 前置       — 横幅、PowerShell 执行策略（否则 npm 脚本报错）
# 1 Node.js    — 1.1 检测版本 ≥22；1.2 缺失则 winget → choco → scoop 安装
# 2 Git        — 2.1 检测；2.2 缺失则 winget 安装（git 安装模式为硬性依赖）
# 3 OpenClaw   — 3.1 npm：全局 npm 包；3.2 git：克隆/更新仓库 + pnpm 构建 + 本地 wrapper
# 4 收尾       — 将 npm global prefix 写入用户 PATH；可选提示 onboard
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
    Write-Host "${ACCENT}  🦞 OpenClaw Installer$NC" -Level info
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
        Write-Host "PowerShell execution policy is set to: $($status.Policy)" -Level warn
        Write-Host "This prevents scripts like npm.ps1 from running." -Level warn
        Write-Host ""
        
        # Try to set execution policy for current process
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -ErrorAction Stop
            Write-Host "Set execution policy to RemoteSigned for current process" -Level success
            return $true
        } catch {
            Write-Host "Could not automatically set execution policy" -Level error
            Write-Host ""
            Write-Host "To fix this, run:" -Level info
            Write-Host "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process" -Level info
            Write-Host ""
            Write-Host "Or run PowerShell as Administrator and execute:" -Level info
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
    } catch { }
    return $null
}

# 读取 npm 版本（本脚本内未做硬性门槛校验，仅供扩展）
function Get-NpmVersion {
    try {
        $version = npm --version 2>$null
        if ($version) {
            return $version
        }
    } catch { }
    return $null
}

# 1.2 安装 Node：依次尝试 winget(OpenJS.NodeJS.LTS) → choco → scoop，成功后刷新 PATH
function Install-Node {
    Write-Host "Node.js not found" -Level info
    Write-Host "Installing Node.js..." -Level info
    
    # 1.2.1 优先 winget（OpenJS.NodeJS.LTS）
    # Try winget first
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  Using winget..." -Level info
        try {
            winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-Host "  Node.js installed via winget" -Level success
            return $true
        } catch {
            Write-Host "  Winget install failed: $_" -Level warn
        }
    }
    
    # 1.2.2 其次 Chocolatey（nodejs-lts）
    # Try chocolatey
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  Using chocolatey..." -Level info
        try {
            choco install nodejs-lts -y 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-Host "  Node.js installed via chocolatey" -Level success
            return $true
        } catch {
            Write-Host "  Chocolatey install failed: $_" -Level warn
        }
    }
    
    # 1.2.3 再次 Scoop（nodejs-lts）
    # Try scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "  Using scoop..." -Level info
        try {
            scoop install nodejs-lts 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-Host "  Node.js installed via scoop" -Level success
            return $true
        } catch {
            Write-Host "  Scoop install failed: $_" -Level warn
        }
    }
    
    Write-Host "Could not install Node.js automatically" -Level error
    Write-Host "Please install Node.js 22+ manually from: https://nodejs.org" -Level info
    return $false
}

# 1.1 Node 环境检测：需主版本 ≥22；不满足则调用 Install-Node
function Ensure-Node {
    $nodeVersion = Get-NodeVersion
    if ($nodeVersion) {
        $major = [int]($nodeVersion -split '\.')[0]
        if ($major -ge 22) {
            Write-Host "Node.js v$nodeVersion found" -Level success
            return $true
        }
        Write-Host "Node.js v$nodeVersion found, but need v22+" -Level warn
    }
    return Install-Node
}

# --- 2. Git ---

# 检测 git 是否在 PATH 中（返回 git --version 文本或 $null）
function Get-GitVersion {
    try {
        $version = git --version 2>$null
        if ($version) {
            return $version
        }
    } catch { }
    return $null
}

# 2.2 使用 winget 安装 Git.Git；失败则提示官网手动安装
function Install-Git {
    Write-Host "Git not found" -Level info
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  Installing Git via winget..." -Level info
        try {
            winget install Git.Git --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-Host "  Git installed" -Level success
            return $true
        } catch {
            Write-Host "  Winget install failed" -Level warn
        }
    }
    
    Write-Host "Please install Git for Windows from: https://git-scm.com" -Level error
    return $false
}

# 2.1 Git 存在则通过；否则 Install-Git
function Ensure-Git {
    $gitVersion = Get-GitVersion
    if ($gitVersion) {
        Write-Host "$gitVersion found" -Level success
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
            FilePath = $startFilePath
            ArgumentList = $startArguments
            Wait = $true
            PassThru = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
        }
        if (![string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startProcessArgs.WorkingDirectory = $WorkingDirectory
        }

        $process = Start-Process @startProcessArgs

        return @{
            ExitCode = $process.ExitCode
            Stdout = Read-TrimmedFileText -Path $stdoutPath
            Stderr = Read-TrimmedFileText -Path $stderrPath
        }
    } finally {
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
    
    Write-Host "Installing OpenClaw ($installSpec)..." -Level info
    
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
            Write-Host "npm install failed with exit code $($installResult.ExitCode)" -Level error
            return $false
        }
        Write-Host "OpenClaw installed" -Level success
        return $true
    } catch {
        Write-Host "npm install failed: $_" -Level error
        return $false
    }
}

# 3.2 git 方式：clone/pull 仓库，pnpm install + build，在用户目录生成 openclaw.cmd 并加入 PATH
function Install-OpenClawGit {
    param([string]$RepoDir, [switch]$Update)
    
    Write-Host "Installing OpenClaw from git..." -Level info
    
    # 3.2.1 克隆仓库或（可选）git pull 更新
    if (!(Test-Path $RepoDir)) {
        Write-Host "  Cloning repository..." -Level info
        git clone https://github.com/openclaw/openclaw.git $RepoDir 2>&1
    } elseif ($Update) {
        Write-Host "  Updating repository..." -Level info
        git -C $RepoDir pull --rebase 2>&1
    }
    
    # 3.2.2 若无 pnpm 则全局安装
    # Install pnpm if not present
    if (!(Get-Command pnpm -ErrorAction SilentlyContinue)) {
        Write-Host "  Installing pnpm..." -Level info
        npm install -g pnpm 2>&1
    }
    
    # 3.2.3 依赖安装与构建
    # Install dependencies
    Write-Host "  Installing dependencies..." -Level info
    pnpm install --dir $RepoDir 2>&1
    
    # Build
    Write-Host "  Building..." -Level info
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
    
    Write-Host "OpenClaw installed" -Level success
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

    throw "OpenClaw installation failed with exit code $($script:InstallExitCode)."
}

# Main：按 0→1→2→3→4 顺序执行；InstallMethod 决定 3.1 npm 或 3.2 git
function Main {
    Write-Banner
    
    Write-Host "Windows detected" -Level success
    
    # 0 前置：执行策略（必须在任何 npm 调用之前）
    # Check and handle execution policy FIRST, before any npm calls
    if (!(Ensure-ExecutionPolicy)) {
        Write-Host ""
        Write-Host "Installation cannot continue due to execution policy restrictions" -Level error
        return (Fail-Install)
    }
    
    # 1 Node.js：Ensure-Node（含 1.1 检测与 1.2 自动安装）
    if (!(Ensure-Node)) {
        return (Fail-Install)
    }
    
    # 2 / 3：按 InstallMethod 分支
    if ($InstallMethod -eq "git") {
        # 2 Git（git 模式为硬性依赖）
        if (!(Ensure-Git)) {
            return (Fail-Install)
        }
        
        if ($DryRun) {
            Write-Host "[DRY RUN] Would install OpenClaw from git to $GitDir" -Level info
        } else {
            try {
                npm uninstall -g openclaw 2>$null | Out-Null
            } catch { }
            # 3.2 从 GitHub 克隆/更新 + pnpm 构建 + wrapper
            if (!(Install-OpenClawGit -RepoDir $GitDir -Update:(-not $NoGitUpdate))) {
                return (Fail-Install)
            }
        }
    } else {
        # npm 方式：建议有 Git（部分依赖可能用到），非硬性失败
        # npm method
        if (!(Ensure-Git)) {
            Write-Host "Git is required for npm installs. Please install Git and try again." -Level warn
        }
        
        if ($DryRun) {
            Write-Host "[DRY RUN] Would install OpenClaw via npm ($((Resolve-PackageInstallSpec -Target $Tag)))" -Level info
        } else {
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
    # Try to add npm global bin to PATH
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
    } catch { }
    
    # 4.1 可选：提示首次引导命令
    if (!$NoOnboard -and !$DryRun) {
        Write-Host ""
        Write-Host "Run 'openclaw onboard' to complete setup" -Level info
    }
    
    Write-Host ""
    Write-Host "🦞 OpenClaw installed successfully!" -Level success
    return $true
}

# 脚本入口：执行 Main 并根据结果退出或抛错
$mainResults = @(Main)
$installSucceeded = $mainResults.Count -gt 0 -and $mainResults[-1] -eq $true
Complete-Install -Succeeded:$installSucceeded