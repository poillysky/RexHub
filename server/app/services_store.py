"""NAS 服务清单。

以卡片形式维护自建服务的连接信息（地址、端口、账号、API Key 等），
配置保存在 data/services.json（0600），仅管理台可读写。
"""

from __future__ import annotations

import json
import os
import re
import socket
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from . import config

SERVICES_PATH = config.DATA_DIR / "services.json"

PROBE_TIMEOUT = 1.0
PROBE_TTL = 15

CATEGORIES = {
    "indexer": "索引器",
    "database": "数据库",
    "media": "媒体服务",
    "download": "下载器",
    "api": "接口服务",
    "other": "其他",
}

# 不预置任何服务：避免把内网地址与数据库口令写进代码。首次部署由管理台录入。
DEFAULT_SERVICES: list[dict[str, Any]] = []

_probe_cache: dict[str, dict[str, Any]] = {}


def _read() -> list[dict[str, Any]]:
    try:
        data = json.loads(SERVICES_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        return [dict(item) for item in DEFAULT_SERVICES]
    if not isinstance(data, list):
        return [dict(item) for item in DEFAULT_SERVICES]
    rows = []
    for item in data:
        if isinstance(item, dict) and item.get("id"):
            rows.append(item)
    return rows or [dict(item) for item in DEFAULT_SERVICES]


def _write(items: list[dict[str, Any]]) -> None:
    config.ensure_data_dir()
    tmp = SERVICES_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(items, ensure_ascii=False, indent=2), "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(SERVICES_PATH)


def _clean_port(value: Any) -> int:
    try:
        port = int(value)
    except (TypeError, ValueError):
        return 0
    return port if 0 < port < 65536 else 0


def _slug(name: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return base or f"svc-{int(time.time())}"


def _text(payload: dict, key: str, limit: int = 200) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        return ""
    return value.strip()[:limit]


def category_label(key: str) -> str:
    return CATEGORIES.get(key, CATEGORIES["other"])


def list_services() -> list[dict[str, Any]]:
    return _read()


def save_service(payload: dict[str, Any]) -> dict[str, Any]:
    items = _read()
    sid = _text(payload, "id", 64)
    name = _text(payload, "name", 64)
    if not name:
        raise ValueError("请填写服务名称")
    host = _text(payload, "host", 128)
    if not host:
        raise ValueError("请填写主机地址")
    port = _clean_port(payload.get("port"))
    if not port:
        raise ValueError("请填写有效端口")

    row: dict[str, Any] | None = None
    for item in items:
        if item.get("id") == sid:
            row = item
            break
    is_new = row is None
    if row is None:
        row = {"id": sid or _slug(name), "password": ""}
        if any(item.get("id") == row["id"] for item in items):
            row["id"] = f"{row['id']}-{int(time.time())}"
        items.append(row)

    row.update(
        {
            "name": name,
            "category": _text(payload, "category", 24) or "other",
            "host": host,
            "port": port,
            "username": _text(payload, "username", 128),
            "database": _text(payload, "database", 128),
            "api_key": _text(payload, "api_key", 256),
            "url": _text(payload, "url", 300),
            "notes": _text(payload, "notes", 300),
            "updated_at": int(time.time()),
        }
    )
    password = payload.get("password")
    if isinstance(password, str) and password.strip():
        row["password"] = password.strip()[:200]

    _write(items)
    _probe_cache.pop(row["id"], None)
    return {"ok": True, "id": row["id"], "created": is_new}


def delete_service(sid: str) -> bool:
    items = _read()
    remain = [item for item in items if item.get("id") != sid]
    if len(remain) == len(items):
        return False
    _write(remain)
    _probe_cache.pop(sid, None)
    return True


def _probe_host(host: str, port: int) -> dict[str, Any]:
    started = time.time()
    try:
        with socket.create_connection((host, port), timeout=PROBE_TIMEOUT):
            latency = int((time.time() - started) * 1000)
            return {"online": True, "latency": latency}
    except OSError:
        return {"online": False, "latency": None}


def _probe(item: dict[str, Any]) -> dict[str, Any]:
    now = time.time()
    cached = _probe_cache.get(item["id"])
    if cached and now - cached["at"] < PROBE_TTL:
        return cached
    result = _probe_host(str(item.get("host") or ""), _clean_port(item.get("port")))
    result["at"] = now
    _probe_cache[item["id"]] = result
    return result


def statuses(items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    if not items:
        return {}
    with ThreadPoolExecutor(max_workers=min(8, len(items))) as pool:
        results = list(pool.map(_probe, items))
    return {item["id"]: result for item, result in zip(items, results)}
