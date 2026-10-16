#!/usr/bin/env bash
# ============================================================
#  Claude Tunnel Proxy — 后台守护控制脚本
#  --------------------------------------------
#  把代理 + SSH 反向隧道放到后台常驻，不占用终端。
#
#  用法: ./tunnel-daemon.sh {start|stop|restart|status|state|probe|logs}
#        ./tunnel-daemon.sh watch                          # 前台跑看门狗
#        ./tunnel-daemon.sh watchdog {start|stop|restart|status}
#
#  状态语义（菜单栏圆点颜色与之一一对应）：
#    running  完全启动   代理 + SSH 隧道 都在运行              🟢 绿（常亮）
#    partial  部分启动   两个组件掉了一个，另一个还在跑        🟠 橙（闪烁）
#    fatal    致命错误   配置错误 / 启动失败，需要人工处理     🔴 红（闪烁）
#    stopped  静默       没有任何进程在运行                    ⚪ 白（常亮）
#
#  看门狗（watchdog）：跟着隧道一起启停
#    start 时自动拉起，stop 时自动停掉；.env 里写 WATCHDOG="off" 可关掉这个行为。
#    （用 `watchdog stop` 关掉只是本次会话；想彻底不要，就改 .env）
#    每 WATCH_HEARTBEAT 秒查一次，坏了自己修：
#      · 代理没了  → 只把代理拉起来（不动 SSH）
#      · SSH 没了  → 只重建隧道（不动代理）
#      · 连续修不好 → 整体 stop + start
#      · 修不动（比如 .env 没填）→ 退避重试，改好 .env 会自动生效
#    深检：SSH 进程活着不等于隧道活着（服务器网络抽风时进程往往还在）。
#    每 WATCH_DEEP_EVERY 次心跳用 `ssh -O check` 问一次控制连接还响不响应
#    （只走控制 socket，不会像普通 ssh 命令那样偷偷新建一条直连来"报平安"）。
#    连挂两次才动手，避免网络抖动来回拆建。
# ============================================================

set -euo pipefail
cd "$(dirname "$0")"
SELF_DIR="$(pwd)"
SELF="$SELF_DIR/tunnel-daemon.sh"

RUN_DIR="$SELF_DIR/.run"
mkdir -p "$RUN_DIR"

FATAL_FILE="$RUN_DIR/fatal"
PROXY_LOG="$RUN_DIR/proxy.log"
TUNNEL_LOG="$RUN_DIR/tunnel.log"
WATCH_LOG="$RUN_DIR/watchdog.log"
PROXY_PID_FILE="$RUN_DIR/proxy.pid"
SSH_PID_FILE="$RUN_DIR/ssh.pid"
WATCH_PID_FILE="$RUN_DIR/watchdog.pid"
LOCK_DIR="$RUN_DIR/lock"
CTL_SOCKET="$RUN_DIR/ssh-ctl"

# ---- 看门狗节奏（可用环境变量覆盖，方便慢机器 / 调试）----
export WATCH_HEARTBEAT="${WATCH_HEARTBEAT:-10}"          # 心跳间隔（秒）
export WATCH_DEEP_EVERY="${WATCH_DEEP_EVERY:-2}"         # 每几次心跳做一次深检
export WATCH_BACKOFF_BASE="${WATCH_BACKOFF_BASE:-2}"     # 修复失败后的首次退避
export WATCH_BACKOFF_MAX="${WATCH_BACKOFF_MAX:-60}"      # 退避上限
CTL_TIMEOUT="${CTL_TIMEOUT:-5}"                          # 控制连接探测超时（秒）

# ---- 运行时全局 ----
STATE="stopped"
PROXY_UP=0
SSH_UP=0
PROXY_PID=""
SSH_PID=""
LOCK_HELD=0
DEEP_FAILS=0
WATCH_STOPPING=0
IN_WATCH=0

# 交互式/看门狗两种场景下都能用的输出（看门狗带时间戳）
nlog() {
    if [[ $IN_WATCH -eq 1 ]]; then
        printf '[%s] %s\n' "$(date '+%F %T')" "$*"
    else
        printf '%s\n' "$*"
    fi
}

