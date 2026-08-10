#!/usr/bin/env bash
# ============================================================
#  Claude Code tunnel launcher (Linux / macOS)
#  --------------------------------------------
#  Reads configuration from .env in the same folder.
#  Copy .env.example to .env and edit it first.
# ============================================================

set -euo pipefail
cd "$(dirname "$0")"

# ---- Load .env ----
if [[ ! -f .env ]]; then
    echo "[ERROR] .env file not found."
    echo "        Copy .env.example to .env and fill in your settings."
    exit 1
fi
set -a
source .env
set +a

# ---- Defaults ----
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-1080}"
REMOTE_PORT="${REMOTE_PORT:-$PROXY_PORT}"

echo "============================================================"
echo " Claude Code tunnel launcher"
echo " ----------------------------"
echo " SSH host   : ${SSH_HOST}"
echo " Proxy      : ${PROXY_HOST}:${PROXY_PORT}"
echo " Remote port: ${REMOTE_PORT}"
echo "============================================================"
echo ""

# ---- Check prerequisites ----
for cmd in python3 ssh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] Missing on PATH: $cmd"
        exit 1
    fi
done

# ---- 1. Start proxy in background ----
echo "[1/2] Starting local proxy (${PROXY_HOST}:${PROXY_PORT})..."
python3 proxy.py &
PROXY_PID=$!
echo "       proxy PID: $PROXY_PID"
sleep 2

# ---- Cleanup on exit ----
cleanup() {
    echo ""
    echo "Shutting down proxy (PID $PROXY_PID)..."
    kill "$PROXY_PID" 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT INT TERM

# ---- 2. Open SSH reverse tunnel ----
echo "[2/2] Opening SSH reverse tunnel to ${SSH_HOST}..."
echo "      remote 127.0.0.1:${REMOTE_PORT} <- local 127.0.0.1:${PROXY_PORT}"
echo ""
echo "      Press Ctrl+C to stop."
echo ""

ssh -N \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -R "${REMOTE_PORT}:127.0.0.1:${PROXY_PORT}" \
    "${SSH_HOST}"
