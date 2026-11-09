"""影视播放辅助接口：插件中心影视类插件 + Stremio addon 片源/字幕聚合与媒体代理。

影视元数据已统一由 MoviePilot 提供，本文件只保留与片源相关的能力：
- ``/streams`` / ``/subtitles``：聚合影视类插件与已启用 addon 的片源、字幕；
- ``/cover-proxy`` / ``/stream-proxy`` / ``/subtitle-proxy``：图片、视频直链、字幕代理。

addon 片源/字幕按 IMDb 编号匹配；调用方需要传 ``imdb``，或直接传 ``tt…`` 形式的 id。
"""


import asyncio
import re
from typing import Any
from urllib.parse import urljoin, urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.rexhub.addons_store import streams as addon_streams
from app.rexhub.addons_store import subtitles as addon_subtitles
from app.rexhub.auth_guard import require_session
from app.core.outbound_http import resolve_proxy_url
from app.core.stream_proxy import is_safe_media_url, proxy_media_stream
from app.rexhub.plugin_framework import dispatcher

router = APIRouter(prefix="/api/media", tags=["media"])

_IMDB_RE = re.compile(r"tt\d{5,12}")
# 插件中心「影视」分组包含的插件分类（片商 studio / 短剧 shortdrama 不参与）
_VIDEO_CATEGORIES = ("video", "resource", "playback", "metadata", "cloud")
_PRIVATE_HOST = re.compile(
    r"^(localhost|0\.|10\.|127\.|169\.254\.|192\.168\."
    r"|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$)"
)
COVER_MAX_BYTES = 8 * 1024 * 1024
SUBTITLE_MAX_BYTES = 4 * 1024 * 1024
_REDIRECT_CODES = (301, 302, 303, 307, 308)
_MAX_REDIRECTS = 3


async def _fetch_capped(
    url: str,
    *,
    headers: dict[str, str],
    timeout: httpx.Timeout,
    max_bytes: int,
    error_detail: str,
) -> tuple[bytes, httpx.Headers]:
    """逐跳校验重定向，并对响应体做大小限制（防 SSRF 与内存打爆）。

    走面板里配置的代理：TMDB 等图床在直连网络下不可达，封面会整片空白。
    """
    current = url
    proxy = resolve_proxy_url()
    client_kwargs: dict[str, Any] = {
        "follow_redirects": False,
        "timeout": timeout,
        "trust_env": False,
    }
    if proxy:
        client_kwargs["proxy"] = proxy
    try:
        client = httpx.AsyncClient(**client_kwargs)
    except (ImportError, ValueError):
        # 代理依赖缺失（如 socks 未安装）时退回直连，别让整条封面链路 500
        client = httpx.AsyncClient(
            follow_redirects=False, timeout=timeout, trust_env=False
        )
    try:
        async with client:
            for _ in range(_MAX_REDIRECTS + 1):
                if not is_safe_media_url(current):
                    raise HTTPException(status_code=400, detail="不支持代理内网地址")
                async with client.stream("GET", current, headers=headers) as resp:
                    if resp.status_code in _REDIRECT_CODES:
                        location = resp.headers.get("location")
                        if not location:
                            raise HTTPException(status_code=502, detail=error_detail)
                        current = urljoin(current, location)
                        continue
                    if resp.status_code >= 400:
                        raise HTTPException(status_code=502, detail=error_detail)
                    buf = bytearray()
                    async for chunk in resp.aiter_bytes():
                        buf.extend(chunk)
                        if len(buf) > max_bytes:
                            raise HTTPException(status_code=413, detail="内容过大")
                    return bytes(buf), resp.headers
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=error_detail) from exc
    raise HTTPException(status_code=502, detail="重定向次数过多")


class MediaStreamItem(BaseModel):
    addon: str = ""
    addonSlug: str = ""
    name: str = ""
    title: str = ""
    url: str = ""
    externalUrl: str = ""
    infoHash: str = ""
    fileIdx: int | None = None
    filename: str = ""
    size: int | None = None
    kind: str = ""
    playable: bool = False


class MediaStreamsResponse(BaseModel):
    streams: list[MediaStreamItem]
    total: int = 0
    addons: int = 0
    reason: str = ""


class MediaSubtitleItem(BaseModel):
    addon: str = ""
    addonSlug: str = ""
    id: str = ""
    url: str = ""
    lang: str = ""
    label: str = ""


class MediaSubtitlesResponse(BaseModel):
    subtitles: list[MediaSubtitleItem]
    total: int = 0
    reason: str = ""


def _imdb_id(raw: str, explicit: str = "") -> str:
    value = str(explicit or "").strip()
    match = _IMDB_RE.search(value) or _IMDB_RE.search(str(raw or ""))
    return match.group(0) if match else ""


def _kind(raw: str, media_type: str) -> str:
    if media_type in ("movie", "series"):
        return media_type
    return "series" if ":tv/" in str(raw or "") else "movie"