# ---- 加载 .env ----
# 缺失或残缺不直接退出：交给状态判断处理，这样菜单栏能显示成「致命错误」（红）。
# 让看门狗能反复调用，所以做成函数：用户改好 .env 后不用重启看门狗。
load_env() {
    CONFIG_ERROR=""
    if [[ ! -f "$SELF_DIR/.env" ]]; then
        CONFIG_ERROR="缺少 .env（请先 cp .env.example .env 并填写 SSH_HOST）"
    else
        set -a
        if ! source "$SELF_DIR/.env"; then
            CONFIG_ERROR=".env 解析失败（检查引号与语法）"
        fi
        set +a
    fi

    PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
    PROXY_PORT="${PROXY_PORT:-1080}"
    REMOTE_PORT="${REMOTE_PORT:-$PROXY_PORT}"
    WATCHDOG="${WATCHDOG:-on}"        # off = 隧道启动时不自动开看门狗
    SSH_HOST="${SSH_HOST:-}"
    SSH_MARKER="-R ${REMOTE_PORT}:127.0.0.1:${PROXY_PORT}"

    if [[ -z "$CONFIG_ERROR" && ( -z "$SSH_HOST" || "$SSH_HOST" == "your-server-alias" ) ]]; then
        CONFIG_ERROR=".env 中的 SSH_HOST 还没填（当前：'${SSH_HOST}'）"
    fi
}

# ---- 小工具 ----
one_line() { printf '%s' "${1//$'\n'/ }"; }

# 进程是否存活，且确实是我们启动的那个（防 PID 复用认错进程）
alive() {
    local pid="$1" marker="$2" cmd
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    [[ "$cmd" == *"$marker"* ]]
}

pid_in() { [[ -f "$1" ]] && tr -d '[:space:]' < "$1" || true; }

proxy_alive() { alive "$(pid_in "$PROXY_PID_FILE")" "proxy.py"; }

# 本地代理端口是否可连（仅对回环地址检查，避免误连远端主机时卡住）
port_open() {
    case "$PROXY_HOST" in
        127.0.0.1|localhost|::1) ;;
        *) return 0 ;;
    esac
    (exec 3<>/dev/tcp/"$PROXY_HOST"/"$PROXY_PORT") 2>/dev/null
}

# 端口是不是「我们自己的」代理在监听。
# 只看端口通不通会被别人的进程骗过（端口被占用时 start 会误判成功）。
proxy_port_owned() {
    local pid="$1"
    [[ -n "$pid" ]] || return 1
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN -t 2>/dev/null | grep -qx "$pid"
    else
        port_open
    fi
}

# 等端口真正释放。
# SIGTERM 是异步的：旧代理收到信号后还要几十毫秒才退出，
# 这段时间里新代理 bind 会直接 EADDRINUSE 死掉 —— 快速 stop→start（restart、
# 看门狗的整体重启）就踩这个坑，报出"端口被占用"的还偏偏是自己刚杀的那个进程。
wait_port_released() {
    local secs="$1" i
    local ticks=$((secs * 4))
    for ((i = 0; i < ticks; i++)); do
        port_open || return 0
        sleep 0.25
    done
    return 1
}

# 占着端口的是谁（用于给出人话的报错）
port_occupant() {
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true
}

