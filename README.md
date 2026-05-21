# Safe Claude Code

启动 Claude Code 之前，先检查你的网络环境，避免污染 Claude Code 使用 IP 记录。

`safe-claude-code` 通过 [ipinfo.io](https://ipinfo.io) 拿到当前出口 IP 的地理信息，按你配置的规则做白名单校验，命中才启动 `claude`，否则打印完整 JSON 并退出。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/adamwoohhh/safe-claude-code/main/install.sh | bash
```

安装到 `~/.local/bin/` 下，同时建两个命令：

- `safe-claude-code`（全名）
- `scc`（短名，符号链接）

如果 `~/.local/bin` 不在 PATH，安装器会提示你加。

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

## 用法

把原本敲 `claude` 的地方换成 `scc`（或 `safe-claude-code`）即可，参数会原样转发给 `claude`。

### 规则语义

- 白名单：所有配置的字段都必须命中其允许的 pattern 列表才放行
- Pattern 支持 glob 通配符：`*`、`?`、`[...]`
- 大小写不敏感
- 多个 pattern 用逗号分隔，命中任意一个即可
- 未配置的字段不检查
- **未配置任何规则时拒绝启动**（避免裸跑）

### 通过环境变量配置

变量名格式：`SCC_<ipinfo字段名>=pattern1,pattern2,...`

```bash
# 只允许中国大陆或香港
SCC_country=CN,HK scc

# 时区必须是亚洲
SCC_timezone='Asia/*' scc

# 多字段同时校验
SCC_country=CN SCC_city='Beijing' scc
```

### 通过配置文件配置

默认路径：`~/.config/safe-claude-code/rules.conf`，可用 `SCC_CONFIG_FILE` 环境变量覆盖。

格式：每行 `field=patterns`，`#` 开头为注释，空行忽略。

```conf
# ~/.config/safe-claude-code/rules.conf
country=CN,HK
timezone=Asia/*
# city=Beijing,Shanghai,*Hong Kong*
```

环境变量优先于配置文件，方便临时覆盖。

### 可用字段

来自 ipinfo.io 响应的顶层字段：

- `ip` — 出口 IP
- `city` — 城市
- `region` — 省/州
- `country` — 国家代码（如 `CN`、`HK`、`US`）
- `loc` — 经纬度
- `org` — ISP/运营商（含 ASN）
- `postal` — 邮编
- `timezone` — 时区（如 `Asia/Shanghai`）

### 保留环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SCC_API` | `https://ipinfo.io` | 改成自建/代理的 IP 信息接口 |
| `SCC_CONFIG_FILE` | `~/.config/safe-claude-code/rules.conf` | 配置文件路径 |

## 失败时的行为

任一条件不满足都会：

1. 打印 `❌` + 错误原因（哪个字段、当前值、期望 pattern）到 stderr
2. 打印完整的 ipinfo.io JSON 到 stderr，方便排查
3. 退出码 `1`，不会启动 `claude`

## 依赖

- `bash` 3.2+（macOS 自带版本即可）
- `curl`

无需 `jq` 或其它工具。

## 升级 / 卸载

```bash
# 升级（重跑安装器即可）
curl -fsSL https://raw.githubusercontent.com/adamwoohhh/safe-claude-code/main/install.sh | bash

# 卸载
rm ~/.local/bin/safe-claude-code ~/.local/bin/scc
```
