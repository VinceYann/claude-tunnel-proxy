#!/usr/bin/env bash
# ============================================================
#  Stop Claude Code local proxy (Linux / macOS)
#  ---------------------------------------------
#  兜底清理脚本：只杀「本项目」的 proxy.py。
#  原先用 pgrep -f "python.*proxy.py" 会连别的项目的 proxy.py 一起杀，
#  这里改成匹配本目录下的脚本绝对路径。
#  注意：只对用绝对路径启动的代理有效（tunnel-daemon.sh / tunnel.sh 都是）。
# ============================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PIDS=$(pgrep -f "$SELF_DIR/proxy.py" 2>/dev/null || true)

if [[ -z "$PIDS" ]]; then
    echo "No proxy.py process found. Nothing to stop."
    exit 0
fi

for pid in $PIDS; do
    echo "Killing PID $pid ..."
    kill "$pid" 2>/dev/null || echo "  [WARN] Could not kill PID $pid"
    echo "  [OK] PID $pid terminated."
done

echo ""
echo "Done."