# 给命令加超时。macOS 没有 timeout(1)；而 ssh 的控制连接命令在 master 卡住时
# 会一直等下去（实测 >120s 不返回），所以必须自己兜住。
run_with_timeout() {
    local secs="$1"
    shift
    "$@" &
    local pid=$! i rc=0
    local ticks=$((secs * 4))
    for ((i = 0; i < ticks; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || rc=$?
            return $rc
        fi
        if [[ $WATCH_STOPPING -eq 1 ]]; then     # 要停了，别为了一次探测死等
            kill -9 "$pid" 2>/dev/null || true
            pkill -9 -P "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.25
    done
    kill -9 "$pid" 2>/dev/null || true
    pkill -9 -P "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
}

# 隧道/控制连接还活着吗。
# 用 -O check：它只走控制 socket，不会偷偷新建一条直连。
# （普通 `ssh host true` 在 master 卡死时会自动回退成直连，返回 0 —— 会造成假报警"隧道正常"。）
master_ok() {
    [[ -S "$CTL_SOCKET" ]] || return 1
    run_with_timeout "$CTL_TIMEOUT" ssh -O check \
        -o ControlPath="$CTL_SOCKET" -o BatchMode=yes "$SSH_HOST" >/dev/null 2>&1
}

# 睡得着也起得来：收到退出信号就立刻返回。
# 直接用 sleep 10 的话，TERM 要等这个 sleep 跑完才处理，看门狗停止会拖到十几秒。
wsleep() {
    local secs="$1" i
    local ticks=$((secs * 4))
    for ((i = 0; i < ticks; i++)); do
        [[ $WATCH_STOPPING -eq 1 ]] && return 0
        sleep 0.25
    done
}

fatal_reason() { [[ -f "$FATAL_FILE" ]] && one_line "$(head -n1 "$FATAL_FILE")" || true; }
set_fatal()    { printf '%s\n' "$1" > "$FATAL_FILE"; }
clear_fatal()  { rm -f "$FATAL_FILE"; }

# ---- 互斥锁 ----
# 看门狗和"人手点菜单"可能同时想操作隧道；没有锁的话会互相打架，
# 撞出两个代理 / 两个反向隧道。用 mkdir 做原子锁。
acquire_lock() {
    [[ $LOCK_HELD -eq 1 ]] && return 0
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        # 崩溃残留：超过 3 分钟没人管就当过期锁清掉
        if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +3 2>/dev/null)" ]]; then
            nlog "[WARN] 清理超时的锁（上次操作可能是被强杀的）"
            rm -rf "$LOCK_DIR"
            continue
        fi
        sleep 0.5
        waited=$((waited + 1))
        if (( waited > 240 )); then
            nlog "[ERROR] 等锁超时，放弃本次操作"
            return 1
        fi
    done
    echo $$ > "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
}

release_lock() {
    [[ $LOCK_HELD -eq 1 ]] || return 0
    rm -rf "$LOCK_DIR"
    LOCK_HELD=0
}

with_lock() {
    acquire_lock || return 1
    local rc=0
    "$@" || rc=$?
    release_lock
    return $rc
}

cleanup_on_exit() { [[ $LOCK_HELD -eq 1 ]] && rm -rf "$LOCK_DIR" || true; }
trap 'cleanup_on_exit' EXIT

# ---- 判断运行状态: running / partial / fatal / stopped ----
compute_state() {
    PROXY_PID="$(pid_in "$PROXY_PID_FILE")"
    SSH_PID="$(pid_in "$SSH_PID_FILE")"
    PROXY_UP=0
    SSH_UP=0
    proxy_alive && PROXY_UP=1 || true
    alive "$SSH_PID" "$SSH_MARKER" && SSH_UP=1 || true

    # 代理进程活着但端口不监听 = 代理已经病态，视同掉线
    if [[ $PROXY_UP -eq 1 ]] && ! port_open; then
        PROXY_UP=0
    fi

    if [[ $PROXY_UP -eq 1 && $SSH_UP -eq 1 ]]; then
        STATE="running"
    elif [[ $PROXY_UP -eq 1 || $SSH_UP -eq 1 ]]; then
        STATE="partial"
    elif [[ -n "$CONFIG_ERROR" || -f "$FATAL_FILE" ]]; then
        STATE="fatal"
    else
        STATE="stopped"
    fi
}

# SSH 起不来的原因（从 tunnel.log 里认出来，给人话而不是日志）
explain_ssh_failure() {
    local log="$1"
    if grep -qi "remote port forwarding failed" "$log" 2>/dev/null; then
        echo "远端 ${REMOTE_PORT} 端口已被占用，sshd 拒绝转发"
    elif grep -qi "permission denied" "$log" 2>/dev/null; then
        echo "SSH 认证失败：免密登录不可用（后台运行无法输入密码）"
    elif grep -qi "host key verification failed" "$log" 2>/dev/null; then
        echo "主机密钥校验失败：请先在终端手动 ssh ${SSH_HOST} 确认一次指纹"
    elif grep -qi "could not resolve hostname" "$log" 2>/dev/null; then
        echo "无法解析主机名 ${SSH_HOST}"
    elif grep -qi "connection timed out\|operation timed out" "$log" 2>/dev/null; then
        echo "连接 ${SSH_HOST} 超时（网络或防火墙）"
    elif grep -qi "connection refused" "$log" 2>/dev/null; then
        echo "连接 ${SSH_HOST} 被拒绝（sshd 未运行或端口不对）"
    else
        echo "SSH 隧道建立失败（详见 .run/tunnel.log）"
    fi
}

# ---- 起两个组件（拆开是为了看门狗能只修坏掉的那一个）----
start_proxy() {
    # 端口还被自己的旧代理占着（正在退出中）就先等一等；
    # 被别人的进程占着则不等，直接走下面的报错路径，把占用者告诉用户。
    if port_open; then
        local occ
        occ="$(port_occupant)"
        if [[ -n "$occ" ]] && ps -o command= -p "$occ" 2>/dev/null | grep -q "$SELF_DIR/proxy.py"; then
            nlog "[WARN] 上一个代理还在退出，等它释放端口 ${PROXY_PORT}…"
            wait_port_released 5 || true
        fi
    fi

    nlog "[1/3] 启动本地代理 (${PROXY_HOST}:${PROXY_PORT})…"
    : > "$PROXY_LOG" 2>/dev/null || true
    # 用绝对路径启动：命令行里带完整路径，清理时不会误伤别人的 proxy.py
    nohup python3 "$SELF_DIR/proxy.py" > "$PROXY_LOG" 2>&1 &
    echo $! > "$PROXY_PID_FILE"
    disown 2>/dev/null || true    # 之后 kill 它时别在终端刷 "Terminated"

    local i ok=0
    for ((i = 0; i < 50; i++)); do
        if ! proxy_alive; then break; fi
        if proxy_port_owned "$(pid_in "$PROXY_PID_FILE")"; then ok=1; break; fi
        sleep 0.2
    done
    if [[ $ok -eq 1 ]]; then return 0; fi

    local occupant
    occupant="$(port_occupant)"
    if [[ -n "$occupant" ]]; then
        nlog "[ERROR] 端口 ${PROXY_PORT} 已被其他进程占用（PID ${occupant}）："
        ps -o command= -p "$occupant" 2>/dev/null | sed 's/^/        /' || true
        kill_local_proxy
        set_fatal "端口 ${PROXY_PORT} 已被 PID ${occupant} 占用"
    else
        nlog "[ERROR] 代理未能在 ${PROXY_HOST}:${PROXY_PORT} 上监听。proxy.log 末尾："
        tail -5 "$PROXY_LOG" 2>/dev/null || true
        kill_local_proxy
        set_fatal "本地代理启动失败（端口 ${PROXY_PORT}）"
    fi
    return 1
}

start_ssh() {
    nlog "[2/3] 建立 SSH 反向隧道 (${SSH_HOST}:${REMOTE_PORT} <- 127.0.0.1:${PROXY_PORT})…"
    rm -f "$CTL_SOCKET"
    : > "$TUNNEL_LOG" 2>/dev/null || true
    nohup ssh -N </dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=20 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o ControlMaster=yes \
        -o ControlPath="$CTL_SOCKET" \
        -R "${REMOTE_PORT}:127.0.0.1:${PROXY_PORT}" \
        "${SSH_HOST}" >> "$TUNNEL_LOG" 2>&1 &
    echo $! > "$SSH_PID_FILE"
    disown 2>/dev/null || true

    # 不靠 sleep 猜：一边确认进程还在，一边真的通过控制连接跑通一条远端命令。
    local sshpid i ok=0
    sshpid="$(pid_in "$SSH_PID_FILE")"
    for ((i = 0; i < 120; i++)); do     # 最多等 30s（DNS / 握手慢的情况）
        if ! alive "$sshpid" "$SSH_MARKER"; then break; fi
        if master_ok; then ok=1; break; fi
        sleep 0.25
    done
    # 二次确认：避开「刚跑通、转发马上被远端拒绝」的瞬间
    if [[ $ok -eq 1 ]] && { ! alive "$sshpid" "$SSH_MARKER" || ! master_ok; }; then
        ok=0
    fi
    if [[ $ok -eq 1 ]]; then
        SSH_PID="$sshpid"
        return 0
    fi

    local reason
    if alive "$sshpid" "$SSH_MARKER"; then
        reason="连接 ${SSH_HOST} 超时：30 秒内隧道未建立"
    else
        reason="$(explain_ssh_failure "$TUNNEL_LOG")"
    fi
    nlog "[ERROR] $reason"
    tail -5 "$TUNNEL_LOG" 2>/dev/null || true
    kill_reverse_tunnel
    set_fatal "$reason"
    return 1
}

# ---- 启动 ----
start() {
    if [[ -n "$CONFIG_ERROR" ]]; then
        nlog "[ERROR] $CONFIG_ERROR"
        set_fatal "$CONFIG_ERROR"
        return 1
    fi

    local cmd
    for cmd in python3 ssh; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            nlog "[ERROR] 未找到命令: $cmd"
            set_fatal "缺少命令 ${cmd}"
            return 1
        fi
    done

    compute_state
    if [[ "$STATE" == "running" ]]; then
        nlog "[INFO] 隧道已在运行。"
        watchdog_ensure
        status || true          # status 在非 running 时返回 1，别让它触发 set -e
        return 0
    fi

    # 清理残留（半开状态），否则端口/隧道会互相打架
    if [[ "$STATE" == "partial" || "$STATE" == "fatal" ]]; then
        nlog "[WARN] 清理上一次的残留进程…"
        stop >/dev/null 2>&1 || true
    fi
    clear_fatal

    start_proxy || return 1

    if ! start_ssh; then
        # 没有隧道，代理留着也没用：整体回滚，避免留一个"半开"的现场
        kill_local_proxy
        return 1
    fi

    nlog "[OK] 隧道已启动并常驻后台。"
    watchdog_ensure
    status || true              # 同上：状态是给人看的，不该决定 start 的退出码
    return 0
}

# ---- 修（看门狗用：只动坏掉的那一半）----
repair() {
    load_env                    # 让 .env 的改动能自动生效
    if [[ -n "$CONFIG_ERROR" ]]; then
        nlog "[ERROR] 配置有问题，自动修复无从下手：$CONFIG_ERROR"
        set_fatal "$CONFIG_ERROR"
        return 1
    fi

    compute_state
    local proxy_ok=$PROXY_UP ssh_ok=$SSH_UP

    # 进程活着 != 隧道通。深检不过要连续两次才动手，避免网络抖动来回拆建。
    if [[ $ssh_ok -eq 1 ]] && ! master_ok; then
        DEEP_FAILS=$((DEEP_FAILS + 1))
        nlog "[WARN] SSH 深检失败（连续 ${DEEP_FAILS} 次）"
        if (( DEEP_FAILS >= 2 )); then
            nlog "[WARN] 判定隧道已死（进程还在但不通），重建连接"
            ssh_ok=0
            kill_reverse_tunnel >/dev/null 2>&1 || true
        fi
    elif [[ $ssh_ok -eq 1 ]]; then
        DEEP_FAILS=0
    fi

    if [[ $proxy_ok -eq 0 ]]; then
        nlog "[WARN] 本地代理没在跑，只重启代理"
        start_proxy || return 1
    fi

    if [[ $ssh_ok -eq 0 ]]; then
        nlog "[WARN] SSH 隧道没在跑，只重建隧道"
        start_ssh || return 1
    fi

    compute_state
    if [[ $STATE == "running" ]]; then
        clear_fatal
        DEEP_FAILS=0
        nlog "[OK] 已恢复：代理 + SSH 隧道 均在运行"
        return 0
    fi
    nlog "[WARN] 修复后状态仍是 $STATE"
    return 1
}

# ---- 停止 ----
kill_local_proxy() {
    local pid
    pid="$(pid_in "$PROXY_PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -CONT "$pid" 2>/dev/null || true   # 被 Ctrl+Z 挂起的进程要先唤醒才收得到信号
        kill "$pid" 2>/dev/null || true
        nlog "[OK] 停止代理 PID $pid"
    fi
    rm -f "$PROXY_PID_FILE"

    # 兜底：PID 文件丢了也要清干净。
    # 只匹配本项目脚本的绝对路径，不会误杀其他项目的 proxy.py。
    pkill -f "$SELF_DIR/proxy.py" 2>/dev/null || true

    # 等它真的退出并把端口还回来，否则紧接着 start 会撞上 EADDRINUSE
    if port_open; then
        wait_port_released 3 || nlog "[WARN] 端口 ${PROXY_PORT} 还没释放，稍后重试"
    fi
}

kill_reverse_tunnel() {
    local pid
    pid="$(pid_in "$SSH_PID_FILE")"

    # 首选：让 master 自己退出（精确，不会误伤别的 ssh）
    if [[ -S "$CTL_SOCKET" ]]; then
        # 必须带超时：master 卡住时 -O 命令不会自己返回
        run_with_timeout "$CTL_TIMEOUT" ssh -O exit \
            -o ControlPath="$CTL_SOCKET" -o BatchMode=yes "$SSH_HOST" >/dev/null 2>&1 || true
    fi
    rm -f "$CTL_SOCKET"

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -CONT "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        nlog "[OK] 停止隧道 PID $pid"
    fi
    rm -f "$SSH_PID_FILE"

    # 兜底：PID 文件丢了，远端端口会被僵尸隧道占着，
    # 下次启动就会「remote port forwarding failed」。这里按特征精准清理。
    pkill -f "ssh .*-R ${REMOTE_PORT}:127.0.0.1:${PROXY_PORT}" 2>/dev/null || true
}

stop() {
    local had=0
    # 先停看门狗：否则它可能在旁边看到 partial，又把隧道拉起来
    # （看门狗自己在跑修复流程时会调 stop，那时不能把自己杀掉）
    if [[ $IN_WATCH -eq 0 ]] && watch_alive; then
        watchdog_stop
    fi

    compute_state
    [[ $PROXY_UP -eq 1 || $SSH_UP -eq 1 ]] && had=1 || true

    kill_reverse_tunnel
    kill_local_proxy
    clear_fatal

    if [[ $had -eq 0 ]]; then
        nlog "[INFO] 没有运行中的隧道 / 代理。"
    else
        nlog "[OK] 已全部停止。"
    fi
    return 0
}

restart_fn() {
    stop
    nlog "[INFO] 重启中…"
    sleep 0.5
    start
}

# ---- 看门狗随隧道启停 ----
# start 的时候顺手确保它在跑（.env 里 WATCHDOG="off" 则不碰）
watchdog_ensure() {
    if [[ "$WATCHDOG" == "off" ]]; then
        nlog "[INFO] WATCHDOG=off，不自动开启看门狗。"
        return 0
    fi
    if watch_alive; then return 0; fi
    nlog "[3/3] 启动看门狗（掉线自动重连）…"
    watchdog_start_quiet
}

# ---- 状态 ----
status() {
    compute_state

    case "$STATE" in
        running) echo "状态: 完全启动 ✅  代理 + SSH 隧道 均在运行" ;;
        partial) echo "状态: 部分启动 ⚠️  两个组件掉了一个" ;;
        fatal)   echo "状态: 致命错误 ❌  需要人工处理" ;;
        stopped) echo "状态: 静默 ⭕  没有任何进程在运行" ;;
    esac

    if [[ $PROXY_UP -eq 1 ]]; then echo "  本地代理 : 运行中 (PID ${PROXY_PID})"; else echo "  本地代理 : 未运行"; fi
    if [[ $SSH_UP -eq 1 ]];   then echo "  SSH 隧道 : 运行中 (PID ${SSH_PID})";   else echo "  SSH 隧道 : 未运行"; fi
    echo "  远程主机 : ${SSH_HOST:-(未配置)}"
    echo "  代理地址 : ${PROXY_HOST}:${PROXY_PORT}  →  远端 ${REMOTE_PORT}"
    echo "  看门狗   : $(watch_text)"

    case "$STATE" in
        partial)
            if [[ $PROXY_UP -eq 1 ]]; then
                echo "  问题     : SSH 隧道掉线，远端 ${REMOTE_PORT} 已释放"
            else
                echo "  问题     : 本地代理已退出（见 .run/proxy.log）"
            fi ;;
        fatal)
            echo "  问题     : $(fatal_reason || true)${CONFIG_ERROR}"
            echo "  处理     : 修复后执行 ./tunnel-daemon.sh restart" ;;
    esac

    [[ "$STATE" == "running" ]]
}

