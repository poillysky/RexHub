"""addon 数据持久化：data/addons.json（0600）的原子读写与进程内写锁。"""

import functools
import json
import os
import threading
from typing import Any

from app.rexhub import config

ADDONS_PATH = config.DATA_DIR / "addons.json"

_IO_LOCK = threading.RLock()


def _locked(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        with _IO_LOCK:
            return func(*args, **kwargs)

    return wrapper


def _empty() -> dict[str, Any]:
    return {"repositories": [], "addons": []}


def _read() -> dict[str, Any]:
    try:
        data = json.loads(ADDONS_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    repos = [
        item
        for item in data.get("repositories") or []
        if isinstance(item, dict) and item.get("url")
    ]
    addons = [
        item
        for item in data.get("addons") or []
        if isinstance(item, dict) and item.get("slug") and isinstance(item.get("manifest"), dict)
    ]
    return {"repositories": repos, "addons": addons}


def _write(data: dict[str, Any]) -> None:
    config.ensure_data_dir()
    with _IO_LOCK:
        tmp = ADDONS_PATH.with_name(
            f"{ADDONS_PATH.name}.{os.getpid()}.{threading.get_ident()}.tmp"
        )
        try:
            tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")
            os.chmod(tmp, 0o600)
            tmp.replace(ADDONS_PATH)
        finally:
            tmp.unlink(missing_ok=True)
