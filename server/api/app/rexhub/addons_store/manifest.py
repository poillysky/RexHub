"""清单解析：仓库文档结构识别、字段提取、slug 分配与 manifest 并发补拉。"""

import hashlib
import re
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from .fetch import MAX_MANIFEST_BYTES, _fetch_json
from .urls import manifest_url, normalize_transport

MAX_ADDONS_PER_REPO = 1000


def _text(value: object, limit: int = 300) -> str:
    return str(value or "").strip()[:limit]


def _manifest_of(value: object) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    manifest = value.get("manifest")
    if isinstance(manifest, dict):
        return manifest
    if value.get("id") and (value.get("resources") or value.get("types")):
        return value
    return None


def _entries(doc: object) -> list:
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for key in ("addons", "items"):
            items = doc.get(key)
            if isinstance(items, list):
                return items
        if doc.get("transportUrl") or _manifest_of(doc):
            return [doc]
    raise ValueError("仓库格式不正确：需要 addon 列表或单个 manifest")


def _entry_targets(doc: object) -> list[tuple[str, dict[str, Any] | None, str]]:
    """整理成 (transport, manifest 或 None, 错误) 列表，manifest 缺失的稍后拉取。"""
    rows: list[tuple[str, dict[str, Any] | None, str]] = []
    for entry in _entries(doc)[:MAX_ADDONS_PER_REPO]:
        if isinstance(entry, str):
            url = entry.strip()
            if not url:
                continue
            try:
                rows.append((normalize_transport(url), None, ""))
            except ValueError as exc:
                rows.append(("", None, str(exc)))
            continue
        if not isinstance(entry, dict):
            continue
        manifest = _manifest_of(entry)
        raw_url = _text(entry.get("transportUrl") or entry.get("url"), 600)
        if not raw_url:
            rows.append(("", manifest, "缺少 transportUrl"))
            continue
        try:
            transport = normalize_transport(raw_url)
        except ValueError as exc:
            rows.append(("", manifest, str(exc)))
            continue
        rows.append((transport, manifest, ""))
    return rows


def _load_entries(doc: object) -> list[tuple[str, dict[str, Any], str]]:
    """补齐缺失的 manifest，返回 (transport, manifest, 错误)。"""
    targets = _entry_targets(doc)
    missing = [item for item in targets if item[1] is None and item[0]]

    fetched: dict[str, tuple[dict[str, Any] | None, str]] = {}

    def one(transport: str) -> None:
        try:
            manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
        except ValueError as exc:
            fetched[transport] = (None, str(exc))
            return
        fetched[transport] = (manifest, "" if manifest else "manifest 格式不正确")

    if missing:
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(one, [item[0] for item in missing]))

    result: list[tuple[str, dict[str, Any], str]] = []
    seen: set[str] = set()
    for transport, manifest, error in targets:
        if not transport:
            continue
        if manifest is None:
            manifest, fetch_error = fetched.get(transport, (None, error or "manifest 获取失败"))
            error = fetch_error
        if manifest is None:
            continue
        addon_id = _text(manifest.get("id"), 200)
        if not addon_id:
            continue
        if addon_id in seen:
            continue
        seen.add(addon_id)
        result.append((transport, manifest, error))
    return result


def _slug_base(addon_id: str) -> str:
    base = re.sub(r"[^A-Za-z0-9._-]", "_", addon_id).strip("._-")[:80]
    return base or "addon"


def _assign_slug(addon_id: str, transport: str, addons: list[dict], keep: str = "") -> str:
    if keep:
        return keep
    used = {str(row.get("slug")) for row in addons if row.get("transport") != transport}
    base = _slug_base(addon_id)
    if base not in used:
        return base
    suffix = hashlib.sha1(transport.encode("utf-8")).hexdigest()[:6]
    candidate = f"{base}-{suffix}"
    index = 2
    while candidate in used:
        candidate = f"{base}-{suffix}-{index}"
        index += 1
    return candidate