# ---- 机器可读状态（供菜单栏等程序调用）----
probe() {
    compute_state

    local proxy_s="down" ssh_s="down" detail="" reason=""
    [[ $PROXY_UP -eq 1 ]] && proxy_s="up" || true
    [[ $SSH_UP -eq 1 ]] && ssh_s="up" || true

    case "$STATE" in
        running) detail="代理 + SSH 隧道 均在运行" ;;
        partial)
            if [[ $PROXY_UP -eq 1 ]]; then
                detail="本地代理正常，SSH 隧道已断开"
                reason="SSH 隧道掉线，远端 ${REMOTE_PORT} 已释放"
            else
                detail="SSH 隧道正常，本地代理已退出"
                reason="本地代理进程已退出（见 proxy.log）"
            fi ;;
        fatal)
            reason="$(fatal_reason)"
            [[ -n "$reason" ]] || reason="$CONFIG_ERROR"
            detail="需要人工处理：${reason}" ;;
        stopped) detail="未启动（静默）" ;;
    esac

    printf 'state=%s\n'       "$STATE"
    printf 'proxy=%s\n'       "$proxy_s"
    printf 'ssh=%s\n'         "$ssh_s"
    printf 'proxy_pid=%s\n'   "$PROXY_PID"
    printf 'ssh_pid=%s\n'     "$SSH_PID"
    printf 'host=%s\n'        "$SSH_HOST"
    printf 'proxy_addr=%s\n'  "${PROXY_HOST}:${PROXY_PORT}"
    printf 'remote_port=%s\n' "$REMOTE_PORT"
    printf 'detail=%s\n'      "$(one_line "$detail")"
    printf 'reason=%s\n'      "$(one_line "$reason")"
    printf 'watch=%s\n'       "$(watch_state)"
    printf 'watch_pid=%s\n'   "$(watch_pid)"
}

