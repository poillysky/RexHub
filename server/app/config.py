import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("REXHUB_DATA_DIR", BASE_DIR / "data"))

HOST = os.environ.get("REXHUB_HOST", "0.0.0.0")
PORT = int(os.environ.get("REXHUB_PORT", "8787"))

TOKEN_TTL_SECONDS = int(os.environ.get("REXHUB_TOKEN_TTL", str(30 * 24 * 3600)))

SECRET_PATH = DATA_DIR / "secret.key"
ACCOUNT_PATH = DATA_DIR / "account.json"

# 跨域来源白名单，逗号分隔；默认留空表示不开放跨域（App 与管理台均同源访问）。
CORS_ORIGINS = [
    origin.strip()
    for origin in os.environ.get("REXHUB_CORS_ORIGINS", "").split(",")
    if origin.strip()
]

# 管理台 Cookie 是否只在 HTTPS 下发送；局域网 HTTP 部署保持默认 False。
COOKIE_SECURE = os.environ.get("REXHUB_COOKIE_SECURE", "").lower() in {"1", "true", "yes", "on"}

# 登录失败锁定：同一来源在窗口期内失败达到上限后暂时拒绝登录。
LOGIN_MAX_FAILURES = int(os.environ.get("REXHUB_LOGIN_MAX_FAILURES", "8"))
LOGIN_LOCK_SECONDS = int(os.environ.get("REXHUB_LOGIN_LOCK_SECONDS", "300"))


def ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
