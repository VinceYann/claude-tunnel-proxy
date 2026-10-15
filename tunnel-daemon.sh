#!/usr/bin/env bash
# ============================================================
#  Claude Tunnel Proxy — 后台守护控制脚本
#  --------------------------------------------
#  把代理 + SSH 反向隧道放到后台常驻，不占用终端。
#  用法: ./tunnel-daemon.sh {start|stop|restart|status}
#
#  一键启动（Finder 双击）请用 start.command
#  菜单栏控制请用 TunnelBar.app
# ============================================================

set -euo pipefail
cd "$(dirname "$0")"

RUN_DIR=".run"
mkdir -p "$RUN_DIR"

# ---- Load .env ----
if [[ ! -f .env ]]; then
    echo "[ERROR] .env 不存在。请先 cp .env.example .env 并填写 SSH_HOST。"
    exit 1
fi
set -a
source .env
set +a

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-1080}"
REMOTE_PORT="${REMOTE_PORT:-$PROXY_PORT}"

# ---- 判断运行状态: running / partial / stopped ----
is_running() {
    local proxy_pid="" ssh_pid="" proxy_alive=0 ssh_alive=0
    [[ -f "$RUN_DIR/proxy.pid" ]] && proxy_pid="$(cat "$RUN_DIR/proxy.pid")"
    [[ -f "$RUN_DIR/ssh.pid" ]]   && ssh_pid="$(cat "$RUN_DIR/ssh.pid")"
    [[ -n "$proxy_pid" ]] && kill -0 "$proxy_pid" 2>/dev/null && proxy_alive=1
    [[ -n "$ssh_pid" ]]   && kill -0 "$ssh_pid"   2>/dev/null && ssh_alive=1

    if [[ $proxy_alive -eq 1 && $ssh_alive -eq 1 ]]; then
        echo "running"
    elif [[ $proxy_alive -eq 1 || $ssh_alive -eq 1 ]]; then
        echo "partial"
    else
        echo "stopped"
    fi
}

# ---- 启动 ----
start() {
    local state
    state="$(is_running)"
    if [[ "$state" == "running" ]]; then
        echo "[INFO] 隧道已在运行。"
        status
        return 0
    fi

    # 清理可能的残留（半开状态）
    if [[ "$state" == "partial" ]]; then
        echo "[WARN] 检测到残留进程，先清理…"
        stop >/dev/null 2>&1 || true
        sleep 1
    fi

    echo "[1/2] 启动本地代理 (${PROXY_HOST}:${PROXY_PORT})…"
    python3 proxy.py > "$RUN_DIR/proxy.log" 2>&1 &
    echo $! > "$RUN_DIR/proxy.pid"
    sleep 2

    echo "[2/2] 建立 SSH 反向隧道 (${SSH_HOST}:${REMOTE_PORT} <- 127.0.0.1:${PROXY_PORT})…"
    ssh -N </dev/null \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -R "${REMOTE_PORT}:127.0.0.1:${PROXY_PORT}" \
        "${SSH_HOST}" > "$RUN_DIR/tunnel.log" 2>&1 &
    echo $! > "$RUN_DIR/ssh.pid"
    sleep 2

    if [[ "$(is_running)" == "running" ]]; then
        echo "[OK] 隧道已启动并常驻后台。"
        status
        return 0
    fi

    echo "[ERROR] 隧道启动失败。tunnel.log 末尾："
    tail -5 "$RUN_DIR/tunnel.log" 2>/dev/null || true
    stop >/dev/null 2>&1 || true
    return 1
}

# ---- 停止 ----
stop() {
    local stopped=0 pid=""

    for f in ssh.pid proxy.pid; do
        if [[ -f "$RUN_DIR/$f" ]]; then
            pid="$(cat "$RUN_DIR/$f")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null && echo "[OK] 停止 PID $pid ($f)"
                stopped=1
            fi
            rm -f "$RUN_DIR/$f"
        fi
    done

    # 兜底：清理任何残留的代理进程（防 PID 文件丢失）
    pkill -f "python.*proxy.py" 2>/dev/null || true

    if [[ $stopped -eq 0 ]]; then
        echo "[INFO] 没有运行中的隧道 / 代理。"
    fi
}

# ---- 状态 ----
status() {
    local state
    state="$(is_running)"

    case "$state" in
        running) echo "状态: 运行中 ✅" ;;
        partial) echo "状态: 部分运行 ⚠️" ;;
        stopped) echo "状态: 已停止 ⭕" ;;
    esac

    if [[ -f "$RUN_DIR/proxy.pid" ]]; then echo "  代理 PID : $(cat "$RUN_DIR/proxy.pid")"; fi
    if [[ -f "$RUN_DIR/ssh.pid" ]];   then echo "  隧道 PID : $(cat "$RUN_DIR/ssh.pid")"; fi
    echo "  远程主机 : ${SSH_HOST}"
    echo "  代理地址 : ${PROXY_HOST}:${PROXY_PORT} (remote ${REMOTE_PORT})"

    [[ "$state" == "running" ]]
}

# ---- 入口 ----
case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    state)   is_running ;;   # 输出纯状态词 running/partial/stopped（供程序调用）
    *)
        echo "用法: $0 {start|stop|restart|status|state}"
        exit 2
        ;;
esac
