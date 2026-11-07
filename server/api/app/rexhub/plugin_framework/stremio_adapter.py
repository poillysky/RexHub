"""Stremio Addon Protocol 适配器。

把 addons_store 里已启用的 Stremio addon 暴露成统一插件列表，并把
catalog / meta / stream / subtitles 调用映射到同一个 execute 入口。
"""


import re
from typing import Any

from app.rexhub import addons_store
from app.rexhub.addons_store import browse
from app.rexhub.addons_store import streams as addon_streams
from app.rexhub.addons_store import subtitles as addon_subtitles

PREFIX = "stremio:"


def _resources(manifest: dict[str, Any]) -> set[str]:
    names = set()
    for item in manifest.get("resources") or []:
        name = item if isinstance(item, str) else (item.get("name") if isinstance(item, dict) else "")
        if name:
            names.add(str(name))
    return names


def _capabilities(manifest: dict[str, Any]) -> list[str]:
    resources = _resources(manifest)
    caps = []
    if "catalog" in resources:
        caps.append("resource.catalog")
    if "meta" in resources:
        caps.append("metadata.detail")
    if "stream" in resources:
        caps.append("playback.resolve")
    if "subtitles" in resources:
        caps.append("subtitle.search")
    return caps


def _modules(row: dict[str, Any]) -> list[dict[str, Any]]:
    info = browse.catalogs(row)
    modules = []
    for item in info.get("catalogs") or []:
        modules.append(
            {
                "id": f"catalog:{item['type']}:{item['id']}",
                "title": item.get("name") or item["id"],
                "type": "catalog",
                "params": [
                    {"name": key, "title": key, "type": "input"}
                    for key in item.get("extraSupported") or []
                ],
            }
        )
    resources = _resources(row.get("manifest") or {})
    if "meta" in resources:
        modules.append({"id": "meta", "title": "元数据", "type": "detail", "params": []})
    if "stream" in resources:
        modules.append({"id": "stream", "title": "片源", "type": "stream", "params": []})
    if "subtitles" in resources:
        modules.append({"id": "subtitles", "title": "字幕", "type": "subtitle", "params": []})
    return modules


def list_plugins() -> list[dict[str, Any]]:
    result = []
    for row in addons_store.snapshot().get("addons") or []:
        if not row.get("enabled", True):
            continue
        slug = str(row.get("slug") or "")
        if not slug:
            continue
        manifest = row.get("manifest") or {}
        result.append(
            {
                "id": f"{PREFIX}{slug}",
                "name": str(manifest.get("name") or slug),
                "version": str(manifest.get("version") or ""),
                "category": "resource",
                "protocol": "stremio",
                "runtime": "http",
                "capabilities": _capabilities(manifest),
                "running": True,
                "modules": _modules(row),
                "search": None,
            }
        )
    return result


def _row(plugin_id: str) -> dict[str, Any]:
    slug = plugin_id[len(PREFIX):] if plugin_id.startswith(PREFIX) else plugin_id
    row = addons_store.find_by_slug(slug)
    if row is None:
        raise ValueError("Stremio addon 不存在或已停用")
    return row


def detail(plugin_id: str) -> dict[str, Any]:
    row = _row(plugin_id)
    manifest = row.get("manifest") or {}
    return {
        "id": plugin_id,
        "name": str(manifest.get("name") or row.get("slug")),
        "description": str(manifest.get("description") or ""),
        "version": str(manifest.get("version") or ""),
        "category": "resource",
        "protocol": "stremio",
        "runtime": {"type": "http", "base_url": row.get("transport") or ""},
        "capabilities": _capabilities(manifest),
        "permissions": ["network"],
        "config": {},
        "enabled": bool(row.get("enabled", True)),
        "running": True,
        "modules": _modules(row),
        "search": None,
        "detailCacheDuration": 0,
    }


def execute(plugin_id: str, module_id: str, params: dict[str, Any]) -> dict[str, Any]:
    row = _row(plugin_id)
    if module_id.startswith("catalog:"):
        parts = module_id.split(":", 2)
        if len(parts) != 3:
            raise ValueError("目录模块 ID 不合法")
        _, media_type, catalog_id = parts
        extra = {
            key: str(value)
            for key, value in (params or {}).items()
            if key in ("genre", "year", "search", "skip")
        }
        data = browse.catalog(row, media_type, catalog_id, extra)
        return {"data": data.get("items") or [], "cached": False}
    if module_id == "meta":
        data = browse.meta(
            row,
            str(params.get("mediaType") or "movie"),
            str(params.get("id") or ""),
        )
        return {"data": data, "cached": False}
    if module_id == "stream":
        data = browse.streams(
            row,
            str(params.get("mediaType") or "movie"),
            str(params.get("id") or ""),
            int(params.get("season") or 0),
            int(params.get("episode") or 0),
        )
        return {"data": data, "cached": False}
    if module_id == "subtitles":
        imdb_id = str(params.get("imdbId") or "")
        if not re.match(r"^tt\d{5,12}$", imdb_id):
            raise ValueError("字幕需要 IMDb 编号")
        data = addon_subtitles.collect(
            str(params.get("mediaType") or "movie"),
            imdb_id,
            int(params.get("season") or 0),
            int(params.get("episode") or 0),
        )
        return {"data": data.get("subtitles") or [], "cached": False}
    if module_id == "catalogs":
        return {"data": browse.catalogs(row), "cached": False}
    raise ValueError("Stremio 插件不支持该模块")
