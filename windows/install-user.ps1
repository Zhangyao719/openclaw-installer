

















param(
    [string]$Tag = "latest",
    [ValidateSet("npm", "git")]
    [string]$InstallMethod = "npm",
    [string]$GitDir,
    [switch]$NoGitUpdate,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"





$script:InstallExitCode = 0


function Fail-Install {
    param([int]$Code = 1)

    $script:InstallExitCode = $Code
    return $false
}


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


function Ask-YesNo {
    param(
        [string]$Prompt,          
        [string]$Default = "Y"    
    )
    $hint = if ($Default -eq "Y") { "(Y/n)" } else { "(y/N)" }
    $answer = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    return $answer -match '^[Yy]'
}

Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║                                                           ║" -ForegroundColor Cyan
Write-Host "  ║          🦞  OpenClaw Easy Deploy  🦞                    ║" -ForegroundColor Cyan
Write-Host "  ║                                                           ║" -ForegroundColor Cyan
Write-Host "  ║     让 OpenClaw 部署变得简单 - 零技术门槛，一键安装        ║" -ForegroundColor Cyan
Write-Host "  ║                                                           ║" -ForegroundColor Cyan
Write-Host "  ║                    猫鼬AI出品                             ║" -ForegroundColor Cyan
Write-Host "  ╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""


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


function Install-Node {
    Write-Host "[*] Installing Node.js..." -ForegroundColor Yellow

    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  Using winget..." -ForegroundColor Gray
        winget install OpenJS.NodeJS.LTS --source winget --accept-package-agreements --accept-source-agreements

        
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        if (Check-Node) {
            Write-Host "[OK] Node.js installed via winget" -ForegroundColor Green
            return $true
        }
        Write-Host "[!] winget completed, but Node.js is still unavailable in this shell" -ForegroundColor Yellow
        Write-Host "Restart PowerShell and re-run the installer if Node.js was installed successfully." -ForegroundColor Yellow
        return $false
    }

    
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  Using Chocolatey..." -ForegroundColor Gray
        choco install nodejs-lts -y

        
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Host "[OK] Node.js installed via Chocolatey" -ForegroundColor Green
        return $true
    }

    
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "  Using Scoop..." -ForegroundColor Gray
        scoop install nodejs-lts
        Write-Host "[OK] Node.js installed via Scoop" -ForegroundColor Green
        return $true
    }

    
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








function Check-ExistingOpenClaw {
    if (Get-OpenClawCommandPath) {
        Write-Host "[*] Existing OpenClaw installation detected" -ForegroundColor Yellow
        return $true
    }
    return $false
}






function Check-Git {
    try {
        $null = Get-Command git -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}


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


function Get-PortableGitRoot {
    $base = Join-Path $env:LOCALAPPDATA "OpenClaw\deps"
    return (Join-Path $base "portable-git")
}


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


function Get-NpmCommandPath {
    $path = Resolve-CommandPath -Candidates @("npm.cmd", "npm.exe", "npm")
    if (-not $path) {
        throw "npm not found on PATH."
    }
    return $path
}


function Get-CorepackCommandPath {
    return (Resolve-CommandPath -Candidates @("corepack.cmd", "corepack.exe", "corepack"))
}


function Get-PnpmCommandPath {
    return (Resolve-CommandPath -Candidates @("pnpm.cmd", "pnpm.exe", "pnpm"))
}


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


function Install-OpenClaw {
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        $Tag = "latest"
    }
    if (-not (Ensure-Git)) {
        return $false
    }

    
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


function Get-LegacyRepoDir {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCLAW_GIT_DIR)) {
        return $env:OPENCLAW_GIT_DIR
    }
    $userHome = [Environment]::GetFolderPath("UserProfile")
    return (Join-Path $userHome "openclaw")
}


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






function Run-Doctor {
    Write-Host "[*] 运行 doctor 程序以迁移设置..." -ForegroundColor Yellow
    try {
        Invoke-OpenClawCommand doctor --non-interactive
    }
    catch {
        
    }
    Write-Host "[OK] Migration complete" -ForegroundColor Green
}


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






