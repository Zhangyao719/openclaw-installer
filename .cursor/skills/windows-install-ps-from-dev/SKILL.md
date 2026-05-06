---
name: windows-install-ps-from-dev
description: Copies windows/install-user-dev.ps1 to windows/install-user.ps1 and strips every comment from the copy. Use when syncing or regenerating the release windows/install-user.ps1 from the dev script, or when the user asks to publish install-user.ps1 without comments.
disable-model-invocation: true
---

# windows/install-user.ps1 从 dev 生成

## 用户定义的任务（原文）

专门把 `windows/install-user-dev.ps1` 文件拷贝一份到 `windows/` 目录下，并将这份 `windows/install-user.ps1` 内的所有注释全部删除。

## 执行步骤

1. 将 `windows/install-user-dev.ps1` 复制为同目录下的 `windows/install-user.ps1`（覆盖已存在文件）。
2. 仅编辑目标文件 `windows/install-user.ps1`，删除其中**全部**注释；不得改动 `install-user-dev.ps1`。

## PowerShell 注释范围

- 块注释：`<#` … `#>`（可跨行）。
- 行注释：从 `#` 起到行尾；不得删除出现在字符串字面量（含单引号、双引号、here-string）内的 `#` 及其后内容。

## 验证

- `windows/install-user.ps1` 存在且内容来自当前 `install-user-dev.ps1`（无注释后语义保留）。
- 文件中不含 `#` 起始的独立注释行、不含 `<#`/`#>` 块（字符串内除外）。
