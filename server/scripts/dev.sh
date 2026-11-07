#!/usr/bin/env bash
# 本地一键启动：API（8787）+ PWA Web（3020）。Ctrl+C 同时退出。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_PORT="${API_PORT:-8787}"
WEB_PORT="${WEB_PORT:-3020}"

# Node 装在 ~/.local/node（未进系统 PATH 时也能跑）
if ! command -v node >/dev/null 2>&1; then
  export PATH="$HOME/.local/node/bin:$PATH"
fi

if [ ! -x "$ROOT/api/.venv/bin/python" ]; then
  echo "缺少 api/.venv，请先执行："
  echo "  cd api && ~/.local/bin/python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  exit 1
fi

if [ ! -d "$ROOT/web/node_modules" ]; then
  echo "缺少 web/node_modules，请先执行：cd web && npm install"
  exit 1
fi

cleanup() {
  trap - INT TERM EXIT
  kill 0
}
trap cleanup INT TERM EXIT

echo "API  -> http://0.0.0.0:${API_PORT}"
echo "Web  -> http://0.0.0.0:${WEB_PORT}"

(cd "$ROOT/api" && .venv/bin/python -m uvicorn app.main:app \
  --host 0.0.0.0 --port "$API_PORT" --reload) &

(cd "$ROOT/web" && API_INTERNAL_BASE="http://127.0.0.1:${API_PORT}" \
  npm run dev) &

wait
