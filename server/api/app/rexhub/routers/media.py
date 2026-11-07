"""影视播放辅助接口：Stremio addon 片源/字幕聚合与媒体代理。

影视元数据已统一由 MoviePilot 提供，本文件只保留与 addon 库相关的能力：
- ``/streams`` / ``/subtitles``：聚合已启用 addon 的片源与字幕；
- ``/cover-proxy`` / ``/stream-proxy`` / ``/subtitle-proxy``：图片、视频直链、字幕代理。

片源/字幕按 IMDb 编号匹配；调用方需要传 ``imdb``，或直接传 ``tt…`` 形式的 id。
"""


import re
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.rexhub.addons_store import streams as addon_streams
from app.rexhub.addons_store import subtitles as addon_subtitles
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/media", tags=["media"])

_IMDB_RE = re.compile(r"tt\d{5,12}")
_PRIVATE_HOST = re.compile(
    r"^(localhost|0\.|10\.|127\.|169\.254\.|192\.168\."
    r"|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$)"
)
COVER_MAX_BYTES = 8 * 1024 * 1024


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
) -> MediaStreamsResponse:
    """聚合已启用 addon 的片源，页面内可直接播放直链。"""
    require_session(request)
    imdb_id = _imdb_id(id, imdb)
    if not imdb_id:
        return MediaStreamsResponse(
            streams=[], reason="该条目缺少 IMDb 编号，无法匹配社区片源"
        )
    data = await addon_streams.collect(_kind(id, mediaType), imdb_id, season, episode)
    return MediaStreamsResponse(**data)


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
    try:
        async with httpx.AsyncClient(
            follow_redirects=True, timeout=httpx.Timeout(15.0, read=25.0)
        ) as client:
            upstream = await client.get(url, headers=headers)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="封面拉取失败") from exc
    if upstream.status_code >= 400:
        raise HTTPException(status_code=502, detail="封面地址返回错误")
    raw = upstream.content
    if len(raw) > COVER_MAX_BYTES:
        raise HTTPException(status_code=413, detail="封面图片过大")
    media_type = (upstream.headers.get("content-type") or "").split(";")[0].strip()
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
async def media_stream_proxy(
    request: Request,
    url: str = Query(..., min_length=8, max_length=1600),
) -> StreamingResponse:
    """视频直链代理：透传 Range，播放器拖进度条依赖 206 响应。"""
    require_session(request)
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="仅支持 http(s) 直链")
    if _PRIVATE_HOST.match(parsed.hostname or ""):
        raise HTTPException(status_code=400, detail="不支持代理内网地址")

    headers = {"User-Agent": "RexHub-Media/1.0", "Accept": "*/*"}
    range_header = request.headers.get("range")
    if range_header:
        headers["Range"] = range_header

    client = httpx.AsyncClient(
        follow_redirects=True, timeout=httpx.Timeout(20.0, read=120.0)
    )
    try:
        upstream = await client.send(
            client.build_request("GET", url, headers=headers), stream=True
        )
    except httpx.HTTPError as exc:
        await client.aclose()
        raise HTTPException(status_code=502, detail="片源直链拉取失败") from exc

    if upstream.status_code >= 400:
        await upstream.aclose()
        await client.aclose()
        code = upstream.status_code
        if code == 429:
            detail = "片源直链被上游限流（429），请稍后重试或换一条片源"
        elif code in (401, 403):
            detail = f"片源直链需要鉴权或已失效（{code}），可换一条或外部打开"
        else:
            detail = f"片源直链返回 {code}，可能已失效，可换一条或外部打开"
        raise HTTPException(status_code=502, detail=detail)
    content_type = (upstream.headers.get("content-type") or "").lower()
    if content_type and not content_type.startswith(
        (
            "video/",
            "audio/",
            "application/vnd.apple.mpegurl",
            "application/x-mpegurl",
            "application/dash+xml",
            "application/octet-stream",
            "binary/octet-stream",
        )
    ):
        await upstream.aclose()
        await client.aclose()
        raise HTTPException(
            status_code=502,
            detail=f"片源返回的不是视频流（{content_type}），可能被跳转到网页，可外部打开",
        )

    async def body():
        try:
            async for chunk in upstream.aiter_bytes(64 * 1024):
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    passthrough = {"Cache-Control": "private, max-age=0", "Accept-Ranges": "bytes"}
    for name in (
        "content-type",
        "content-length",
        "content-range",
        "accept-ranges",
        "etag",
        "last-modified",
    ):
        value = upstream.headers.get(name)
        if value:
            passthrough[name] = value
    return StreamingResponse(
        body(), status_code=upstream.status_code, headers=passthrough
    )


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
    try:
        async with httpx.AsyncClient(
            follow_redirects=True, timeout=httpx.Timeout(20.0, read=30.0)
        ) as client:
            upstream = await client.get(url, headers=headers)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="字幕拉取失败") from exc
    if upstream.status_code >= 400:
        raise HTTPException(status_code=502, detail="字幕地址返回错误")
    raw = upstream.content
    if len(raw) > 4 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="字幕文件过大")
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
