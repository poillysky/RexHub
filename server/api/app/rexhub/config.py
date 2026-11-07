import os
from pathlib import Path

# app/rexhub/config.py → parents[3] = 部署根 server/（server/api/app/rexhub → 上三级）。
# RexHub 自己的 JSON 运行时数据单独放 data/rexhub/，与 next-web 的 data/ 互不干扰。
BASE_DIR = Path(__file__).resolve().parents[3]
DATA_DIR = Path(os.environ.get("REXHUB_DATA_DIR", BASE_DIR / "data" / "rexhub"))

HOST = os.environ.get("REXHUB_HOST", "0.0.0.0")
PORT = int(os.environ.get("REXHUB_PORT", "8787"))

# 跨域来源白名单，逗号分隔；默认留空表示不开放跨域（App 与管理台均同源访问）。
CORS_ORIGINS = [
    origin.strip()
    for origin in os.environ.get("REXHUB_CORS_ORIGINS", "").split(",")
    if origin.strip()
]


def ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
