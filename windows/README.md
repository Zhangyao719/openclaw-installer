Windows 版本的脚本使用说明

## OpenClaw 官方安装脚本解析

OpenClaw 官方有两种 `install.ps1` 脚本，分别为：

1. https://github.com/openclaw/openclaw/blob/main/scripts/install.ps1
2. https://openclaw.ai/install.ps1

其中第二个是面向用户的版本（我们安装 OpenClaw 时用的），以下是针对第二个版本做的分析。

### 1. OpenClaw install 功能模块划分

| 模块 | 职责 | 主要符号 |
| :--- | :--- | :--- |
| **0. 前置与全局** | `param`（`Tag`/`InstallMethod`/`GitDir`/`NoOnboard`/`NoGitUpdate`/`DryRun`）；未显式传入时可用环境变量覆盖：`OPENCLAW_INSTALL_METHOD`、`OPENCLAW_GIT_DIR`、`OPENCLAW_NO_ONBOARD=1`、`OPENCLAW_GIT_UPDATE=0`、`OPENCLAW_DRY_RUN=1`；`$ErrorActionPreference = Stop`；退出码 `Fail-Install` / `Complete-Install`（失败时：独立脚本 `exit`，被点源时 `throw`）；横幅；要求 **PowerShell 5+**；默认 `GitDir` 为 `%USERPROFILE%\openclaw` | `$script:InstallExitCode`、`Fail-Install`、`Complete-Install` |
| **1. Node.js** | **1.1** `Check-Node`：检查 `node -v` 且主版本 ≥ 22；**1.2** `Install-Node`：依次尝试 `winget`（OpenJS.NodeJS.LTS）→ Chocolatey → Scoop；成功后刷新当前进程的 `$env:Path` | `Check-Node`、`Install-Node` |
| **1.3 已有安装** | 通过 PATH 上是否存在 `openclaw`/`openclaw.cmd` 判断是否为**升级**场景，影响后续是否跑 `doctor` 与文案 | `Check-ExistingOpenClaw`、`Get-OpenClawCommandPath` |
| **2. Git** | **2.1** `Check-Git`；**2.2** `Add-ToProcessPath`（仅当前进程 PATH）；**2.3～2.4** 便携 Git 目录、`git.exe` 定位与启用；**2.5** `Resolve-PortableGitDownload`（GitHub API 解析 MinGit zip）；**2.6** `Install-PortableGit` 下载解压到 `%LOCALAPPDATA%\OpenClaw\deps\portable-git`；**2.7** `Ensure-Git`：系统 Git → 已有便携 → 自动拉便携 → 失败则提示手动安装 Git for Windows（**非**仅靠 winget 装 Git） | `Ensure-Git`、`Install-PortableGit` 等 |
| **3. 命令与 PATH** | 解析并调用 `openclaw`；解析 `npm`/`corepack`/`pnpm`；`Get-NpmGlobalBinCandidates`；**Ensure-OpenClawOnPath**：若 PATH 上还没有 `openclaw`，则根据 npm 全局目录自动把含 `openclaw.cmd` 的路径写入**用户** PATH；**Ensure-Pnpm**：git 安装链路优先 corepack 启用 pnpm，否则 `npm install -g pnpm` | `Invoke-OpenClawCommand`、`Ensure-OpenClawOnPath`、`Ensure-Pnpm` 等 |
| **4. 安装本体** | **4.1** `Resolve-NpmOpenClawInstallSpec`：把 `-Tag` 转成 npm 安装说明（含 URL、`github:`、`git+`、`file:`、本地路径、`.tgz` 等显式 spec）；**4.2** `Install-OpenClaw`：`npm install -g`，临时收紧 npm 日志/赞助/审计等环境变量，并可跳过部分可选原生模块下载；**4.3** `Install-OpenClawFromGit`：克隆或按需 `pull --rebase`（工作区脏则跳过拉取）、`pnpm install`、`ui:build`（失败仅警告）、`pnpm build`、生成 `%USERPROFILE%\.local\bin\openclaw.cmd` 并补用户 PATH；**4.4** `Get-LegacyRepoDir` / `Remove-LegacySubmodule`：删除仓库内旧版 `Peekaboo` 子模块目录 | `Install-OpenClaw`、`Install-OpenClawFromGit`、`Remove-LegacySubmodule` |
| **5. 装后** | **5.1** `Run-Doctor`：非交互执行 `openclaw doctor` 做配置迁移（错误忽略）；**5.2** `Refresh-GatewayServiceIfLoaded`：若检测到网关服务已加载则 `gateway install --force` 并尝试 `gateway restart` | `Run-Doctor`、`Test-GatewayServiceLoaded`、`Refresh-GatewayServiceIfLoaded` |
| **6. Main** | `DryRun` 仅打印将执行选项；正式流程：清理遗留子模块 → 判定升级 → 保证 Node → 按 `InstallMethod` 走 npm 或 git 安装（切换方式时会删掉另一种方式留下的 wrapper/全局包）→ **Ensure-OpenClawOnPath** → 网关刷新 → 升级或 git 安装时跑 doctor → 解析版本号与随机提示文案 → 升级则提示可再跑 `doctor`；全新安装且未 `-NoOnboard` 则调用 **`openclaw onboard`**（与仅打印提示命令不同） | `Main` |