# ---- 日志 ----
logs() {
    local n="${1:-30}"
    echo "== ${PROXY_LOG} =="
    tail -n "$n" "$PROXY_LOG" 2>/dev/null || echo "(暂无)"
    echo ""
    echo "== ${TUNNEL_LOG} =="
    tail -n "$n" "$TUNNEL_LOG" 2>/dev/null || echo "(暂无)"
    echo ""
    echo "== ${WATCH_LOG} =="
    tail -n "$n" "$WATCH_LOG" 2>/dev/null || echo "(暂无)"
}

# ============================================================
#  看门狗
# ============================================================
watch_pid()   { pid_in "$WATCH_PID_FILE"; }
watch_alive() { alive "$(watch_pid)" "tunnel-daemon.sh watch"; }

watch_state() {
    if watch_alive; then echo "on"; else echo "off"; fi
}

watch_text() {
    if watch_alive; then
        echo "自动重连中 (PID $(watch_pid))，随隧道启停"
    else
        echo "未开启"
    fi
}

rotate_watch_log() {
    # 超过 512KB 就轮转一次，别让它无限长
    if [[ -f "$WATCH_LOG" ]] && (( $(wc -c < "$WATCH_LOG" 2>/dev/null || echo 0) > 524288 )); then
        mv -f "$WATCH_LOG" "$WATCH_LOG.1" 2>/dev/null || true
    fi
}

