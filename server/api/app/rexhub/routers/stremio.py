"""Stremio addon 接口。

管理台接入的第三方 addon：manifest 走本地缓存，其余请求透传到 addon 的
transport 地址。Stremio 客户端要求 CORS，所有响应都带
``Access-Control-Allow-Origin``。
"""


import asyncio

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from app.rexhub import addons_store

router = APIRouter(prefix="/stremio", tags=["stremio"])

NO_CACHE = {"Cache-Control": "no-cache"}
CORS = {"Access-Control-Allow-Origin": "*"}


def _json(payload: object, status: int = 200) -> JSONResponse:
    return JSONResponse(payload, status_code=status, headers={**NO_CACHE, **CORS})


def _error(status: int, message: str) -> JSONResponse:
    return _json({"error": message}, status)


async def _proxy(slug: str, path: str, query: str = "") -> JSONResponse:
    row = addons_store.find_by_slug(slug)
    if row is None:
        return _error(404, "addon 不存在或已停用")
    try:
        status, payload = await asyncio.to_thread(
            addons_store.proxy_get, row, path, query
        )
    except addons_store.UpstreamError as exc:
        return _error(502, str(exc))
    return _json(payload, status)


@router.get("/{slug}/manifest.json")
async def manifest(slug: str) -> JSONResponse:
    row = addons_store.find_by_slug(slug)
    if row is None:
        return _error(404, "addon 不存在或已停用")
    return _json(row["manifest"])


@router.get("/{slug}/catalog/{media_type}/{catalog_id}.json")
async def catalog(slug: str, media_type: str, catalog_id: str, request: Request) -> JSONResponse:
    return await _proxy(
        slug, f"catalog/{media_type}/{catalog_id}.json", request.url.query
    )


@router.get("/{slug}/catalog/{media_type}/{catalog_id}/{extra}.json")
async def catalog_extra(
    slug: str, media_type: str, catalog_id: str, extra: str
) -> JSONResponse:
    return await _proxy(
        slug, f"catalog/{media_type}/{catalog_id}/{extra}.json", ""
    )


@router.get("/{slug}/meta/{media_type}/{meta_id}.json")
async def meta(slug: str, media_type: str, meta_id: str, request: Request) -> JSONResponse:
    return await _proxy(
        slug, f"meta/{media_type}/{meta_id}.json", request.url.query
    )


@router.get("/{slug}/stream/{media_type}/{video_id}.json")
async def stream(slug: str, media_type: str, video_id: str, request: Request) -> JSONResponse:
    return await _proxy(
        slug, f"stream/{media_type}/{video_id}.json", request.url.query
    )


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
