#!/usr/bin/env bash
# ============================================================
#  Stop Claude Code local proxy (Linux / macOS)
#  ---------------------------------------------
#  Kills only python processes running proxy.py.
# ============================================================
set -euo pipefail

PIDS=$(pgrep -f "python.*proxy.py" 2>/dev/null || true)

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