watch_loop() {
    IN_WATCH=1
    # 退出信号只在这个进程里接管：收到就走完当前这轮，干净收尾
    trap 'WATCH_STOPPING=1' TERM INT
    local attempt=0 delay="$WATCH_BACKOFF_BASE" tick=0
    load_env
    echo "── 看门狗 pid=$$ 心跳 ${WATCH_HEARTBEAT}s 深检每 ${WATCH_DEEP_EVERY} 次 ──"
    echo "   状态：$(watch_state)  主机：${SSH_HOST:-?}  代理：${PROXY_HOST}:${PROXY_PORT}"

    while true; do
        if [[ $WATCH_STOPPING -eq 1 ]]; then
            echo "收到退出信号，看门狗结束。"
            release_lock
            return 0
        fi
        tick=$((tick + 1))

        compute_state

        # ---- 健康就不用管 ----
        if [[ $STATE == "running" ]]; then
            local deep_due=0
            (( tick % WATCH_DEEP_EVERY == 0 )) && deep_due=1 || true
            if [[ $deep_due -eq 0 ]]; then
                attempt=0
                delay="$WATCH_BACKOFF_BASE"
                wsleep "$WATCH_HEARTBEAT"
                continue
            fi
            if master_ok; then
                DEEP_FAILS=0
                attempt=0
                delay="$WATCH_BACKOFF_BASE"
                wsleep "$WATCH_HEARTBEAT"
                continue
            fi
            DEEP_FAILS=$((DEEP_FAILS + 1))
            nlog "深检失败第 ${DEEP_FAILS} 次：SSH 进程还在，但隧道已经不通"
            if (( DEEP_FAILS < 2 )); then
                wsleep "$WATCH_HEARTBEAT"
                continue
            fi
        fi

        # ---- 需要修 ----
        local why="状态 ${STATE}"
        [[ $STATE == "running" ]] && why="深检发现隧道不通（进程还在）"
        nlog "需要修复（${why}），第 $((attempt + 1)) 次尝试"
        if with_lock repair; then
            attempt=0
            delay="$WATCH_BACKOFF_BASE"
            wsleep "$WATCH_HEARTBEAT"
            continue
        fi

        attempt=$((attempt + 1))
        # 定向修复连着失败 → 整体重启一次，清掉所有残留再重来
        # （配置错误就没必要折腾了：整体重启也救不了，等用户改 .env）
        # 每 3 次才升级一次（3、6、9…），不要每次失败都整体重启
        if (( attempt % 3 == 0 )) && [[ -z "$CONFIG_ERROR" ]]; then
            nlog "[WARN] 连续 ${attempt} 次定向修复失败，改为整体重启"
            with_lock stop >/dev/null 2>&1 || true
            with_lock start >/dev/null 2>&1 || true
            compute_state
            if [[ $STATE == "running" ]]; then
                nlog "[OK] 整体重启后恢复"
                attempt=0
                delay="$WATCH_BACKOFF_BASE"
                wsleep "$WATCH_HEARTBEAT"
                continue
            fi
        fi

        local why
        why="$(fatal_reason)"
        [[ -n "$why" ]] || why="$CONFIG_ERROR"
        [[ -n "$why" ]] || why="原因不明，见 .run/tunnel.log"
        nlog "修复失败：${why}；${delay}s 后重试"
        wsleep "$delay"
        delay=$((delay * 2))
        (( delay > WATCH_BACKOFF_MAX )) && delay="$WATCH_BACKOFF_MAX" || true
    done
}