@router.get("/streams", response_model=MediaStreamsResponse)
async def media_streams(
    request: Request,
    id: str = Query(..., min_length=1, max_length=120),
    imdb: str = Query("", max_length=32),
    mediaType: str = Query("", max_length=12),
    season: int = Query(0, ge=0, le=99),
    episode: int = Query(0, ge=0, le=999),
    title: str = Query("", max_length=200),
) -> MediaStreamsResponse:
    """聚合影视类插件与已启用 addon 的片源，页面内可直接播放直链。"""
    require_session(request)
    imdb_id = _imdb_id(id, imdb)
    keyword = title.strip() or imdb_id

    async def _from_addons() -> dict[str, Any]:
        if not imdb_id:
            return {
                "streams": [],
                "total": 0,
                "addons": 0,
                "reason": "该条目缺少 IMDb 编号，无法匹配社区片源",
            }
        return await addon_streams.collect(_kind(id, mediaType), imdb_id, season, episode)

    async def _from_plugins() -> dict[str, Any]:
        if not keyword:
            return {"streams": [], "providers": [], "reason": ""}
        return await asyncio.to_thread(
            dispatcher.playable_streams, _VIDEO_CATEGORIES, keyword, timeout=8
        )

    addon_data, plugin_data = await asyncio.gather(_from_addons(), _from_plugins())

    streams: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in list(plugin_data.get("streams") or []) + list(addon_data.get("streams") or []):
        key = item.get("url") or item.get("externalUrl") or item.get("infoHash") or ""
        if not key or key in seen:
            continue
        seen.add(key)
        streams.append(item)

    reasons: list[str] = []
    addon_reason = str(addon_data.get("reason") or "")
    if addon_reason and (not addon_data.get("streams") or not imdb_id):
        reasons.append(addon_reason)
    plugin_reason = str(plugin_data.get("reason") or "")
    if plugin_reason:
        reasons.append(plugin_reason)

    return MediaStreamsResponse(
        streams=streams,
        total=len(streams),
        addons=int(addon_data.get("addons") or 0) + len(plugin_data.get("providers") or []),
        reason="；".join(item for item in reasons if item),
    )


@router.get("/subtitles", response_model=MediaSubtitlesResponse)
async def media_subtitles(
    request: Request,
    id: str = Query(..., min_length=1, max_length=120),
    imdb: str = Query("", max_length=32),
    mediaType: str = Query("", max_length=12),
    season: int = Query(0, ge=0, le=99),
    episode: int = Query(0, ge=0, le=999),
) -> MediaSubtitlesResponse:
    """聚合已启用 addon 的字幕资源。"""
    require_session(request)
    imdb_id = _imdb_id(id, imdb)
    if not imdb_id:
        return MediaSubtitlesResponse(
            subtitles=[], reason="该条目缺少 IMDb 编号，暂无社区字幕"
        )
    data = await addon_subtitles.collect(_kind(id, mediaType), imdb_id, season, episode)
    return MediaSubtitlesResponse(**data)


def _sniff_image_type(raw: bytes) -> str:
    if raw[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "image/webp"
    if raw[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    return ""


COVER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


@router.get("/cover-proxy")
async def media_cover_proxy(
    request: Request,
    url: str = Query(..., min_length=8, max_length=1600),
) -> Response:
    """外链封面代理：部分图床有防盗链，浏览器直连会被拒绝。"""
    require_session(request)
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="仅支持 http(s) 图片地址")
    if _PRIVATE_HOST.match(parsed.hostname or ""):
        raise HTTPException(status_code=400, detail="不支持代理内网地址")

    headers = {
        "User-Agent": COVER_UA,
        "Accept": "image/avif,image/webp,image/*,*/*;q=0.8",
        "Referer": f"{parsed.scheme}://{parsed.netloc}/",
    }
    raw, resp_headers = await _fetch_capped(
        url,
        headers=headers,
        timeout=httpx.Timeout(15.0, read=25.0),
        max_bytes=COVER_MAX_BYTES,
        error_detail="封面拉取失败",
    )
    media_type = (resp_headers.get("content-type") or "").split(";")[0].strip()
    if not media_type.startswith("image/"):
        media_type = _sniff_image_type(raw)
    if not media_type:
        raise HTTPException(status_code=415, detail="该地址不是图片")
    return Response(
        content=raw,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/stream-proxy")
def media_stream_proxy(
    request: Request,
    url: str = Query(..., min_length=8, max_length=1600),
) -> StreamingResponse:
    """视频直链代理：透传 Range，播放器拖进度条依赖 206 响应。"""
    require_session(request)
    return proxy_media_stream(request, url)


def _decode_subtitle(raw: bytes) -> str:
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        try:
            return raw.decode("utf-16")
        except (UnicodeDecodeError, ValueError):
            return ""
    for encoding in ("utf-8-sig", "gb18030", "big5", "latin-1"):
        try:
            return raw.decode(encoding)
        except (UnicodeDecodeError, ValueError):
            continue
    return ""


@router.get("/subtitle-proxy")
async def media_subtitle_proxy(
    request: Request,
    url: str = Query(..., min_length=8, max_length=2000),
) -> Response:
    """字幕代理：下载字幕并把 SRT 转成浏览器 <track> 需要的 WebVTT。"""
    require_session(request)
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="仅支持 http(s) 字幕地址")
    if _PRIVATE_HOST.match(parsed.hostname or ""):
        raise HTTPException(status_code=400, detail="不支持代理内网地址")

    headers = {"User-Agent": "RexHub-Media/1.0", "Accept": "text/vtt, text/plain, */*"}
    raw, _ = await _fetch_capped(
        url,
        headers=headers,
        timeout=httpx.Timeout(20.0, read=30.0),
        max_bytes=SUBTITLE_MAX_BYTES,
        error_detail="字幕拉取失败",
    )
    if raw[:4] == b"PK\x03\x04":
        raise HTTPException(status_code=415, detail="该字幕是压缩包，暂不支持")
    text = _decode_subtitle(raw)
    if not text.strip():
        raise HTTPException(status_code=415, detail="字幕内容无法识别")
    if "Dialogue:" in text and not text.lstrip().upper().startswith("WEBVTT"):
        raise HTTPException(status_code=415, detail="暂不支持 ASS/SSA 字幕")
    return Response(
        content=addon_subtitles.srt_to_vtt(text),
        media_type="text/vtt; charset=utf-8",
        headers={"Cache-Control": "private, max-age=3600"},
    )
