"""仓库管理：官方 / 第三方仓库的接入、刷新与删除。"""

import time
from typing import Any
from urllib.parse import urlparse

from . import storage
from .addons import add_addon
from .fetch import MAX_REPO_BYTES, _fetch_json
from .manifest import _assign_slug, _load_entries, _text
from .storage import _locked, _read, _write
from .urls import _http_url, manifest_url

OFFICIAL_REPOSITORY = "https://api.strem.io/addonscollection.json"
REPOSITORY_PRESETS = (
    ("Stremio 官方仓库", OFFICIAL_REPOSITORY),
)


def _repo_title(url: str, title: str) -> str:
    picked = (title or "").strip()
    if picked:
        return picked[:200]
    for name, preset in REPOSITORY_PRESETS:
        if preset == url:
            return name
    return urlparse(url).netloc or url


@_locked
def _upsert_repository(
    url: str, title: str, entries: list[tuple[str, dict[str, Any], str]], error: str
) -> dict[str, Any]:
    data = _read()
    now = int(time.time())
    others = [row for row in data["addons"] if row.get("repository") != url]
    kept = {str(row.get("transport")): row for row in data["addons"] if row.get("repository") == url}

    fresh: list[dict[str, Any]] = []
    for transport, manifest, entry_error in entries:
        old = kept.get(transport) or {}
        addon_id = _text(manifest.get("id"), 200)
        fresh.append(
            {
                "slug": _assign_slug(addon_id, transport, others + fresh, str(old.get("slug") or "")),
                "id": addon_id,
                "transport": transport,
                "manifest_url": manifest_url(transport),
                "manifest": manifest,
                "repository": url,
                "enabled": bool(old.get("enabled", True)),
                "added_at": int(old.get("added_at") or now),
                "updated_at": now,
                "error": entry_error,
            }
        )

    data["addons"] = others + fresh
    repo = next((row for row in data["repositories"] if row.get("url") == url), None)
    if repo is None:
        repo = {"url": url, "created_at": now}
        data["repositories"].append(repo)
    repo.update(
        {
            "title": _repo_title(url, title),
            "fetched_at": now,
            "error": error,
            "count": len(fresh),
        }
    )
    _write(data)
    return {"url": url, "title": repo["title"], "count": len(fresh), "error": error}


def add_repository(url: str, title: str = "") -> dict[str, Any]:
    target = _http_url(url).rstrip("/")
    if target.lower().endswith("/manifest.json"):
        # 单个 manifest 地址：按单个 addon 接入
        addon = add_addon(target)
        return {
            "url": addon["transport"],
            "title": str(title or addon["manifest"].get("name") or addon["id"]),
            "count": 1,
        }
    with storage._IO_LOCK:
        exists = any(row.get("url") == target for row in _read()["repositories"])
    if exists:
        return refresh_repository(target)
    try:
        doc = _fetch_json(target, MAX_REPO_BYTES)
    except ValueError as exc:
        raise ValueError(str(exc)) from exc
    if isinstance(doc, dict) and not (
        isinstance(doc.get("addons"), list)
        or isinstance(doc.get("items"), list)
        or doc.get("transportUrl")
    ):
        manifest = _manifest_of(doc)
        if manifest is not None:
            # 直接粘贴单个 manifest 地址时，按单个 addon 接入
            addon = add_addon(target)
            return {
                "url": addon["transport"],
                "title": str(title or manifest.get("name") or addon["id"]),
                "count": 1,
            }
    entries = _load_entries(doc)
    if not entries:
        raise ValueError("仓库里没有可用的 addon")
    return _upsert_repository(target, title, entries, "")


def refresh_repository(url: str) -> dict[str, Any]:
    target = _http_url(url).rstrip("/")
    data = _read()
    repo = next((row for row in data["repositories"] if row.get("url") == target), None)
    if repo is None:
        raise ValueError("仓库不存在")
    try:
        doc = _fetch_json(target, MAX_REPO_BYTES)
        entries = _load_entries(doc)
    except ValueError as exc:
        repo = dict(repo)
        repo.update({"error": str(exc), "fetched_at": int(time.time())})
        with storage._IO_LOCK:
            latest = _read()
            for index, row in enumerate(latest["repositories"]):
                if row.get("url") == target:
                    latest["repositories"][index] = {**row, **repo}
            _write(latest)
        raise ValueError(str(exc)) from exc
    if not entries:
        raise ValueError("仓库里没有可用的 addon")
    return _upsert_repository(target, str(repo.get("title") or ""), entries, "")


@_locked
def delete_repository(url: str) -> bool:
    target = _http_url(url).rstrip("/")
    data = _read()
    remain = [row for row in data["repositories"] if row.get("url") != target]
    if len(remain) == len(data["repositories"]):
        return False
    data["repositories"] = remain
    data["addons"] = [row for row in data["addons"] if row.get("repository") != target]
    _write(data)
    return True
