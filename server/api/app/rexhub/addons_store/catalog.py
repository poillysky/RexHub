"""仓库管理：自定义 Stremio addon 仓库的接入、刷新与删除。"""


import time
from typing import Any
from urllib.parse import urlparse

from . import storage
from .addons import add_addon
from .fetch import MAX_REPO_BYTES, _fetch_json
from .manifest import _assign_slug, _entry_targets, _load_entries, _text
from .storage import _locked, _read, _write
from .urls import _http_url, manifest_url


def _repo_title(url: str, title: str) -> str:
    picked = (title or "").strip()
    if picked:
        return picked[:200]
    return urlparse(url).netloc or url


@_locked
def _upsert_repository(
    url: str,
    title: str,
    entries: list[tuple[str, dict[str, Any], str]],
    error: str,
    retain: set[str] | None = None,
) -> dict[str, Any]:
    data = _read()
    now = int(time.time())
    by_transport = {str(row.get("transport") or ""): row for row in data["addons"]}

    fresh: list[dict[str, Any]] = []
    seen_transports: set[str] = set()
    for transport, manifest, entry_error in entries:
        if not transport or transport in seen_transports:
            continue
        seen_transports.add(transport)
        old = by_transport.get(transport) or {}
        owner = str(old.get("repository") or "")
        if owner and owner != url:
            # 该 transport 已归属其他仓库：保留原归属，避免同一 addon 重复入库 / 重复 slug
            continue
        addon_id = _text(manifest.get("id"), 200)
        fresh.append(
            {
                "slug": _assign_slug(
                    addon_id, transport, data["addons"] + fresh, str(old.get("slug") or "")
                ),
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

    # 本仓库接管的 addon（含此前「直接安装」的同 transport 行）从其他归属中移除
    taken = {str(row.get("transport") or "") for row in fresh}
    # retain：本次拉取失败但仍在仓库列表里的 addon，保留旧数据，避免瞬时失败丢条目
    retained = {
        str(row.get("transport") or "")
        for row in data["addons"]
        if row.get("repository") == url and str(row.get("transport") or "") in (retain or set())
    }
    data["addons"] = [
        row
        for row in data["addons"]
        if row.get("repository") != url
        and str(row.get("transport") or "") not in taken
    ] + [
        row
        for row in data["addons"]
        if row.get("repository") == url and str(row.get("transport") or "") in retained
    ] + fresh

    repo = next((row for row in data["repositories"] if row.get("url") == url), None)
    if repo is None:
        repo = {"url": url, "created_at": now}
        data["repositories"].append(repo)

    counts: dict[str, int] = {}
    for row in data["addons"]:
        key = str(row.get("repository") or "")
        if key:
            counts[key] = counts.get(key, 0) + 1
    for row in data["repositories"]:
        row["count"] = counts.get(str(row.get("url") or ""), 0)

    repo.update({"title": _repo_title(url, title), "fetched_at": now, "error": error})
    _write(data)
    return {"url": url, "title": repo["title"], "count": repo["count"], "error": error}


def add_repository(url: str, title: str = "") -> dict[str, Any]:
    target = _http_url(url).rstrip("/")
    if target.lower().endswith("/manifest.json"):
        # 单个 manifest 地址：按单个 addon 接入
        addon = add_addon(target)
        return {
            "url": addon["transport"],
            "title": str(title or addon["manifest"].get("name") or addon["id"]),
            "count": 1,
            "kind": "addon",
        }
    with storage._IO_LOCK:
        exists = any(row.get("url") == target for row in _read()["repositories"])
    if exists:
        return {**refresh_repository(target), "kind": "repository"}
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
            # 直接粘贴单个 manifest 地址时，按单个 addon 接入（复用已拉取的 manifest）
            addon = add_addon(target, manifest)
            return {
                "url": addon["transport"],
                "title": str(title or manifest.get("name") or addon["id"]),
                "count": 1,
                "kind": "addon",
            }
    entries = _load_entries(doc)
    if not entries:
        raise ValueError("仓库里没有可用的 addon")
    return {**_upsert_repository(target, title, entries, ""), "kind": "repository"}


def _set_repo_error(target: str, message: str) -> None:
    with storage._IO_LOCK:
        latest = _read()
        for index, row in enumerate(latest["repositories"]):
            if row.get("url") == target:
                latest["repositories"][index] = {
                    **row,
                    "error": message,
                    "fetched_at": int(time.time()),
                }
        _write(latest)


def refresh_repository(url: str) -> dict[str, Any]:
    target = _http_url(url).rstrip("/")
    data = _read()
    repo = next((row for row in data["repositories"] if row.get("url") == target), None)
    if repo is None:
        raise ValueError("仓库不存在")
    try:
        doc = _fetch_json(target, MAX_REPO_BYTES)
        listed = {transport for transport, _, _ in _entry_targets(doc) if transport}
        entries = _load_entries(doc)
    except ValueError as exc:
        _set_repo_error(target, str(exc))
        raise ValueError(str(exc)) from exc
    if not entries:
        _set_repo_error(target, "仓库里没有可用的 addon")
        raise ValueError("仓库里没有可用的 addon")
    retain = listed - {transport for transport, _, _ in entries}
    return _upsert_repository(target, str(repo.get("title") or ""), entries, "", retain)


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
