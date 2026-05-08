# 🦞 OpenClaw 一键安装工具

> 🤩 支持多平台一键安装，免去配置烦恼

## 一、安装脚本说明

我们在官网安装脚本的基础上，做了自定义的二次开发，既保留了部分功能，又针对国内的用户拓展了一些功能。

### 🌈快速入门

👉️ [Windows 版本](./windows/README.md)

👉️ [Linux/macOS/WSL 版本](./linux/README.md)

### 🚀新增功能

#### 1. 设置 `npm` 下载源为淘宝镜像

我们将 `npm`下载源设置成了国内淘宝镜像，避免了国外下载过慢的问题。

#### 2. 简化的 `onboard` 交互向导

我们通过修改了 `onboard` 的调用参数，精简了向导的部分交互逻辑，保留了最重要的**模型和网关**配置。

需要注意的是，`Windows`版本和 `Linux/macOS/WSL` 的表现形式不太一样：

- `Linux/macOS/WSL` 版本能够显示简化后的 `onboard` 交互向导，除了配置模型，还需要选择 `hooks`，因为 `onboard` 并没有提供跳过 `hooks`的参数 。

- `Windows`版本由于系统原因，无法使用简化版的交互向导，所以全部采用 `onboard` 的非交互模式（`--non-interactive`）+ 自研模型交互 + 自动配置 `skills` 的方式。用户无需选择 `hooks`。

#### 3. 配置 Hooks

`Linux/macOS/WSL` 版本在进行交互式 `onboard` 时，会自带 Hooks 的交互配置。

`Windows` 版本使用的是非交互式 `onboard`，不会配置 Hooks，所以会通过主动执行命令来启用 Hooks。

#### 4. 预装常用 Skills

```tex
'self-improving-agent',		自我迭代智能体
'data-analyst',				专业数据分析
'find-skills',				智能检索匹配可用技能
'humanizer',				文本拟人化润色
'markdown-converter',		各类格式与 Markdown 互转
'memory-setup',				配置初始化智能记忆库
'multi-search-engine',		多引擎聚合搜索
'nano-pdf',					轻量 PDF 处理
'ontology',					构建知识体系
'proactive-agent',			主动式智能体
'skill-vetter',				skills 安全审查
'summarize'					智能摘要提炼
```

todo: 后续需要按用户角色分组，让用户可选，并安装 Meerkat AI 自研 skills。

#### 5. 单独进行 md 模板配置

todo

#### 6. 执行 `dashboard` 自动打开浏览器

## 二、拓展阅读

### OpenClaw `onboard` 向导调研

详情参考 👉️ [openclaw-onboard 说明文档](./docs/openclaw-onboard.md)
