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

## OpenClaw `onboard` 使用说明

👉️ [openclaw-onboard 说明文档](./docs/openclaw-onboard.md)

## 我们的安装脚本说明

我们在官网安装脚本的基础上，做了自定义的二次开发，既保留了部分功能，又针对国内的小白用户拓展了一些功能。

### 🌈 新增功能

- 设置 `npm` 下载源为淘宝镜像。

  新增 `Set-NpmRegistryMirror` 函数，设置淘宝镜像。

- 主动调用 `onboard` 进行基础配置。

  ```bash
  openclaw onboard --accept-risk \
    --flow quickstart \
    --gateway-auth token \
    --install-daemon \
    --skip-channels \
    --skip-skills \
    --skip-search \
    --skip-ui \
    --json \
  ```

- 单独进行 Skills 配置。

  安装 `SkillHub` ，再预装 Skills。

- 单独进行 md 模板配置

  todo

- 自动打开浏览器

### 🚀 安装流程

1. 环境检测（与官方保持一致）
2. NodeJS 安装（与官方保持一致）+ npm 下载源替换
3. Git 安装（与官方保持一致）
4. 下载安装OpenClaw（与官方保持一致）
5. 收尾，将 npm global prefix 写入用户 PATH（与官方保持一致）
6. 进行 `onboard` 引导配置
7. 进行 Skills 配置
8. 进行 md 模板配置
9. 通过 `dashboard` 获取 token URL，并自动打开浏览器

