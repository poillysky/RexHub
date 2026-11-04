"""Stremio addon 接口。

同一个 /stremio 前缀下有两类来源：
  1. 本地明文插件桥接（stremio_bridge）：把 WidgetMetadata 插件包装成 addon；
  2. 管理台接入的第三方 addon 转发：manifest 走本地缓存，其余请求透传。

桥接路由先注册、优先匹配；未命中本地明文插件时回落到原来的 addon 转发。
Stremio 客户端要求 CORS，所有桥接响应都带 Access-Control-Allow-Origin。
"""

from __future__ import annotations

import asyncio
from urllib.parse import parse_qs

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from app.rexhub import addons_store, stremio_bridge

router = APIRouter(prefix="/stremio", tags=["stremio"])

NO_CACHE = {"Cache-Control": "no-cache"}
CORS = {"Access-Control-Allow-Origin": "*"}


def _json(payload: object, status: int = 200) -> JSONResponse:
    return JSONResponse(payload, status_code=status, headers={**NO_CACHE, **CORS})


def _error(status: int, message: str) -> JSONResponse:
    return _json({"error": message}, status)


async def _proxy(slug: str, path: str) -> JSONResponse:
    row = addons_store.find_by_slug(slug)
    if row is None:
        return _error(404, "addon 不存在或已停用")
    try:
        status, payload = await asyncio.to_thread(addons_store.proxy_get, row, path, "")
    except addons_store.UpstreamError as exc:
        return _error(502, str(exc))
    return _json(payload, status)


def _extra_dict(raw: str) -> dict[str, str]:
    values = parse_qs(raw or "", keep_blank_values=True)
    return {key: items[0] for key, items in values.items() if items}


@router.get("/{plugin_id}/manifest.json")
async def manifest(plugin_id: str) -> JSONResponse:
    plugin = stremio_bridge._find_plugin(plugin_id)
    if plugin is None:
        row = addons_store.find_by_slug(plugin_id)
        if row is None:
            return _error(404, "插件不存在或未启用")
        return _json(row["manifest"])
    try:
        return _json(stremio_bridge.build_manifest(plugin))
    except ValueError as exc:
        return _error(502, str(exc))


@router.get("/{plugin_id}/catalog/{media_type}/{catalog_id}.json")
async def catalog(
    plugin_id: str, media_type: str, catalog_id: str
) -> JSONResponse:
    if stremio_bridge._find_plugin(plugin_id) is None:
        return await _proxy(plugin_id, f"catalog/{media_type}/{catalog_id}.json")
    try:
        payload = await stremio_bridge.catalog(plugin_id, catalog_id, {})
    except ValueError as exc:
        return _error(502, str(exc))
    return _json(payload)


@router.get("/{plugin_id}/catalog/{media_type}/{catalog_id}/{extra}.json")
async def catalog_extra(
    plugin_id: str, media_type: str, catalog_id: str, extra: str
) -> JSONResponse:
    if stremio_bridge._find_plugin(plugin_id) is None:
        return await _proxy(
            plugin_id, f"catalog/{media_type}/{catalog_id}/{extra}.json"
        )
    try:
        payload = await stremio_bridge.catalog(plugin_id, catalog_id, _extra_dict(extra))
    except ValueError as exc:
        return _error(502, str(exc))
    return _json(payload)


@router.get("/{plugin_id}/meta/{media_type}/{meta_id}.json")
async def meta(plugin_id: str, media_type: str, meta_id: str) -> JSONResponse:
    if stremio_bridge._find_plugin(plugin_id) is None:
        return await _proxy(plugin_id, f"meta/{media_type}/{meta_id}.json")
    try:
        payload = await stremio_bridge.meta(plugin_id, meta_id)
    except ValueError as exc:
        return _error(502, str(exc))
    return _json(payload)


@router.get("/{plugin_id}/stream/{media_type}/{video_id}.json")
async def stream(plugin_id: str, media_type: str, video_id: str) -> JSONResponse:
    if stremio_bridge._find_plugin(plugin_id) is None:
        return await _proxy(plugin_id, f"stream/{media_type}/{video_id}.json")
    try:
        payload = await stremio_bridge.stream(plugin_id, video_id)
    except ValueError as exc:
        return _error(502, str(exc))
    return _json(payload)


@router.get("/{slug}/{path:path}")
async def forward(slug: str, path: str, request: Request) -> JSONResponse:
    row = addons_store.find_by_slug(slug)
    if row is None:
        raise HTTPException(status_code=404, detail="addon 不存在或已停用")
    if path == "manifest.json":
        return JSONResponse(row["manifest"], headers=NO_CACHE)
    try:
        status, payload = await asyncio.to_thread(
            addons_store.proxy_get, row, path, request.url.query
        )
    except addons_store.UpstreamError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse(payload, status_code=status, headers=NO_CACHE)