watchdog_start() {
    if watch_alive; then
        echo "[INFO] 看门狗已经在跑（PID $(watch_pid)），继续保持自动重连。"
        return 0
    fi
    watchdog_start_quiet
    if watch_alive; then
        echo "[OK] 看门狗已启动（PID $(watch_pid)）"
        echo "     日志: .run/watchdog.log"
        echo "     注意：它跟随隧道启停，'停止隧道' 时也会一起停。"
        return 0
    fi
    echo "[ERROR] 看门狗启动失败，见 .run/watchdog.log"
    tail -5 "$WATCH_LOG" 2>/dev/null || true
    return 1
}

# 只把进程拉起来，不打成功/失败横幅（start 路径用）
watchdog_start_quiet() {
    rm -f "$WATCH_PID_FILE"
    rotate_watch_log
    nohup "$SELF" watch >> "$WATCH_LOG" 2>&1 &
    echo $! > "$WATCH_PID_FILE"
    disown 2>/dev/null || true
    sleep 1
    watch_alive
}

watchdog_stop() {
    local pid i
    pid="$(watch_pid)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for ((i = 0; i < 15; i++)); do      # 现在能立刻退出，等 3 秒足够
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$pid" 2>/dev/null || true
        echo "[OK] 看门狗已停止（PID $pid）"
    else
        echo "[INFO] 看门狗没在跑。"
    fi
    rm -f "$WATCH_PID_FILE"
    # 兜底：PID 文件丢了也要停掉，否则它会一直跟人抢隧道
    pkill -f "$SELF watch" 2>/dev/null || true
    return 0
}

