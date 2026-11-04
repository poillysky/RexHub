"""Stremio 风格插件接口：把明文插件的函数暴露成标准 HTTP 资源。

  /addon/{id}/manifest.json
  /addon/{id}/catalog/{type}/{catalog}.json
  /addon/{id}/meta/{type}/{id}.json
  /addon/{id}/stream/{type}/{id}.json

列表、搜索、封面、详情由插件函数执行；stream 返回播放层（如 NAS 25566）
的地址，真正的视频流仍由播放层提供。
"""

from __future__ import annotations

import asyncio
import json
import re

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from app.rexhub import plugin_runtime, plugins_store

router = APIRouter(prefix="/addon", tags=["addon"])

NO_CACHE = {"Cache-Control": "no-cache"}
# Stremio 的 skip 是条目偏移量，按每页 20 条换算成插件使用的 page
CATALOG_PAGE_SIZE = 20


def _load(plugin_id: str) -> tuple[dict, str, dict]:
    row, source = plugins_store.find_with_source(plugin_id)
    if row is None:
        raise HTTPException(status_code=404, detail="插件不存在")
    if not row.get("enabled", True):
        raise HTTPException(status_code=404, detail="插件已停用")
    if not source:
        raise HTTPException(status_code=400, detail="插件源码尚未下载到本地")
    if plugin_runtime.is_encrypted(source):
        raise HTTPException(status_code=422, detail="插件是加密模块，运行时无法执行")
    analysis = plugin_runtime.analysis_of(row, source)
    if not analysis.get("ok"):
        raise HTTPException(status_code=422, detail=str(analysis.get("error") or "插件解析失败"))
    return row, source, analysis


def _execute(row: dict, source: str, analysis: dict, function: str, extra: dict) -> object:
    params = plugin_runtime.build_params(row, analysis, extra)
    return plugin_runtime.run_function(
        source, function, params, proxy=plugin_runtime.plugin_proxy(row)
    )


@router.get("/{plugin_id}/manifest.json")
async def manifest(plugin_id: str) -> JSONResponse:
    row, _, analysis = _load(plugin_id)
    return JSONResponse(
        plugin_runtime.build_manifest(plugin_id, row, analysis), headers=NO_CACHE
    )


@router.get("/{plugin_id}/catalog/{media_type}/{catalog_id}.json")
async def catalog(
    plugin_id: str,
    media_type: str,
    catalog_id: str,
    request: Request,
    page: int = Query(default=1, ge=1),
    search: str | None = Query(default=None),
) -> JSONResponse:
    row, source, analysis = _load(plugin_id)
    modules = plugin_runtime.modules_of(analysis)
    module = next(
        (item for item in modules if str(item.get("id") or item.get("function")) == catalog_id),
        None,
    )
    if catalog_id == "search":
        function = str((analysis.get("search") or {}).get("function") or "")
    elif module is not None:
        function = str(module.get("function") or "")
    else:
        # 未知目录不再回退到搜索，避免返回错数据
        raise HTTPException(status_code=404, detail="目录不存在")
    if not function:
        raise HTTPException(status_code=404, detail="目录不存在")

    extra = {
        key: value for key, value in request.query_params.items() if key not in {"page", "skip"}
    }
    skip = request.query_params.get("skip")
    if skip and "page" not in request.query_params:
        try:
            page = max(0, int(skip)) // CATALOG_PAGE_SIZE + 1
        except ValueError:
            pass
    extra["page"] = page
    keyword = (search or extra.get("keyword") or extra.get("q") or "").strip()
    if keyword:
        extra["keyword"] = keyword
    if catalog_id == "search":
        # 搜索目录按类型分开挂载，插件据此只返回对应类型的条目
        extra["mediaType"] = media_type or "tv"
    try:
        value = await asyncio.to_thread(_execute, row, source, analysis, function, extra)
    except plugin_runtime.PluginRuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse(
        {"metas": plugin_runtime.to_metas(value, default_type=media_type or "tv")},
        headers=NO_CACHE,
    )


@router.get("/{plugin_id}/catalog/{media_type}/{catalog_id}/search={keyword}.json")
async def catalog_search(
    plugin_id: str,
    media_type: str,
    catalog_id: str,
    keyword: str,
    request: Request,
    page: int = Query(default=1, ge=1),
) -> JSONResponse:
    return await catalog(plugin_id, media_type, catalog_id, request, page=page, search=keyword)


@router.get("/{plugin_id}/meta/{media_type}/{item_id}.json")
async def meta(
    plugin_id: str,
    media_type: str,
    item_id: str,
    request: Request,
) -> JSONResponse:
    row, source, analysis = _load(plugin_id)
    module = next(
        (
            item
            for item in plugin_runtime.modules_of(analysis)
            if re.search(r"meta|detail", f"{item.get('id')} {item.get('function')}", re.I)
        ),
        None,
    )
    if module is None:
        raise HTTPException(status_code=404, detail="插件没有详情模块")
    extra = {key: value for key, value in request.query_params.items()}
    extra["id"] = item_id
    try:
        value = await asyncio.to_thread(
            _execute, row, source, analysis, str(module.get("function") or ""), extra
        )
    except plugin_runtime.PluginRuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    metas = plugin_runtime.to_metas(value if isinstance(value, list) else [value])
    if not metas:
        raise HTTPException(status_code=404, detail="未找到详情")
    return JSONResponse({"meta": metas[0]}, headers=NO_CACHE)


@router.get("/{plugin_id}/stream/{media_type}/{item_id}.json")
async def stream(
    plugin_id: str,
    media_type: str,
    item_id: str,
    request: Request,
    episode: int | None = Query(default=None, ge=1),
) -> JSONResponse:
    row, source, analysis = _load(plugin_id)
    module = next(
        (
            item
            for item in plugin_runtime.modules_of(analysis)
            if plugin_runtime.module_kind(item) == "stream"
        ),
        None,
    )
    if module is None:
        raise HTTPException(status_code=404, detail="插件没有播放模块")
    extra = {key: value for key, value in request.query_params.items()}
    extra.update({"id": item_id, "seriesId": item_id, "linkId": item_id})
    if episode:
        extra["episode"] = episode
    try:
        value = await asyncio.to_thread(
            _execute, row, source, analysis, str(module.get("function") or ""), extra
        )
    except plugin_runtime.PluginRuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse({"streams": plugin_runtime.to_streams(value)}, headers=NO_CACHE)
