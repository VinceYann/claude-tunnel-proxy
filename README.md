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
├── tunnel-daemon.sh      # macOS / Linux 后台常驻控制（start/stop/restart/status/probe/logs/watchdog）
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
./tunnel-daemon.sh status     # 查看状态（带各组件与问题描述）
./tunnel-daemon.sh restart    # 重启
./tunnel-daemon.sh stop       # 停止
./tunnel-daemon.sh probe      # 机器可读状态（key=value，给菜单栏用）
./tunnel-daemon.sh logs 50    # 看三份日志的末尾
./tunnel-daemon.sh watchdog start   # 开启看门狗（自动重连，常驻后台）
./tunnel-daemon.sh watchdog status  # 看门狗状态
./tunnel-daemon.sh watchdog stop    # 关闭看门狗
```

代理与隧道以后台进程运行，不占用终端。状态分四种，能一眼看出是"完全好了"还是"掉了一半"：

| `state` | 含义 | 判定 |
|---|---|---|
| `running` | **完全启动** | 本地代理 + SSH 隧道 都在运行 |
| `partial` | **部分启动** | 两个组件掉了一个，另一个还活着 |
| `fatal` | **致命错误** | 配置错误 / 启动失败，需要人工处理 |
| `stopped` | **静默** | 没有任何进程在运行 |

`partial` 和 `fatal` 的区别：前者是"曾经起来过、现在退化"（一键重启即可），后者是"根本没起来、或配置本身有问题"（`probe` 的 `reason` 会说明该改什么，比如端口被占用、SSH 认证失败、远端端口已被占用）。

启动不再是"睡两秒就宣布成功"：脚本会等到代理端口**确实由自己的进程**监听、并**通过 SSH 控制连接真的跑通一条远端命令**，才判定成功。

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

## 看门狗（自动重连）

隧道掉了不用管，看门狗自己修。这正是这个项目的痛点场景——**服务器三天两头抽风**：链路一断，SSH 隧道就没了，以前只能自己发现、自己重启。

**默认跟着隧道一起启停**：你 `start`（或双击 `start.command`、或在菜单里点"启动隧道"），看门狗跟着起来；
你 `stop`，它跟着停，不留后台进程。不需要单独去开，也不需要开机自启。

```bash
./tunnel-daemon.sh watchdog status   # 看状态
./tunnel-daemon.sh watchdog start    # 单独开（本次）
./tunnel-daemon.sh watchdog stop     # 单独关（本次）
./tunnel-daemon.sh watch             # 前台跑（看得见日志，调试用）
```

菜单栏应用里也有开关（**暂停自动重连（本次）/ 开启自动重连**），菜单里"自动重连"那行会显示它是否在跑。

**不想要看门狗**：在 `.env` 里写 `WATCHDOG="off"`，`start` 时就不会自动拉起它。

### 它会做什么

每 10 秒看一次状态，坏了自己修，而且**只修坏掉的那一半**：

| 情况 | 动作 |
|---|---|
| 代理没了、SSH 还好 | 只重启代理，**不动 SSH**（不打断已有连接） |
| SSH 没了、代理还好 | 只重建隧道，**不动代理** |
| 连修 3 次不行 | 整体 `stop` + `start`，清掉所有残留再来 |
| 配置有问题（没填 `.env`） | 不瞎撞，记日志等你去改；**改完自动生效**，不用重启看门狗 |
| 一直修不好 | 退避重试：2 → 4 → 8 → … → 最多 60 秒一次 |

**"SSH 进程活着"不等于"隧道活着"**——服务器网络抽风时进程往往还在那儿。所以每 20 秒做一次深检：用
`ssh -O check` 问一次控制连接还响不响应。这个命令**只走控制 socket，不会偷偷新建一条直连来报平安**
（普通 `ssh host true` 在 master 卡死时会自动回退成直连并返回成功，是个假信号）。连挂两次才动手，避免网络抖动来回拆建。

> 深检再快也有盲区：链路断了但 master 还"看上去正常"的窗口，交给 SSH 自己的保活
> （`ServerAliveInterval=20` × `ServerAliveCountMax=3`，约 60 秒内 ssh 自己退出），看门狗下一个心跳接手。
> 所以最坏情况的恢复时间是几十秒，而不是原来那种"不发现就一直坏着"。

### 和手动操作的关系

- **跟着隧道走**：看门狗由 `start` 拉起、`stop` 停掉，所以不会出现"你以为停了它还在折腾"。
- **有锁**：看门狗和你点菜单可能同时想操作隧道（比如你点"重新启动"时它正好在修），
  用 `.run/lock` 互斥，不会撞出两个代理或两条反向隧道。锁超过 3 分钟自动视为过期清理。
- **菜单里的"暂停自动重连（本次）"只在本轮生效**：下次启动隧道它会照旧跟着起来；
  想彻底关掉就改 `.env`。

> 顺带修掉一个老坑：`stop` 以前不等代理真正退出就返回，紧接着 `start` 会撞上
> `EADDRINUSE`（`restart` 尤其容易中）。现在杀掉进程后会等端口真的释放，`restart` 连做多次都稳。

日志在 `.run/watchdog.log`（超过 512KB 自动轮转），菜单里可以直接打开。

### 可调参数

用环境变量覆盖，例如慢一点的节奏：

```bash
WATCH_HEARTBEAT=30 WATCH_DEEP_EVERY=4 ./tunnel-daemon.sh watchdog start
```

| 变量 | 默认 | 含义 |
|---|---|---|
| `WATCH_HEARTBEAT` | 10 | 心跳间隔（秒） |
| `WATCH_DEEP_EVERY` | 2 | 每几次心跳做一次深检 |
| `WATCH_BACKOFF_BASE` | 2 | 修复失败后的首次退避（秒） |
| `WATCH_BACKOFF_MAX` | 60 | 退避上限（秒） |
| `CTL_TIMEOUT` | 5 | 控制连接探测超时（秒） |

> 看门狗是常驻进程，重启电脑就没了。想开机自启，用 launchd 拉起
> `./tunnel-daemon.sh watch`（`KeepAlive`）即可，不需要额外脚本。

## macOS 菜单栏应用

常驻状态栏的小前端，用颜色圆点显示隧道状态，点击即可启停。

| 圆点 | `state` | 状态 |
|---|---|---|
| ⚪ 白色（常亮） | `stopped` | 静默：没有任何进程在运行 |
| 🟢 绿色（常亮） | `running` | 完全启动：代理 + SSH 隧道 都在运行 |
| 🟠 橙色（闪烁） | `partial` | 部分启动：两个组件掉了一个 |
| 🔴 红色（闪烁） | `fatal` | 致命错误：配置错误 / 启动失败 |

闪烁表示"需要你注意"：缓慢闪烁（约 0.55 秒一次）用来把"部分启动"和"致命错误"从静态的绿/白里区分出来。

菜单顶部会直接写清楚是哪一种，以及**缺的是哪一个组件**，不用再去猜"部分启动"到底缺什么：

```
● 部分启动：SSH 隧道已断开
  本地代理    运行中 · PID 87518
  SSH 隧道    未运行
  远程主机    my-server  →  远端 1080
  代理地址    127.0.0.1:1080
