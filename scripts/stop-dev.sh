#!/usr/bin/env bash
# 停掉本地 API / Web 开发进程。
set -uo pipefail

pkill -f "uvicorn app.main:app" 2>/dev/null && echo "api stopped"
pkill -f "next dev" 2>/dev/null && echo "web stopped"
exit 0