watchdog_status() {
    if watch_alive; then
        echo "看门狗: 运行中 (PID $(watch_pid))，随隧道启停"
    else
        echo "看门狗: 未运行（隧道 start 时会自动开，除非 .env 里 WATCHDOG=off）"
    fi
    [[ -f "$WATCH_LOG" ]] && echo "  日志: $WATCH_LOG"
    return 0
}

watchdog_main() {
    case "${1:-}" in
        start)   watchdog_start ;;
        stop)    watchdog_stop ;;
        restart) watchdog_stop; watchdog_start ;;
        status)  watchdog_status ;;
        *)
            echo "用法: $0 watchdog {start|stop|restart|status}"
            exit 2
            ;;
    esac
}

# ============================================================
#  入口
# ============================================================
load_env

case "${1:-}" in
    start)    with_lock start ;;
    stop)     with_lock stop ;;
    restart)  with_lock restart_fn ;;
    status)   status ;;
    state)    compute_state; echo "$STATE" ;;   # 纯状态词，供程序调用
    probe)    probe ;;                          # key=value，供程序调用
    logs)     logs "${2:-30}" ;;
    watch)    watch_loop ;;                     # 前台看门狗（launchd / 调试用）
    watchdog) watchdog_main "${2:-}" ;;
    *)
        echo "用法: $0 {start|stop|restart|status|state|probe|logs} [n]"
        echo "      $0 watch                      前台跑看门狗"
        echo "      $0 watchdog {start|stop|restart|status}"
        exit 2
        ;;
esac