function Main {
    if ($InstallMethod -ne "npm" -and $InstallMethod -ne "git") {
        Write-Host "Error: invalid -InstallMethod (use npm or git)." -ForegroundColor Red
        return (Fail-Install -Code 2)
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

    
    $isUpgrade = Check-ExistingOpenClaw

    
    if (-not (Check-Node)) {
        if (-not (Install-Node)) {
            return (Fail-Install)
        }

        
        if (-not (Check-Node)) {
            Write-Host ""
            Write-Host "Error: Node.js installation may require a terminal restart" -ForegroundColor Red
            Write-Host "Please close this terminal, open a new one, and run this installer again." -ForegroundColor Yellow
            return (Fail-Install)
        }
    }

    
    Set-NpmRegistry

    $finalGitDir = $null

    
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
        Write-Host "Install completed, but OpenClaw is not on PATH yet." -ForegroundColor Yellow
        Write-Host "Open a new terminal, then run: openclaw doctor" -ForegroundColor Cyan
        return
    }

    Refresh-GatewayServiceIfLoaded

    
    
    if ($isUpgrade -or $InstallMethod -eq "git") {
        Run-Doctor
    }

    
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
        Write-Host "OpenClaw 安装成功 ($installedVersion)!" -ForegroundColor Green
    }
    else {
        Write-Host "OpenClaw 安装成功!" -ForegroundColor Green
    }
    Write-Host ""
    
    if ($isUpgrade) {
        
        $updateMessages = @(
            "升级成功！新技能已解锁，不用谢。",
            "代码焕然一新，小龙虾依旧。有没有想我？",
            "更新完成，我学会了一些新招式。",
            "版本升级，现在多了23%的幽默感！",
            "我进化了，记得跟上我的步伐哦。",
            "新版本，谁？没错，还是我，只是更闪亮。",
            "修复、优化，准备继续大显身手！",
            "小龙虾刚蜕壳，壳更硬，钳更锋利。",
            "升级完成！要不看下更新日志？其实相信我就行。",
            "在 npm 的沸水中重生，现在更强大了。",
            "我升级归来，变聪明了，你也试试看？",
            "更新完成，连 bug 都害怕跑了。",
            "新版本就位，上一版让我代他问好。",
            "固件已焕新，脑回路又多了几圈。",
            "我见过的都超乎你的想象。总之我升级啦！",
            "上线报到，更新日志很长，但我们的友情更长。",
            "版本跃迁！还是熟悉的混乱能量，只是可能更稳定了。"
        )
        Write-Host (Get-Random -InputObject $updateMessages) -ForegroundColor Gray
        Write-Host ""
    }
    else {
        
        $completionMessages = @(
            "啊，这里不错嘛，有没有小零食？",
            "到家咯！别担心，我不会随便动你的文件。",
            "我上线啦，准备一起搞事情吧！",
            "安装好啦，你的效率马上变得有点不一样了。",
            "安顿好了，准备帮你自动化日常小事，不管你想不想~",
            "挺舒服的，我已经悄悄看完你的日历了，有空聊聊？",
            "东西都收拾好了，把难题交给我吧！",
            "嘎吱嘎吱，钳子就位，咱们干点啥？",
            "小龙虾到岗，从此你的终端不再一样！",
            "搞定啦！我保证只会稍微评价一下你的代码。"
        )
        Write-Host (Get-Random -InputObject $completionMessages) -ForegroundColor Gray
        Write-Host ""
    }

    if ($InstallMethod -eq "git") {
        Write-Host "Source checkout: $finalGitDir" -ForegroundColor Cyan
        Write-Host "Wrapper: $env:USERPROFILE\\.local\\bin\\openclaw.cmd" -ForegroundColor Cyan
        Write-Host ""
    }

    
    if ($isUpgrade) {
        Write-Host "升级完成，请运行 " -NoNewline
        Write-Host "openclaw doctor" -ForegroundColor Cyan -NoNewline
        Write-Host " 检查是否有其他迁移操作需要执行。"

        if (Ask-YesNo -Prompt "是否开始 onboard 安装向导（注意：可能会覆盖当前配置）？" -Default "N") {
            Write-Host "开始执行 onboard 官方配置向导..." -ForegroundColor Cyan
            Write-Host ""
            Invoke-OpenClawCommand onboard
        }
    }
    else {
        Write-Host "开始执行 onboard 官方配置向导..." -ForegroundColor Cyan
        Write-Host ""
        Invoke-OpenClawCommand onboard --accept-risk --flow quickstart --skip-channels --skip-skills --skip-search --skip-ui
    }

    
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

    return $true
}


$mainResults = @(Main)
$installSucceeded = $mainResults.Count -gt 0 -and $mainResults[-1] -eq $true
Complete-Install -Succeeded:$installSucceeded




function Invoke-OpenClawDashboardBrowser {
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
    Invoke-OpenClawDashboardBrowser
}