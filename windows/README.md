# Windows 版本的脚本使用说明

## OpenClaw 官方安装脚本解析

### 1. OpenClaw install 功能模块划分

| 模块                   | 职责                                                         | 主要符号                                                     |
| :--------------------- | :----------------------------------------------------------- | :----------------------------------------------------------- |
| 1. 入参与全局          | `param`（`InstallMethod`/`Tag`/`GitDir`/`NoOnboard`/`NoGitUpdate`/`DryRun`）、`$ErrorActionPreference = Stop`、ANSI 颜色常量 | 文件顶部                                                     |
| 2. 终端输出            | 带级别的 `Write-Host` 包装、`Write-Banner`                   | `Write-Host`、`Write-Banner`                                 |
| 3. PowerShell 环境     | 执行策略是否阻塞、`RemoteSigned` 进程级修复                  | `Get-ExecutionPolicyStatus`、`Ensure-ExecutionPolicy`（另有 `Test-Admin` 定义，主流程未调用） |
| 4. Node / npm          | 读 `node`/`npm` 版本；缺 Node 或主版本 < 22 时走包管理器安装；装完刷新 `$env:Path` | `Get-NodeVersion`、`Get-NpmVersion`、`Install-Node`、`Ensure-Node` |
| 5. Git                 | 检测 Git；没有则 winget 装 Git 或提示官网                    | `Get-GitVersion`、`Install-Git`、`Ensure-Git`                |
| 6. 原生命令与 npm 包名 | 把 `npm.cmd` 等通过子进程跑并收集 stdout/stderr/退出码；把 `-Tag` 解析成 `openclaw@…` / `github:…#main` 等 | `Invoke-NativeCommandCapture`、`Read-TrimmedFileText`、`ConvertTo-PowerShellSingleQuotedLiteral`、`Resolve-PackageInstallSpec`、`Test-ExplicitPackageInstallSpec` |
| 7. 安装 OpenClaw       | npm：`npm install -g … --no-fund --no-audit`；git：clone/pull、`pnpm install`、`pnpm build`、写 `%USERPROFILE%\.local\bin\openclaw.cmd` 并 `Add-ToPath` | `Install-OpenClawNpm`、`Install-OpenClawGit`                 |
| 8. 退出与收尾          | 统一失败码、`Complete-Install`（ piped `iex` 时用 `throw` 而非 `exit` 的场景）、用户 PATH 追加 | `Add-ToPath`、`Fail-Install`、`Complete-Install`、`$script:InstallExitCode` |

### 2. Node 安装解析

在 OpenClaw 的安装器里，Node 的安装本质上是**委托给系统/平台包管理器**完成的，自己本身并没有 Node 安装流程，它主要做的是：

1. 检测 Node 是否存在、版本是否达标；

2. 按 OS 选择安装渠道（Windows: `winget/choco/scoop`；macOS: `brew`；Linux: `pacman` 或 NodeSource + `apt/dnf/yum`）；比如 Windows，会按顺序：`winget` → `choco` → `scoop` 尝试安装 Node。

3. 安装成功做一次 PATH 刷新（重读 Machine/User 的 `Path` 到当前 `$env:Path`）然后继续流程。

4. **潜在问题**：Windows 版本在安装完 Node 后，并没有像 macOS/Linux 版本一样做**安装后再次校验 active shell Node 版本**的逻辑（「装完必须 ≥22」的二次强校验），可能会导致 Node 仍然使用旧版的问题。

   比如，用户之前使用 Node 官网 MSI 安装过旧版 Node，脚本会尝试用 `winget/choco/scoop` 再装一份（通常是 LTS），但不保证自动覆盖或卸载 MSI 安装，也不保证 `PATH` 一定切到新 Node；若仍解析到旧版，需要用户调整 `PATH` 或卸掉旧安装。

5. 安装过程中的问题，可以参考：[故障排除](https://docs.openclaw.ai/zh-CN/install/installer#%E6%95%85%E9%9A%9C%E6%8E%92%E9%99%A4)。

### 3. Git 安装分析

Git 在 git 安装模式下是必须（`-InstallMethod git`），且默认的 npm 模式也“可能”依赖 Git，因为某些 npm 依赖会是 `github:`、`git+https:` 这类来源，npm 安装时会调用 git。不装 Git，最常见结果是 npm 报 `spawn git ENOENT` 或类似“找不到 git”错误。

### 4. OpenClaw 下载分析

有两种安装路径：`-InstallMethod npm` 和 `-InstallMethod git`

**npm 安装：**

- 先做前置检查（执行策略、Node、Git 可用性提示）
- 然后调用： `npm install -g <installSpec> --no-fund --no-audit`
- 其中 `<installSpec>` 由 `-Tag` 解析而来：
  - 默认 `latest` -> `openclaw@latest`
  - `main` -> `github:openclaw/openclaw#main`
  - 其它 tag/version -> `openclaw@<tag>`
- 安装后尝试把 `npm config get prefix` 加到用户 PATH。

**git 安装：**

- `git clone/pull` 仓库
- `pnpm install`
- `pnpm build`
- 生成 `openclaw.cmd` 包装器并加到 PATH。

## 我们的安装脚本说明

我们在官网安装脚本的基础上，做了自定义的二次开发，既保留了部分功能，又针对国内的小白用户他拓展了一些功能。

### node

## 关于 `node-installer.ps1` 的安装说明

这个脚本是专门用来安装 node，是为了解决 OpenClaw 内置的 Node 需要翻墙的问题。

### 安装原理

我们基于官方 [Node](https://github.com/nodejs/node) 的 MSI 安装原理，实现了 ps1 版本的 Node 安装脚本。

安装流程大致如下：

1. 确保安装权限正确
   把安装统一为机器级安装，要求管理员权限；如果当前不是管理员，就引导到管理员上下文继续安装。
2. 获取官方指定版本安装包
   从淘宝镜像地址下载 Node `v24.15.0` 的 Windows x64 zip，作为唯一安装来源，避免版本漂移。
3. 把 Node 落地到标准系统目录
   将包内容部署到 `C:\Program Files\nodejs`，形成与传统 Windows 安装一致的主安装位置（`node.exe`、npm/npx、node_modules 等都在这里）。
4. 固化“安装器能力”到本机
   把安装/卸载脚本副本放到 `C:\Program Files\nodejs\installer`，让后续卸载不依赖项目仓库或外部路径。
5. 注册系统安装信息
   写入 Windows 卸载信息（显示名 `Node.js`、版本 `24.15.0`、卸载入口等）以及 Node 安装信息（安装路径/版本），让系统和其他工具能识别这是一个已安装的软件。
6. 配置命令可用性并立即生效
   更新系统 PATH（Node 主目录）和用户 PATH（`%AppData%\npm`），然后广播环境变量变更，让新开的终端可以直接使用 `node` / `npm`。

## 关于 `openclaw-installer.ps1` 的安装说明

我们的安装脚本采用：自研预装必备环境(node/git) + 执行 `OpenClaw install.ps1`（或者直接使用 npm 安装？） + 自研安装配置（吸取 onboard 配置实现）+ 自研 gateway 启动的策略。

### 安装流程

1. 

2. 先检测有没有安装过 Node，如果没有，则使用 `node-installer`，解决国内安装慢的问题，如果之前安装过，则使用 openclaw 的官方脚本逻辑