说明：该脚本**不包含**「进程级修改 ExecutionPolicy」一类逻辑；若遇 `npm.ps1` 被策略拦截，需用户自行调整执行策略（与带 `Ensure-ExecutionPolicy` 等自动修复的其它变体不同）。

### 2. Node 安装解析

在 **install.ps1** 中，Node 的安装同样是**委托给 Windows 上的包管理器**（`winget` / `choco` / `scoop`），脚本自身不负责内置 Node 分发包。流程要点：

1. **检测**：用 `node -v` 判断是否存在且主版本 **≥ 22**。
2. **安装顺序**：`winget` → Chocolatey → Scoop；若无任一包管理器则提示前往 Node 官网或安装 winget。
3. **PATH**：安装或检测到 Node 后，会**重读** Machine/User 的 `Path` 合并进当前 `$env:Path`（至少 winget 分支成功后会再 `Check-Node` 验证）。
4. **二次校验**：若自动安装 Node 后当前 shell 仍拿不到 ≥22，脚本会**报错并提示重开终端再运行**，避免 silent 继续。
5. **环境并存**：与用户本机已装的其它 Node（如旧 MSI）并存时，仍以当前 shell 解析到的 `node` 为准；若 PATH 仍指向旧版，需用户自行调整 PATH 或卸载冲突安装。
6. 通用故障可参考：[故障排除](https://docs.openclaw.ai/zh-CN/install/installer#%E6%95%85%E9%9A%9C%E6%8E%92%E9%99%A4)。

### 3. Git 安装分析

- **npm 模式（`-InstallMethod npm`）**：在安装 OpenClaw 前会 **`Ensure-Git` 成功**，即 Git 为**硬前置**（依赖安装过程中可能出现 `github:` / git 拉取等场景）；失败则 npm 安装阶段无法继续。
- **git 模式**：同样必须先有可用的 `git`，再走克隆与 `pnpm` 构建。
- **与「仅 winget 装 Git」类脚本的区别**：本脚本优先系统 PATH 中的 Git；若无则尝试**用户目录便携 MinGit**（从 GitHub 发行版解析 MinGit zip 下载解压）；仍失败才提示安装 Git for Windows。

### 4. OpenClaw 下载分析

两种安装路径：`-InstallMethod npm` 与 `-InstallMethod git`。

**npm 安装**

- 保证 Node（≥22）与 Git（`Ensure-Git`）后执行 `npm install -g "<installSpec>"`；安装过程中可临时设置 npm 相关环境变量以减少噪音、跳过部分可选下载等。
- `<installSpec>` 由 `Resolve-NpmOpenClawInstallSpec` 根据 `-Tag` 生成，规则概要：
  - 空或缺省 → `openclaw@latest`（内部会先规范 `Tag`）；
  - 形如 `http(s):`、`file:`、`git+`/`github:`、盘符路径、UNC、相对路径、`.tgz` 等 → **原样**作为安装说明传给 npm；
  - 否则 → `openclaw@<Tag>`（`beta` 等标签在脚本内与包名组合使用，以脚本当前逻辑为准）。
- 安装结束后通过 **Ensure-OpenClawOnPath** 尝试把 npm 全局 bin（含 `openclaw.cmd` 的目录）写入用户 PATH。

**git 安装**

- 可选卸载全局 npm 包 `openclaw`，避免与源码安装并存冲突。
- `git clone` 官方仓库；在未禁用更新且工作区干净时 `git pull --rebase`。
- **Remove-LegacySubmodule**：删除仓库内旧 `Peekaboo` 目录。
- **Ensure-Pnpm** 后：`pnpm install`、`pnpm ui:build`（失败仅警告）、`pnpm build`。
- 在 `%USERPROFILE%\.local\bin\openclaw.cmd` 写入调用 `dist\entry.js` 的包装，并把该目录加入用户 PATH。

**装后统一行为（与仅「下载包」相关的部分）**

- 若判定为**升级**或当前为 **git 安装**，会执行 **`openclaw doctor --non-interactive`**；若检测到网关服务已加载则尝试刷新/重启网关。
- 全新安装且未指定 `-NoOnboard` 时，脚本会**直接调用 `openclaw onboard`** 进入引导（不仅是打印命令提示）。

## OpenClaw `onboard` 使用说明

👉️ [openclaw-onboard 说明文档](./docs/openclaw-onboard.md)

## 我们的安装脚本说明

我们在官网安装脚本的基础上，做了自定义的二次开发，既保留了部分功能，又针对国内的小白用户拓展了一些功能。

我们提供两种脚本，一种是面向用户使用的 `install-user.ps1`，一种是面向开发者的 `install-script.ps1`，前者有交互引导页面，对新用户更有好，后者则更倾向直接部署运行，更方便。

### 🌈 新增功能

- 设置 `npm` 下载源为淘宝镜像。

  新增 `Set-NpmRegistryMirror` 函数，设置淘宝镜像。

  对于 `install-user.ps1` ，如果 node 安装失败，会有 node 安装教程提示。

- 调用 `onboard` 的同时，传递部分参数，实现非交互向导。

  ```bash
  openclaw onboard --accept-risk \
    --non-interactive \
    --reset \
    --reset full \
    --flow quickstart \
    --skip-channels \
    --skip-skills \
    --skip-search \
    --skip-ui \
    --json \
  ```
  
  **关于模型设置的说明**：
  
  对于 `install-user.ps1`，需要用户准备模型相关配置，脚本会以对话的形式让用户选择模型和输入 apikey。
  
  对于 `install-script.ps1`，没有对话交互，而是直接使用 `-AuthChoice`、`-Provider`、`-ApiKey`三个参数来直接指定模型配置信息（**必传**）。
  
  具体用法详见下方[📖使用方法](#-使用方法)。
  
- 预先安装部分常用 Skills

  ```tex
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
  ```
  
- 单独进行 md 模板配置

  todo

- 执行 `dashboard` 自动打开浏览器

  `install-script.ps1`只执行，不打开浏览器

### 🚀 安装流程

1. 环境检测（与官方保持一致）
2. NodeJS 安装（与官方保持一致）+ npm 下载源替换
3. Git 安装（与官方保持一致）
3. 确保环境正常：openclaw/npm/pnpm 路径、调用、全局 bin、补全 PATH、确保 pnpm
4. 下载安装 OpenClaw 本体（与官方保持一致）
5. 装后：doctor 迁移、网关服务刷新、预装 Skills（全新安装）
6. 进行 `onboard` 引导配置
7. 进行 Skills 配置
8. 进行 md 模板配置
9. 通过 `dashboard` 获取 token URL，并自动打开浏览器

### 📖使用方法

#### 命令示例

```powershell
# 使用交互安装脚本
iex ((irm 'https://raw.githubusercontent.com/Zhangyao719/openclaw-installer/main/windows/install-user.ps1').TrimStart([char]0xFEFF))

# 使用非交互脚本（适合服务器直接跑）
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Zhangyao719/openclaw-installer/main/windows/install-user.ps1').TrimStart([char]0xFEFF))) -AuthChoice moonshot-api-key-cn -Provider moonshot-api-key -ApiKey sh-xxx123
```

## FAQ

### 为什么脚本不能直接进行 `onboard` 交互向导，要人工输入才可以？

根本原因是 stdin 的 TTY 状态不同，导致 `openclaw onboard` 的内部行为分叉。

人为在终端手动输入 `openclaw board` 时，Node.js 检测到完整的交互式 TTY，openclaw 进入 TUI 模式，渲染界面、等待用户操作，一切正常。

```tex
你的 shell → openclaw.cmd → node → openclaw onboard
                                        ↑
                    process.stdin.isTTY  = true
                    process.stdout.isTTY = true
```

从 PowerShell 脚本调用 `& openclaw.cmd @Arguments`。

```te
pwsh -File install.ps1
  └─ & openclaw.cmd @args
       └─ cmd.exe (Volta shim)
            └─ node → openclaw onboard
                           ↑
           process.stdin.isTTY  = true  ← PowerShell 没有重定向 stdin
           process.stdout.isTTY = false ← PowerShell 接管了 stdout 管道
```

关键差异：stdout 不再是 TTY，但 stdin 仍然是 TTY。这个"半 TTY"状态导致 openclaw 内部进入一种矛盾的模式：

- 认为有人在键盘前（`stdin.isTTY = true`）→ 进入"需要等待用户操作"的交互分支
- 但无法渲染 TUI（`stdout.isTTY = false`）→ 界面什么都不显示
- 加上 gateway 未运行（`ECONNREFUSED`），交互分支默认行为是无限等待 gateway 或等待用户输入

结果：界面空白、进程挂起。

脚本内的 `onboard` 传入了 `--non-interactive` 参数，明确告诉 openclaw：不要依赖 stdin 的 TTY 状态，直接走非交互流程，有错误就输出并以非零码退出，而不是等待。
