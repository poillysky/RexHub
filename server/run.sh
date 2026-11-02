#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
fi

HOST="${REXHUB_HOST:-0.0.0.0}"
PORT="${REXHUB_PORT:-8787}"

echo "RexHub Server  ->  http://${HOST}:${PORT}"
echo "管理台入口      ->  http://${HOST}:${PORT}/admin"

exec .venv/bin/uvicorn app.main:app --host "$HOST" --port "$PORT" --reload "$@"