```

菜单项：启动隧道 / 停止隧道 / 重新启动 / 暂停（开启）自动重连 / 打开代理日志 / 打开隧道日志 / 打开看门狗日志 / 打开项目目录 / 复制代理地址 / 退出（退出只关前端，隧道继续跑）。

### 构建

```bash
chmod +x menubar/build.sh
./menubar/build.sh
```

产物为项目根目录下的 `TunnelBar.app`。启动：`open TunnelBar.app`，或 Finder 双击。

> 首次打开若提示「无法验证开发者」，在「系统设置 → 隐私与安全性」中点「仍要打开」。

### 功能

- 每 3 秒自动刷新状态（启停期间加密到 0.7 秒，圆点很快跟上真实状态）
- 部分启动 / 致命错误时圆点闪烁；菜单开着时状态文字也会实时更新
- 悬停提示（tooltip）写出当前状态与细节
- 一键开关看门狗（自动重连），并显示它是在工作还是待命
- 纯菜单栏应用（`LSUIElement`），不占用 Dock

> 圆点是**自己画的彩色 NSImage**，不是 `systemSymbol` + `contentTintColor`。
> 状态栏会把 template 图像按菜单栏前景色重绘，`contentTintColor` 不生效——
> 那样圆点会永远是一个颜色（启动后图标不变就是这个原因），改回去请三思。

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
