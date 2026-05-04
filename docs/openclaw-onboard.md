# OpenClaw `onboard` 命令参考（含非交互模式）

本文档结合 [openclaw/openclaw](https://github.com/openclaw/openclaw) 源码（CLI 注册见 `src/cli/program/register.onboard.ts`）与官方文档 [CLI onboard](https://docs.openclaw.ai/cli/onboard) 整理，便于脚本化安装与自动化部署。

**版本提示：** 具体可选值（尤其是各云厂商的 `--xxx-api-key`）会随已加载扩展/发行版变化，请以本机 `openclaw onboard --help` 为准。

---

## 一、非交互模式怎么用

### 1.1 必备参数（脚本自动化）

| 参数 | 说明 |
|------|------|
| `--non-interactive` | 关闭所有问答提示，适合 CI / 安装脚本。 |
| `--accept-risk` | 声明你已阅读安全风险说明；**非交互模式下与上一项绑定**，缺一不可。 |

基础骨架：

```bash
openclaw onboard --non-interactive --accept-risk
```

### 1.2 与「是否交互」无关但常被脚本使用的参数

| 参数 | 默认值（源码） | 说明 |
|------|----------------|------|
| `--json` | `false` | 会挑与本次 onboard 结果相关的关键信息**在结尾输出结构化摘要**（便于机器解析）；<br>**不**等同于非交互，需同时加 `--non-interactive` 才能无人值守。 |

```json
// 比如，本地非交互 — 成功，显示如下结构化摘要：
{
  "ok": true,
  "mode": "local",
  "workspace": "C:\\Users\\you\\.openclaw\\workspace",
  "authChoice": "skip",
  "gateway": {
    "port": 18789,
    "bind": "loopback",
    "authMode": "token",
    "tailscaleMode": "off"
  },
  "installDaemon": false,
  "daemonInstall": {
    "requested": true,
    "installed": true,
    "skippedReason": "systemd-user-unavailable"
  },
  "daemonRuntime": "node",
  "skipSkills": false,
  "skipHealth": false
}
```



### 1.3 `--modern`（单独一类）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--modern` | `false` | 启用 Crestodian 对话式引导预览（即聊天对话的形式进行）；**不会**走下文「经典 onboard」管线。非交互时相当于固定跑概览类流程。 |

自动化若要经典向导，**不要**加 `--modern`。

---

## 二、流程、模式与迁移

### 2.1 `--flow`：走哪条向导线

| 取值 | 含义（通俗） |
|------|----------------|
| `quickstart` | 尽量少问，偏一键 defaults。具体见下方详解。 |
| `advanced` / `manual` | `manual` 是 `advanced` 的别名，步骤更全。 |
| `import` | 从其它助手/产品迁移配置（具体提供方由插件定义）。 |

`quickstart` 的默认配置如下：

1. 未传 `--mode` 时，直接当 `local` 使用。

2. 未传 `--workspace` 时，直接用已有配置里的路径或默认 `DEFAULT_WORKSPACE`（约 `~/.openclaw/workspace`）

3. 网关：端口、绑定、鉴权方式、Tailscale，会直接用已经计算好的值。

   - bind：`loopback`（只本机回环）
   - 鉴权方式：`token`（和已有 token 时继承不同）
   - Tailscale：`off`
   - 端口：`resolveGatewayPort(baseConfig)`（缺省一般是 18789）

   若配置中已有，会尽量沿用。

4. 通道（聊天渠道），少掉部分确认/策略类提示，用快速默认策略填通道相关项。

5. 搜索、技能

   - Search：`quickstartDefaults: true`，倾向用快速默认，而不是问满全套。
   - Skills：仍执行 `setupSkills`，但前面通道那套「QuickStart 默认」已整体偏自动化。

6. 官方插件与插件配置向导，会直接跳过。

7. 安装 Gateway 服务

   在未手动指定 `--install-daemon` / `--no-install-daemon` 且平台允许时，默认认为要装网关服务（`installDaemon = true`），不再问「要不要装」。

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--flow <flow>` | 未传则由交互挑选；非交互里常与其它参数组合推断 | **否** | 与 `--import-from` 等配合做迁移时可用 `import`。 |

**官方提醒**：`import` 适合「干净环境」。不能有已有实质配置、工作区关键文件、state 下 配置/凭据(credentials)/会话(sessions)/agents 等；否则会报错，提示你先 `--reset` 或换干净目录。

```bash
# 示例，从 hermes 中迁移配置
openclaw onboard --non-interactive --accept-risk \
  --flow import \
  --import-from hermes \
  --import-source "$HOME/.hermes"
```

### 2.2 `--mode`：配本机网关还是只连远程

| 取值 | 含义 |
|------|------|
| `local` | 在本机写入 `gateway.mode=local` 等，走完整本地安装逻辑（通道、技能等是否执行取决于跳过项）。 |
| `remote` | **只**把「远程网关地址 + 可选 token」写入配置，不在本机装插件包；适合客户端只想连已有网关。 |

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--mode <mode>` | 未显式传时由逻辑推断（本地管线默认按本地处理） | **remote 时强烈建议显式传** | 与 `--remote-url` 配合见第五节。 |

---

## 三、重置与工作区

### 3.1 重置（装一半重来）

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--reset` | `false` | **否** | 为 `true` 时先清再 onboard。 |
| `--reset-scope <scope>` | 若启用 `--reset` 而未写 scope，源码侧会以 **`config+creds+sessions`** 为默认重置范围 | **否**（但若要用「仅清配置」等需显式写） | 取值：`config` \| `config+creds+sessions` \| `full`（`full` 会波及 workspace）。 |

### 3.2 工作区目录

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--workspace <dir>` | 约 `~/.openclaw/workspace`（以 CLI 描述为准） | **否** | Agent 工作目录；不传则用默认或已有配置中的路径。 |

### 3.3 是否生成默认工作区引导文件

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--skip-bootstrap` | `false` | **否** | 为 `true` 时不生成 `AGENTS.md`、`SOUL.md` 等默认引导文件（相当于你自己管工作区模板）。 |

---

## 四、模型侧认证与密钥写法

### 4.1 总开关

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--auth-choice <choice>` | 未传时，非交互会尝试根据你给出的「某一个」厂商 key 类参数**推断**；都未提供则等价 **`skip`**（不配模型密钥，只配网关等其它项） | **否**（多 key 冲突时需显式指定） | 告诉 onboard「你要用哪种方式给 AI 模型接入身份 / 密钥」 |
| `--secret-input-mode <mode>` | **`plaintext`** | **否** | `plaintext`：把密钥以明文写入配置（或允许明文字段）；`ref`：写入引用（如环境变量名），密钥应在进程环境里可见，见官方「ref 模式合约」。 |

**关于 `<choice>`的说明**

- `<choice>` 的值可以通过 `openclaw onboard --help` 查看，见 👉️  [十二、延伸阅读](#extend)。

- 不同的 `<choice>`，需要配置不同的参数，具体可参考以下的 4.2/4.3/4.4/4.5。

**非交互推断规则（通俗）：** 若你同时传了多个不同厂商的 `--xxx-api-key`，脚本不知道选谁，必须改传**单一** key 或显式 `--auth-choice`。

### 4.2 Token 型认证{#token}

`--auth-choice token` 时使用。

非交互模式下必传（缺任意一个会直接报错）：

- `--token-provider <id>`：哪家。
- `--token <token>`：令牌。

具体参数如下：

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--token-provider <id>` | 无 | **按所选 provider 要求** | 指明 token 对应哪家/哪条接入。 |
| `--token <token>` | 无 | 视策略 | Token 字面值。 |
| `--token-profile-id <id>` | 文档/实现默认形如 `<provider>:manual` | **否** | 写入认证档案用的 id。 |
| `--token-expires-in <duration>` | 无 | **否** | 如 `365d`、`12h`。 |

```bash
# 示例
openclaw onboard --non-interactive --accept-risk \
  --auth-choice setup-token \
  --token-provider anthropic \
  --token "你的_Anthropic_访问令牌"
```

### 4.3 Cloudflare AI Gateway

`--auth-choice cloudflare-ai-gateway-api-key` 时使用。

走 Cloudflare AI Gateway 这条官方接入——程序会按你的 Cloudflare 账号 ID + Gateway ID 拼出固定格式的底座地址（例如 `https://gateway.ai.cloudflare.com/v1/<account>/<gateway>/anthropic`），并用内置好的 Anthropic Messages 形态去连，默认模型走插件里定义的那套（如 Claude Sonnet 4.6），不需要你自己手写整段 `baseUrl`。

非交互模式下必传（缺任意一个会直接报错）：

- `--cloudflare-ai-gateway-account-id`
- `--cloudflare-ai-gateway-gateway-id`

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--cloudflare-ai-gateway-account-id <id>` | 无 | 使用该通路时 **是** | Cloudflare 账号 ID。 |
| `--cloudflare-ai-gateway-gateway-id <id>` | 无 | 使用该通路时 **是** | AI Gateway 实例 ID。 |

### 4.4 各厂商 动态注册 API Key（最常用）

`--auth-choice <厂商>-api-key`  时使用。

多数你看到的「各厂商」并不是你另外去商店装的，而是跟着 OpenClaw 主仓库 / npm 包一起带的。在 [OpenClaw 的仓库](https://github.com/openclaw/openclaw/tree/main/extensions)中已经内置了一整个`extensions\` 目录，它们各自带 `openclaw.plugin.json`。随官方安装包/源码一起发布，对用户来说就像「内置扩展」。

以下是 `moonshot` 在 OpenClaw 中的 `openclaw.plugin.json`文件

```json

{
    // ......
    "providerAuthChoices": [
        // 国外的
        {
          "provider": "moonshot",
          "method": "api-key",
          "choiceId": "moonshot-api-key",
          "choiceLabel": "Moonshot API key (.ai)",
          "groupId": "moonshot",
          "groupLabel": "Moonshot AI (Kimi K2.6)",
          "groupHint": "Kimi K2.6",
          "optionKey": "moonshotApiKey",
          "cliFlag": "--moonshot-api-key",
          "cliOption": "--moonshot-api-key <key>",
          "cliDescription": "Moonshot API key"
        },
        // 国内的
        {
          "provider": "moonshot",
          "method": "api-key-cn",
          "choiceId": "moonshot-api-key-cn", // 对应 --auth-choice <choice> 中的 <choice>
          "choiceLabel": "Moonshot API key (.cn)",
          "groupId": "moonshot",
          "groupLabel": "Moonshot AI (Kimi K2.6)",
          "groupHint": "Kimi K2.6",
          "optionKey": "moonshotApiKey",
          "cliFlag": "--moonshot-api-key",
          "cliOption": "--moonshot-api-key <key>", // 对应必传的密钥参数本身
          "cliDescription": "Moonshot API key"
        }
      ]
}
```

非交互模式下必传：

- 密钥本身：比如上述文件中对应的 `cliFlag/cliOption`。

| 说明 |
|------|
| **不在此文档逐条列出**；请运行 `openclaw onboard --help` 查看当前构建下全部 key 类选项与描述。 |
| 官方示例包括：`--mistral-api-key`、`--lmstudio-api-key`、`--zai-api-key`（及多种 Z.AI endpoint 对应的 `--auth-choice`）等。 |

### 4.5 自定义 OpenAI / Anthropic 兼容接口{#custom-api-key}

`--auth-choice custom-api-key`  时使用。

非交互模式下必传（缺任意一个会直接报错）：

- `--custom-base-url`：服务根地址（合法 URL）。
- `--custom-model-id`：要用的模型名。

具体参数如下：

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--custom-base-url <url>` | 无（部分场景如 Ollama 文档写明可默认 `http://127.0.0.1:11434`） | 走自定义兼容接口时 **通常需要** | 兼容服务的 Base URL。 |
| `--custom-api-key <key>` | 无 | **否** | 不显式传时，自定义通路可能回退读环境变量（如 `CUSTOM_API_KEY`，以官方说明为准）。 |
| `--custom-model-id <id>` | 无 | **否** | 默认模型 id；Ollama 等可不传则用建议默认。 |
| `--custom-provider-id <id>` | 自动推导 | **否** | 高级用户固定 provider 名。 |
| `--custom-compatibility <mode>` | **`openai`** | **否** | `openai` 或 `anthropic` 协议形态。 |
| `--custom-image-input` | `false` | **否** | 声明模型支持图像输入（未知 vision id 时常用）。不配时也会按模型名猜 |
| `--custom-text-input` | `false` | **否** | 声明纯文本；若与上一项同时出现，**源码以 text 为准覆盖 image**。不配时也会按模型名猜 |

---

## 五、本机 Gateway（监听、鉴权、Tailscale）

默认端口在配置层常用 **`18789`**（见 `DEFAULT_GATEWAY_PORT`）；未指定且配置为空时由解析逻辑决定。

### 5.1 端口与绑定

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--gateway-port <port>` | 未传则用当前/默认解析端口（常为 18789） | **否** | 网关 HTTP+WS 复用端口。 |
| `--gateway-bind <mode>` | 未传则沿用已有或向导默认 | **否** | `loopback` \| `lan` \| `auto` \| `custom` \| `tailnet`。 |

### 5.2 网关访问控制（token / 密码）

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--gateway-auth <mode>` | 未传则继承已有或向导默认 | **否** | `token` 或 `password`。 |
| `--gateway-token <token>` | 无 | **否** | token 模式下的明文 token。 |
| `--gateway-token-ref-env <name>` | 无 | **否** | token 写入为「环境变量引用」，运行时必须能解析；**与 `--gateway-token` 互斥**（勿同时用于表达同一字段）。 |
| `--gateway-password <password>` | 无 | **否** | 密码模式下的密码。 |

官方补充：`--install-daemon` 且 token 用 SecretRef 时，解析失败会**阻止安装**；token/password 若同时存在且 mode 未指定，也可能阻塞 daemon 安装直至显式指定。

### 5.3 Tailscale 暴露

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--tailscale <mode>` | 多为 `off` | **否** | `off` \| `serve` \| `funnel`。 |
| `--tailscale-reset-on-exit` | `false` | **否** | 退出向导时是否复位 serve/funnel。 |

---

## 六、远程 Gateway（仅客户端连接）

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--remote-url <url>` | 无 | **`--mode remote` 下必传** | 远端网关 WebSocket URL（如 `wss://...`）。 |
| `--remote-token <token>` | 无 | **否** | 远端可选访问令牌。 |

**环境变量（客户端）：** 对可信内网的明文 `ws://`，可在进程环境里设 `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1`（官方说明：无等价 `openclaw.json` 开关）。

---

## 七、守护进程、运行时与健康检查

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--install-daemon` | `false` | **否** | 为 `true` 时尝试安装系统服务 / Windows 计划任务 / 启动项等（平台相关）。 |
| `--no-install-daemon` / `--skip-daemon` | — | **否** | 明确不装服务；**若命令行显式传了 `--skip-daemon`，优先于 `--install-daemon`**。 |
| `--daemon-runtime <runtime>` | 实现默认 **`node`**（`DEFAULT_GATEWAY_DAEMON_RUNTIME`） | **否** | `node` 或 `bun`。 |
| `--skip-health` | `false` | **否** | 为 `true` 时不等待本地网关连通即结束；适合只生成配置、由你稍后手动 `openclaw gateway run`。 |

**健康检查（通俗）：** 非交互本地路径默认会等服务就绪；若不装 daemon 又没手工先跑网关，会超时失败——此时要么先启动网关，要么加 `--install-daemon`，要么 `--skip-health`。

---

## 八、跳过类（精简自动化步骤）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--skip-channels` | `false` | 不配聊天通道（微信、Telegram 等扩展带来的向导步骤）。 |
| `--skip-skills` | `false` | 不配 Skills。 |
| `--skip-search` | `false` | 不配联网搜索提供方。 |
| `--skip-ui` | `false` | 不触发 Control UI / TUI 相关提示。 |

说明：`--skip-providers` 为旧别名，等价于 `--skip-channels`（若 help 仍列出）。

---

## 九、Skills 包管理器

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--node-manager <name>` | 未传则用环境/默认 | **否** | `npm` \| `pnpm` \| `bun`，影响 skills 安装命令。 |

---

## 十、迁移（从其它产品导入）

| 参数 | 默认值 | 非交互是否必传 | 说明 |
|------|--------|------------------|------|
| `--import-from <provider>` | 无 | **走迁移分支时必传**（非交互下导入路径要求显式） | 插件提供的迁移 id |
| `--import-source <path>` | 无 | 视提供方要求 | 源「agent home」路径。 |
| `--import-secrets` | `false` | **否** | 是否在迁移时导入支持的密钥。 |

常与 `--flow import` 搭配；详见官方示例与 `migrate` 命令文档。

**`<provider>` 可以取哪些指？**

在 openclaw 上游仓库当前 main 里，通过扩展清单挂上 `migrationProviders` 的内置 id 只有这三个：

1. `hermes`

2. `claude`

3. `codex`

4. 其它取值：任意 第三方插件 只要在自家 `openclaw.plugin.json` 的 `contracts.migrationProviders` 里声明并在运行时注册，就会出现新的 id；这就不是固定列表了。要看你当前环境里到底加载了哪些，最稳妥是 `openclaw onboard --help` 里迁移相关说明、`openclaw plugins inspect` / 官方插件列表，或直接 `grep`/查配置里已启用的迁移插件。

   **注意：**若某个迁移插件在你安装的 npm 包里 未启用或未打进构建，对应的 `--import-from` 在该环境里会 不存在或不可用。

---

## 十一、命令示例（可复制改写）

**1）最小非交互（仅接受风险位，模型侧 skip，其它默认）：**

```bash
openclaw onboard --non-interactive --accept-risk --auth-choice skip
```

**2）自定义兼容 API + 明文密钥：**

```bash
openclaw onboard --non-interactive --accept-risk \
  --auth-choice custom-api-key \
  --custom-base-url "https://llm.example.com/v1" \
  --custom-model-id "my-model" \
  --custom-api-key "$CUSTOM_API_KEY" \
  --custom-compatibility openai
```

**3）密钥走环境变量引用（不全写在命令行）：**

```bash
export OPENAI_API_KEY="sk-..."
openclaw onboard --non-interactive --accept-risk \
  --auth-choice openai-api-key \
  --secret-input-mode ref
```

**4）只连接远程网关（客户端）：**

```bash
openclaw onboard --non-interactive --accept-risk \
  --mode remote \
  --remote-url "wss://gateway.example.com:18789" \
  --remote-token "$REMOTE_TOKEN"
```

**5）网关 token 用环境变量名引用 + 跳过健康检查（先生成配置再由你手动起服务）：**

```bash
export OPENCLAW_GATEWAY_TOKEN="..."
openclaw onboard --non-interactive --accept-risk \
  --auth-choice skip \
  --gateway-auth token \
  --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
  --skip-health
```

**6）安装守护进程并 JSON 输出（便于上游编排解析）：**

```bash
openclaw onboard --non-interactive --accept-risk \
  --install-daemon \
  --json
```

---

## 十二、延伸阅读 {#extend}

- 官方：[CLI onboard](https://docs.openclaw.ai/cli/onboard)

- 安全说明（`--accept-risk` 指向的风险披露）：见文档内链接与 `openclaw onboard --help` 提示

  ```bash
  # 以下是 3.13 版本，执行 openclaw onboard --help 后所显示的所有参数
  
  OpenClaw 2026.3.13 (61d171a) — Type the command with confidence—nature will provide the stack trace if needed.
  
  Usage: openclaw onboard [options]
  
  Interactive wizard to set up the gateway, workspace, and skills
  
  Options:
    --accept-risk                            Acknowledge that agents are powerful and full system access is risky (required for --non-interactive) (default: false)
    --ai-gateway-api-key <key>               Vercel AI Gateway API key
    --anthropic-api-key <key>                Anthropic API key
    --auth-choice <choice>                   Auth:
                                             token|openai-codex|chutes|apiKey|openai-api-key|mistral-api-key|openrouter-api-key|kilocode-api-key|ai-gateway-api-key|cloudflare-ai-gateway-api-key|moonshot-api-key|kimi-code-api-key|gemini-api-key|zai-api-key|xiaomi-api-key|minimax-global-api|synthetic-api-key|venice-api-key|together-api-key|huggingface-api-key|opencode-zen|opencode-go|xai-api-key|litellm-api-key|qianfan-api-key|modelstudio-api-key-cn|modelstudio-api-key|volcengine-api-key|byteplus-api-key|moonshot-api-key-cn|github-copilot|gemini-api-key|google-gemini-cli|zai-api-key|zai-coding-global|zai-coding-cn|zai-global|zai-cn|xiaomi-api-key|minimax-global-oauth|minimax-global-api|minimax-cn-oauth|minimax-cn-api|qwen-portal|copilot-proxy|apiKey|opencode-zen|qianfan-api-key|modelstudio-api-key-cn|modelstudio-api-key|custom-api-key|ollama|sglang|vllm|skip|setup-token|oauth|claude-cli|codex-cli
    --byteplus-api-key <key>                 BytePlus API key
    --cloudflare-ai-gateway-account-id <id>  Cloudflare Account ID
    --cloudflare-ai-gateway-api-key <key>    Cloudflare AI Gateway API key
    --cloudflare-ai-gateway-gateway-id <id>  Cloudflare AI Gateway ID
    --custom-api-key <key>                   Custom provider API key (optional)
    --custom-base-url <url>                  Custom provider base URL
    --custom-compatibility <mode>            Custom provider API compatibility: openai|anthropic (default: openai)
    --custom-model-id <id>                   Custom provider model ID
    --custom-provider-id <id>                Custom provider ID (optional; auto-derived by default)
    --daemon-runtime <runtime>               Daemon runtime: node|bun
    --flow <flow>                            Wizard flow: quickstart|advanced|manual
    --gateway-auth <mode>                    Gateway auth: token|password
    --gateway-bind <mode>                    Gateway bind: loopback|tailnet|lan|auto|custom
    --gateway-password <password>            Gateway password (password auth)
    --gateway-port <port>                    Gateway port
    --gateway-token <token>                  Gateway token (token auth)
    --gateway-token-ref-env <name>           Gateway token SecretRef env var name (token auth; e.g. OPENCLAW_GATEWAY_TOKEN)
    --gemini-api-key <key>                   Gemini API key
    -h, --help                               Display help for command
    --huggingface-api-key <key>              Hugging Face API key (HF token)
    --install-daemon                         Install gateway service
    --json                                   Output JSON summary (default: false)
    --kilocode-api-key <key>                 Kilo Gateway API key
    --kimi-code-api-key <key>                Kimi Coding API key
    --litellm-api-key <key>                  LiteLLM API key
    --minimax-api-key <key>                  MiniMax API key
    --mistral-api-key <key>                  Mistral API key
    --mode <mode>                            Wizard mode: local|remote
    --modelstudio-api-key <key>              Alibaba Cloud Model Studio Coding Plan API key (Global/Intl)
    --modelstudio-api-key-cn <key>           Alibaba Cloud Model Studio Coding Plan API key (China)
    --moonshot-api-key <key>                 Moonshot API key
    --no-install-daemon                      Skip gateway service install
    --node-manager <name>                    Node manager for skills: npm|pnpm|bun
    --non-interactive                        Run without prompts (default: false)
    --openai-api-key <key>                   OpenAI API key
    --opencode-go-api-key <key>              OpenCode API key (Go catalog)
    --opencode-zen-api-key <key>             OpenCode API key (Zen catalog)
    --openrouter-api-key <key>               OpenRouter API key
    --qianfan-api-key <key>                  QIANFAN API key
    --remote-token <token>                   Remote Gateway token (optional)
    --remote-url <url>                       Remote Gateway WebSocket URL
    --reset                                  Reset config + credentials + sessions before running wizard (workspace only with --reset-scope full)
    --reset-scope <scope>                    Reset scope: config|config+creds+sessions|full
    --secret-input-mode <mode>               API key persistence mode: plaintext|ref (default: plaintext)
    --skip-channels                          Skip channel setup
    --skip-daemon                            Skip gateway service install
    --skip-health                            Skip health check
    --skip-search                            Skip search provider setup
    --skip-skills                            Skip skills setup
    --skip-ui                                Skip Control UI/TUI prompts
    --synthetic-api-key <key>                Synthetic API key
    --tailscale <mode>                       Tailscale: off|serve|funnel
    --tailscale-reset-on-exit                Reset tailscale serve/funnel on exit
    --together-api-key <key>                 Together AI API key
    --token <token>                          Token value (non-interactive; used with --auth-choice token)
    --token-expires-in <duration>            Optional token expiry duration (e.g. 365d, 12h)
    --token-profile-id <id>                  Auth profile id (non-interactive; default: <provider>:manual)
    --token-provider <id>                    Token provider id (non-interactive; used with --auth-choice token)
    --venice-api-key <key>                   Venice API key
    --volcengine-api-key <key>               Volcano Engine API key
    --workspace <dir>                        Agent workspace directory (default: ~/.openclaw/workspace)
    --xai-api-key <key>                      xAI API key
    --xiaomi-api-key <key>                   Xiaomi API key
    --zai-api-key <key>                      Z.AI API key
  
  Docs: docs.openclaw.ai/cli/onboar
  ```

- 上游源码：`src/commands/onboard.ts`、`src/commands/onboard-non-interactive*.ts`、`src/wizard/setup.ts`
