# Agent Launcher

一个面向 AI CLI 的会话启动器，用来在启动前选择 CLI、临时启停全局能力，并把参数原样转发给目标工具。

`Agent Launcher` 会探测本机安装的 Agent CLI，让你选择要启动的 CLI，并在启动前选择本次会话启用哪些全局 skills / plugins / MCP servers。确认后，它会执行所选 CLI，并保留原本的命令行参数。

| Agent CLI | Support |
| --------- | ------- |
| Codex CLI | ✅ |
| Claude Code | ✅ |
| Pi Code Agent | 👷... |


## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/adamwoohhh/safe-claude-code/main/install.sh | bash
```

安装到 `~/.local/bin/` 下，会创建两个命令：

- `agent-launch`（全名）
- `al`（短名，推荐日常使用）

如果 `~/.local/bin` 不在 PATH，安装器会提示你添加。

## 适用场景

- 全局安装了很多 skills / plugins / MCP servers，希望按会话临时启停。
- CLI 运行依赖特殊的网络环境，在启动前检查代理是否配置正确。

## 用法

运行：

```bash
al
```

如果本机同时安装了多个 Agent CLI，会出现选择器：

```text
Select CLI to launch:

> codex      /usr/local/bin/codex
  claude     /usr/local/bin/claude

↑/↓ move, Enter select, q cancel
```

用方向键切换，回车确认，`q` 取消。

如果只安装了其中一个 CLI，`al` 会自动选择它。

选择 CLI 后，如果发现可控的全局能力，会出现第二个选择器，默认全部启用：

```text
Select features to enable:

  [x] lark (2)
>   [x] skill   lark-approval
    [x] skill   lark-apps
  [x] plugin (1)
    [x] plugin  browser@openai-bundled
  [x] mcp (1)
    [x] mcp     node_repl

↑/↓ move/scroll, ←/→ collapse/expand, Space toggle item, g toggle group, Enter continue, a toggle all, q cancel
```

用上下方向键移动，左右方向键折叠或展开当前分组，空格反选单项，`g` 切换当前项所在分组，回车继续，`a` 全选/全不选，`q` 取消。超过 5 项的分组会默认折叠。selector 固定最多展示 20 行，超出的内容用方向键滚动查看。

skill 会从通用目录和当前 CLI 专属目录读取：

- 通用：`~/.agents/skills`
- Codex：`~/.codex/skills`
- Claude Code：`~/.claude/skills`

Claude Code 的 plugins 会从 `~/.claude/plugins/marketplaces/<marketplace>/{plugins,external_plugins}/<plugin>/.claude-plugin/plugin.json` 读取，并展示为 `marketplace:plugin`。

如果 skill 目录是软链，`al` 会解析到真实目录，并用真实的 `SKILL.md` 路径生成禁用配置，避免漏读软链安装的 skill。对于 `~/.agents/skills/superpowers -> ~/.codex/superpowers/skills` 这种 bundle 目录，`al` 会继续读取下一层的 `*/SKILL.md`，展示为 `superpowers:brainstorming`、`superpowers:systematic-debugging` 这类名称，并归入 `superpowers` 分组。

相同前缀的 skill 会分到同一组，例如 `lark-approval`、`lark-apps` 会进入 `lark` 分组；如果同时存在 `understand` 和 `understand-chat`，两者也会进入 `understand` 分组。

### Codex 的禁用方式

选择 `codex` 时，反选的 skills / plugins / MCP servers 会转成启动参数：

```bash
codex -c 'skills.config=[{path="/absolute/path/to/skill/SKILL.md",enabled=false}]' \
      -c 'plugins."browser@openai-bundled".enabled=false' \
      -c 'mcp_servers.node_repl.enabled=false'
```

Codex CLI 不能通过 `-c 'skills."name".enabled=false'` 禁用单个 skill；需要使用 `skills.config` 并指向 `SKILL.md` 文件本身。多个反选 skill 会合并成一个 `skills.config=[...]` 数组。

### Claude Code 的禁用方式

Claude Code 没有单独禁用某个 skill 或 plugin 的 `-c` 参数；它的 `-c` 是 `--continue`。因此当你选择 `claude` 且反选了 skill 或 plugin 时，`al` 会把本次选择转成 Claude Code 原生的 `--settings` 参数：

```bash
claude --settings '{"skillOverrides":{"alpha":"off"},"enabledPlugins":{"plugin-alpha@official":false}}'
```

反选普通 skill 时写入 `skillOverrides`，值为 `"off"`；反选 plugin 时写入 `enabledPlugins`，值为 `false`。Claude Code 的 plugin key 使用 `plugin@marketplace` 格式，因此 selector 中展示的 `official:plugin-alpha` 会转换成 `plugin-alpha@official`。

这种方式不会创建临时配置目录，不会设置 `CLAUDE_CONFIG_DIR`，也不会改写项目里的 `.claude` 或用户全局的 `~/.claude` / `~/.claude.json`。登录态、缓存和 Claude Code 自己的项目状态都保持由 Claude Code 原本的配置加载逻辑处理；`al` 只是在本次启动命令前追加一次性的 `--settings` 覆盖参数。

## 确认网络

完成 CLI 和能力选择后，`al` 会展示一次启动前检查结果，并要求你确认：

```text
IPinfo response:
{"ip":"1.2.3.4","city":"Beijing","country":"CN","timezone":"Asia/Shanghai"}

Continue and launch codex? [Y/n]
```

直接回车或输入 `y` / `yes` 会启动；输入 `n` / `no` 或其他内容会取消。

如果你在代理环境下使用 AI CLI，可以让启动前检查接口和目标 CLI 使用同一套代理规则。代理配置可参考 [Claude Code 安全使用指南](https://github.com/sakurs2/safe-claude?tab=readme-ov-file)。

参数会原样转发给最终 CLI：

```bash
al --model gpt-5
```

如果你选择 `codex`，等价于：

```bash
codex --model gpt-5
```

调试启动参数时可以设置 `AL_DEBUG=1`：

```bash
AL_DEBUG=1 al --model gpt-5
```

存在 `AL_DEBUG` 且值不是 `0`、`false`、`no` 或 `off` 时，`al` 会在启动目标 CLI 前向 stderr 打印完整命令，例如 `Launch command: codex ...` 或 `Launch command: claude ...`。调试模式不占用目标 CLI 的命令行参数；如果你传入 `--debug`，它会被当作普通参数原样转发给最终的 Codex CLI 或 Claude Code。

## 失败时的行为

以下情况会拒绝启动：

1. 本机没有安装 `codex` 或 `claude`
2. 无法获取启动前检查接口的响应
3. 响应看起来不是 JSON
4. 用户取消 CLI 选择
5. 用户取消能力选择
6. 用户没有确认启动

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
rm ~/.local/bin/agent-launch ~/.local/bin/al
```
