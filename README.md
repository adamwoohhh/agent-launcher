# Safe Claude Code

如果你通过静态住宅 IP 代理访问 AI CLI，启动前最好先确认当前出口 IP，避免污染 IP 使用记录。

`safe-claude-code` 是一个极简启动器：它会探测本机安装的 `codex` 和 `claude`，让你选择要启动的 CLI，然后通过 [ipinfo.io](https://ipinfo.io) 获取当前出口 IP 信息。只有你确认后，它才会执行所选 CLI。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/adamwoohhh/safe-claude-code/main/install.sh | bash
```

安装到 `~/.local/bin/` 下，会创建两个命令：

- `safe-claude-code`（全名，主启动器）
- `scc`（短名，`safe-claude-code` 的符号链接）

如果 `~/.local/bin` 不在 PATH，安装器会提示你添加。

### 安装器的环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SCC_REPO` | `adamwoohhh/safe-claude-code` | 拉取的仓库（fork 时改这里）|
| `SCC_REF` | `main` | 分支/tag/commit SHA |
| `SCC_INSTALL_DIR` | `$HOME/.local/bin` | 安装目录 |

例如装到 `/usr/local/bin`：

```bash
curl -fsSL https://raw.githubusercontent.com/adamwoohhh/safe-claude-code/main/install.sh \
  | SCC_INSTALL_DIR=/usr/local/bin bash
```

## 使用前提

确保 `ipinfo.io` 和你要启动的 CLI 相关域名使用的是同一套代理规则。完整的代理教程可以参考 [Claude Code 安全使用指南](https://github.com/sakurs2/safe-claude?tab=readme-ov-file)。

```yaml
rules:
  - DOMAIN-KEYWORD,anthropic,纯净IP代理
  - DOMAIN-KEYWORD,claude,纯净IP代理
  - DOMAIN-KEYWORD,openai,纯净IP代理
  - DOMAIN-KEYWORD,ipinfo,纯净IP代理
  - DOMAIN-KEYWORD,github,机房代理
  - DOMAIN-KEYWORD,google,机房代理
```

## 用法

运行：

```bash
scc
```

如果本机同时安装了 `codex` 和 `claude`，会出现选择器：

```text
Select CLI to launch:

> codex      /usr/local/bin/codex
  claude     /usr/local/bin/claude

↑/↓ move, Enter select, q cancel
```

用方向键切换，回车确认，`q` 取消。

如果只安装了其中一个 CLI，`scc` 会自动选择它，然后继续展示 IP 信息。

选择 CLI 后，`scc` 会打印 ipinfo 返回结果，并要求你确认：

```text
IPinfo response:
{"ip":"1.2.3.4","city":"Beijing","country":"CN","timezone":"Asia/Shanghai"}

Continue and launch codex? [y/N]
```

只有输入 `y` 或 `yes` 才会启动；直接回车或其他输入都会取消。

参数会原样转发给最终 CLI：

```bash
scc --model gpt-5
```

如果你选择 `codex`，等价于：

```bash
codex --model gpt-5
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SCC_API` | `https://ipinfo.io` | 改成自建/代理的 IP 信息接口 |

## 失败时的行为

以下情况会拒绝启动：

1. 本机没有安装 `codex` 或 `claude`
2. 无法获取 `SCC_API` 的响应
3. 响应看起来不是 JSON
4. 用户取消 CLI 选择
5. 用户没有确认启动

失败时退出码为 `1`，不会启动目标 CLI。

## 依赖

- `bash` 3.2+（macOS 自带版本即可）
- `curl`
- 至少安装一个支持的 CLI：`codex` 或 `claude`

无需 `jq` 或其它工具。

## 开发

跑单元测试（纯 bash，无依赖，所有测试在临时目录里跑并 mock 掉 `curl` / `codex` / `claude`）：

```bash
./test.sh
```

## 升级 / 卸载

```bash
# 升级（重跑安装器即可）
curl -fsSL https://raw.githubusercontent.com/adamwoohhh/safe-claude-code/main/install.sh | bash

# 卸载
rm ~/.local/bin/safe-claude-code ~/.local/bin/scc
```
