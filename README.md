# Claude Tunnel Proxy

让远程（或本地）的 Claude Code 通过本地网络的代理访问 API 后端。核心场景：**远程服务器无法直接访问某 API（如 DeepSeek），但你的本地机器可以**。

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
├── proxy.py          # 核心：HTTP CONNECT 代理服务器
├── tunnel.bat        # Windows 一键启动脚本
├── tunnel.sh         # Linux / macOS 一键启动脚本
├── stop-all.bat      # Windows 停止脚本
├── stop-all.sh       # Linux / macOS 停止脚本
├── .env.example      # 配置文件模板
└── .gitignore
```

## 快速开始

### 1. 克隆项目

```bash
git clone https://github.com/yanjingshu/claude-tunnel-proxy.git
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

**Linux / macOS:**
```bash
chmod +x tunnel.sh stop-all.sh
./tunnel.sh
```

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
**Linux / macOS:** 运行 `./stop-all.sh`，或直接 `Ctrl+C` 终止 `tunnel.sh`（会自动清理）

## 适用场景

- 远程服务器在防火墙后，无法直接访问外部 API
- 需要通过本地网络出口访问特定地区限制的 API
- 使用第三方 Anthropic 兼容 API（如 DeepSeek、OpenRouter 等）
- 任何需要通过 SSH 隧道转发 HTTPS 流量的场景

## 依赖

- **Python 3** — 运行代理
- **SSH 客户端** — 建立隧道（Windows 自带 OpenSSH，Linux/macOS 自带）

## License

MIT
