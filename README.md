# Claude Tunnel Proxy

让远程服务器上的 Claude Code 通过本地网络访问外部 API。核心场景：**服务器三天两头抽风连不上外网，但你的本地机器可以正常访问**。

## 为什么需要这个项目

有一台远程 Linux 服务器，经常间歇性断网——外网 API 时而能连时而连不上。但本地 Windows 机器网络稳定，能正常访问 DeepSeek、GitHub 等服务。于是有了这个方案：

- 在本地 Windows 上跑一个轻量 HTTP CONNECT 代理
- 通过 SSH 反向隧道把远程端口映射到本地代理
- 远程 Claude Code 的 API 请求经隧道走本地网络出去

这样一来，即使服务器本身连不上外部 API，只要 SSH 隧道通畅，Claude Code 就能正常工作。同时也能用于其他需要走代理的场景（git push、curl 等）。

## 工作原理

```
远程/本地 Claude Code
        │
        │  HTTP_PROXY=http://127.0.0.1:1080
        ▼
  SSH 反向隧道
        │
        ▼
  本地 proxy.py (HTTP CONNECT 代理 :1080)
        │
        ▼
   目标 API (api.deepseek.com, etc.)
```

1. **proxy.py** — 一个轻量级 HTTP CONNECT 代理，只做 HTTPS 隧道转发  
2. **SSH 反向隧道** — 将远程端口映射到本地代理  
3. Claude Code 通过 `HTTP_PROXY` 环境变量指向代理，所有 API 请求走隧道出去

## 项目结构

```
├── proxy.py              # 核心：HTTP CONNECT 代理服务器
├── tunnel.bat            # Windows 一键启动脚本
├── tunnel.sh             # Linux / macOS 前台启动脚本
├── stop-all.bat          # Windows 停止脚本
├── stop-all.sh           # Linux / macOS 停止脚本
├── tunnel-daemon.sh      # macOS / Linux 后台控制（start/stop/restart/status）
├── start.command         # macOS 一键启动（Finder 双击运行）
├── menubar/              # macOS 菜单栏应用
│   ├── TunnelBar.swift   #   应用源码（Swift）
│   └── build.sh          #   编译打包脚本
├── .env.example          # 配置文件模板
└── .gitignore
```

## 快速开始

### 1. 克隆项目

```bash
git clone https://github.com/VinceYann/claude-tunnel-proxy.git
cd claude-tunnel-proxy
```

### 2. 配置

```bash
cp .env.example .env
```

编辑 `.env`，填写你的 SSH 远程主机：

```env
SSH_HOST="your-server-alias"   # 你的 SSH 远程服务器别名或 user@host
PROXY_HOST="127.0.0.1"         # 通常不需要改
PROXY_PORT="1080"              # 通常不需要改
REMOTE_PORT="1080"             # 远程端口，默认与 PROXY_PORT 相同
```

### 3. 启动

**Windows:**
```bat
tunnel.bat
```

**macOS / Linux（前台运行）:**
```bash
chmod +x tunnel.sh stop-all.sh
./tunnel.sh
```

> 前台模式下隧道随终端会话存活，`Ctrl+C` 或关闭终端即停止。

**macOS / Linux（后台常驻，推荐）:**

```bash
./tunnel-daemon.sh start      # 启动，代理与隧道常驻后台
./tunnel-daemon.sh status     # 查看状态
./tunnel-daemon.sh restart    # 重启
./tunnel-daemon.sh stop       # 停止
```

代理与隧道以后台进程运行，不占用终端。状态区分 **运行中 / 部分运行 / 已停止**，可识别残留的半开进程。

**macOS 免终端启动:**

| 方式 | 操作 |
|---|---|
| 一键启动 | Finder 中双击 `start.command` |
| 菜单栏控制 | 双击 `TunnelBar.app`，见下方「macOS 菜单栏应用」 |

> **macOS 需要先装 Python 3**（见下方「依赖」）。SSH 客户端系统自带。

### 4. 在远程服务器上配置 Claude Code

在远程服务器的 `~/.bashrc` 或 Claude Code 配置中设置：

```bash
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
export ANTHROPIC_AUTH_TOKEN="sk-your-deepseek-api-key"
export ANTHROPIC_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
export HTTP_PROXY="http://127.0.0.1:1080"
export HTTPS_PROXY="http://127.0.0.1:1080"
export NO_PROXY="localhost,127.0.0.1"
```

### 5. 停止

**Windows:** 运行 `stop-all.bat`

**Linux / macOS:**
- 后台模式：`./tunnel-daemon.sh stop`
- 前台模式：`Ctrl+C` 终止 `tunnel.sh`（会自动清理）
- 兜底清理残留代理：`./stop-all.sh`

## macOS 菜单栏应用

常驻状态栏的小前端，用颜色圆点显示隧道状态，点击即可启停。

| 圆点 | 状态 |
|---|---|
| 🟢 绿色 | 运行中 |
| 🟠 橙色 | 部分运行（代理或隧道掉了一个） |
| ⚪ 灰色 | 已停止 |

### 构建

```bash
chmod +x menubar/build.sh
./menubar/build.sh
```

产物为项目根目录下的 `TunnelBar.app`。启动：`open TunnelBar.app`，或 Finder 双击。

> 首次打开若提示「无法验证开发者」，在「系统设置 → 隐私与安全性」中点「仍要打开」。

### 功能

- 每 5 秒自动刷新状态圆点
- 点击圆点弹出菜单：启动隧道 / 停止隧道 / 打开项目目录 / 退出
- 纯菜单栏应用（`LSUIElement`），不占用 Dock

### 构建依赖

需要 `swiftc`，由 Xcode 命令行工具提供（多数 macOS 已安装）：

```bash
xcode-select --install
```

界面与逻辑分离：菜单栏应用只是 `tunnel-daemon.sh` 的图形外壳，所有启停与状态判断都走同一个脚本，不存在两套逻辑。

## 适用场景

- 远程服务器在防火墙后，无法直接访问外部 API
- 需要通过本地网络出口访问特定地区限制的 API
- 使用第三方 Anthropic 兼容 API（如 DeepSeek、OpenRouter 等）
- 任何需要通过 SSH 隧道转发 HTTPS 流量的场景

## 依赖

- **Python 3** — 运行代理
- **SSH 客户端** — 建立隧道

各平台说明：

| 平台 | Python 3 | SSH |
|---|---|---|
| Windows | 从 [python.org](https://python.org) 安装，或 `winget install Python.Python.3` | 自带 OpenSSH（Win10 1809+） |
| macOS | 未预装，需手动安装 | 自带 |
| Linux | 多数发行版自带 | 自带 |

**macOS 安装 Python 3（二选一）：**

```bash
# 方式一：Xcode 命令行工具（自带 python3）
xcode-select --install

# 方式二：Homebrew
brew install python3
```

## License

MIT
