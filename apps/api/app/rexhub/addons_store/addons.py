"""addon 管理：单个 addon 的接入、刷新、启停、删除、探测与查询。"""

import time
from typing import Any
from urllib.parse import quote

from . import storage
from .fetch import MAX_MANIFEST_BYTES, UpstreamError, _fetch_json, proxy_get
from .manifest import _assign_slug, _manifest_of, _text
from .storage import _locked, _read, _write
from .urls import manifest_url, normalize_transport


def add_addon(url: str) -> dict[str, Any]:
    transport = normalize_transport(url)
    manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
    if manifest is None:
        raise ValueError("该地址返回的不是 addon manifest")
    addon_id = _text(manifest.get("id"), 200)
    if not addon_id:
        raise ValueError("manifest 缺少 id")
    with storage._IO_LOCK:
        data = _read()
        old = next((row for row in data["addons"] if row.get("transport") == transport), None)
        now = int(time.time())
        row = {
            "slug": _assign_slug(
                addon_id, transport, data["addons"], str((old or {}).get("slug") or "")
            ),
            "id": addon_id,
            "transport": transport,
            "manifest_url": manifest_url(transport),
            "manifest": manifest,
            "repository": (old or {}).get("repository") or "",
            "enabled": bool((old or {}).get("enabled", True)),
            "added_at": int((old or {}).get("added_at") or now),
            "updated_at": now,
            "error": "",
        }
        if old is None:
            data["addons"].append(row)
        else:
            data["addons"] = [
                row if item.get("transport") == transport else item for item in data["addons"]
            ]
        _write(data)
        return row


def refresh_addon(slug: str) -> dict[str, Any]:
    row = find_any(slug)
    if row is None:
        raise ValueError("addon 不存在")
    transport = str(row.get("transport") or "")
    manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
    if manifest is None:
        raise ValueError("manifest 格式不正确")
    with storage._IO_LOCK:
        data = _read()
        for item in data["addons"]:
            if item.get("slug") == slug:
                item.update({"manifest": manifest, "updated_at": int(time.time()), "error": ""})
        _write(data)
    return find_any(slug) or row


def test_addon(slug: str) -> dict[str, Any]:
    """探测 addon 是否可用：拉取 manifest，再试一次它的首个目录。"""
    row = find_any(slug)
    if row is None:
        raise ValueError("addon 不存在")
    transport = str(row.get("transport") or "")
    started = time.monotonic()

    def elapsed() -> int:
        return int((time.monotonic() - started) * 1000)

    try:
        manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
    except ValueError as exc:
        return {"ok": False, "ms": elapsed(), "message": f"manifest 请求失败：{exc}"}
    if manifest is None:
        return {"ok": False, "ms": elapsed(), "message": "manifest 格式不正确"}

    catalog = next(
        (
            item
            for item in manifest.get("catalogs") or []
            if isinstance(item, dict)
            and item.get("type")
            and item.get("id")
            and not item.get("extraRequired")
        ),
        None,
    )
    if catalog:
        path = (
            f"catalog/{quote(str(catalog['type']), safe='')}"
            f"/{quote(str(catalog['id']), safe='')}.json"
        )
        try:
            status, _ = proxy_get(row, path)
        except UpstreamError as exc:
            return {"ok": False, "ms": elapsed(), "message": f"目录请求失败：{exc}"}
        if status >= 400:
            return {"ok": False, "ms": elapsed(), "message": f"目录返回 HTTP {status}"}

    detail = "manifest 正常"
    if catalog:
        detail += " · 目录可访问"
    return {"ok": True, "ms": elapsed(), "message": detail}


@_locked
def set_addon_enabled(slug: str, enabled: bool) -> bool:
    data = _read()
    row = next((item for item in data["addons"] if item.get("slug") == slug), None)
    if row is None:
        return False
    row["enabled"] = enabled
    row["updated_at"] = int(time.time())
    _write(data)
    return True


@_locked
def delete_addon(slug: str) -> bool:
    data = _read()
    remain = [item for item in data["addons"] if item.get("slug") != slug]
    if len(remain) == len(data["addons"]):
        return False
    data["addons"] = remain
    _write(data)
    return True


def find_any(slug: str) -> dict[str, Any] | None:
    return next((row for row in _read()["addons"] if row.get("slug") == slug), None)


def find_by_slug(slug: str) -> dict[str, Any] | None:
    row = find_any(slug)
    if row is None or not row.get("enabled", True):
        return None
    return row


def snapshot() -> dict[str, Any]:
    data = _read()
    return {
        "repositories": data["repositories"],
        "addons": data["addons"],
        "stats": {
            "repositories": len(data["repositories"]),
            "addons": len(data["addons"]),
            "enabled": sum(1 for row in data["addons"] if row.get("enabled", True)),
        },
    }
