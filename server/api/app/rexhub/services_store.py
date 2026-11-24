"""NAS 服务清单。

以卡片形式维护自建服务的连接信息（地址、端口、账号、API Key 等），
配置保存在 data/services.json（0600），仅管理台可读写。
"""


import json
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from app.rexhub import config

SERVICES_PATH = config.DATA_DIR / "services.json"

PROBE_TIMEOUT = 1.0
PROBE_TTL = 15

CATEGORIES = {
    "indexer": "索引器",
    "database": "数据库",
    "media": "媒体服务",
    "playback": "在线播放",
    "download": "下载器",
    "source": "内容源",
    "api": "接口服务",
    "other": "其他",
}

# 内容源类型：目前只有短剧源，后续新增类型只需在这里登记。
SOURCE_KINDS = {
    "shortdrama": "短剧源",
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


def _clean_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        text = value.strip().lower()
        if text in {"1", "true", "yes", "on"}:
            return True
        if text in {"0", "false", "no", "off"}:
            return False
    if isinstance(value, (int, float)):
        return bool(value)
    return default


def _clean_map(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    return {str(key): item for key, item in value.items() if isinstance(key, str)}


def category_label(key: str) -> str:
    return CATEGORIES.get(key, CATEGORIES["other"])


def list_services() -> list[dict[str, Any]]:
    return _read()


def get_service(sid: str) -> dict[str, Any] | None:
    for item in _read():
        if item.get("id") == sid:
            return item
    return None


def list_sources(kind: str) -> list[dict[str, Any]]:
    """按内容源类型取启用的服务行（短剧源用 ``shortdrama``）。"""
    return [
        item
        for item in _read()
        if str(item.get("source_kind") or "") == kind
        and _clean_bool(item.get("enabled"), True)
    ]


def save_service(payload: dict[str, Any]) -> dict[str, Any]:
    items = _read()
    sid = _text(payload, "id", 64)
    name = _text(payload, "name", 64)
    if not name:
        raise ValueError("请填写服务名称")

    # 内容源（外部 HTTP API）只需要一个地址，无需主机 + 端口；
    # 传统 NAS 服务仍按 host + port 录入，两者互不强制。
    api_base = (_text(payload, "api_base", 300) or _text(payload, "url", 300)).rstrip("/")
    host = _text(payload, "host", 128)
    port = _clean_port(payload.get("port"))
    if not host and api_base:
        parsed = urllib.parse.urlparse(api_base)
        host = parsed.hostname or ""
        port = port or _clean_port(parsed.port)
    if not host and not api_base:
        raise ValueError("请填写主机地址或服务地址")
    if not port and not api_base:
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
            "url": _text(payload, "url", 300),
            "api_base": api_base,
            "source_kind": _text(payload, "source_kind", 32),
            "notes": _text(payload, "notes", 300),
            "updated_at": int(time.time()),
        }
    )
    # 凭据字段不由通用编辑面板下发，空值不覆盖已保存的账号。
    for key, limit in (
        ("username", 128),
        ("database", 128),
        ("api_key", 256),
    ):
        value = _text(payload, key, limit)
        if value:
            row[key] = value
    section = _text(payload, "section", 24)
    if section:
        row["section"] = section
    elif "section" in payload:
        row.pop("section", None)
    endpoints = _clean_map(payload.get("endpoints"))
    if endpoints:
        row["endpoints"] = endpoints
    elif "endpoints" in payload:
        row.pop("endpoints", None)
    ui = _clean_map(payload.get("ui"))
    if ui:
        row["ui"] = ui
    elif "ui" in payload:
        row.pop("ui", None)
    row["enabled"] = _clean_bool(payload.get("enabled"), _clean_bool(row.get("enabled"), True))
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


def _probe_http(url: str) -> dict[str, Any]:
    """无端口的 HTTP 服务源：有响应即视为在线（含 4xx/5xx）。"""
    if not url.startswith(("http://", "https://")):
        return {"online": False, "latency": None}
    started = time.time()
    request = urllib.request.Request(url, method="HEAD", headers={"Accept": "*/*"})
    try:
        with urllib.request.urlopen(request, timeout=PROBE_TIMEOUT):
            return {"online": True, "latency": int((time.time() - started) * 1000)}
    except urllib.error.HTTPError:
        return {"online": True, "latency": int((time.time() - started) * 1000)}
    except (urllib.error.URLError, OSError, ValueError):
        return {"online": False, "latency": None}


def probe_target(host: str, port: int = 0, api_base: str = "", url: str = "") -> dict[str, Any]:
    """不落库的连通性测试：有主机 + 端口走 socket，否则按 HTTP 地址探测。"""
    clean_host = str(host or "").strip()
    clean_port = _clean_port(port)
    if clean_host and clean_port:
        return _probe_host(clean_host, clean_port)
    target = str(api_base or url or "").strip().rstrip("/")
    if not target and clean_host:
        target = f"http://{clean_host}"
    if not clean_port and target:
        parsed = urllib.parse.urlparse(target)
        if parsed.port:
            return _probe_host(parsed.hostname or "", parsed.port)
    return _probe_http(target)


def _probe(item: dict[str, Any]) -> dict[str, Any]:
    now = time.time()
    cached = _probe_cache.get(item["id"])
    if cached and now - cached["at"] < PROBE_TTL:
        return cached
    host = str(item.get("host") or "")
    port = _clean_port(item.get("port"))
    if host and port:
        result = _probe_host(host, port)
    else:
        result = _probe_http(str(item.get("api_base") or item.get("url") or ""))
    result["at"] = now
    _probe_cache[item["id"]] = result
    return result


def statuses(items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    if not items:
        return {}
    with ThreadPoolExecutor(max_workers=min(8, len(items))) as pool:
        results = list(pool.map(_probe, items))
    return {item["id"]: result for item, result in zip(items, results)}
