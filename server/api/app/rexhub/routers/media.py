"""影视媒体代理：封面/截图外链代理与视频直链代理。

影视元数据已统一由 MoviePilot 提供；在线片源改由插件中心的 MorePlay 能力提供
（``/api/media/moreplay/streams``）。
"""


import asyncio
import re
from typing import Any
from urllib.parse import urljoin, urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse

from app.rexhub.auth_guard import require_session
from app.core.outbound_http import resolve_proxy_url
from app.core.stream_proxy import is_safe_media_url, proxy_media_stream

router = APIRouter(prefix="/api/media", tags=["media"])

_PRIVATE_HOST = re.compile(
    r"^(localhost|0\.|10\.|127\.|169\.254\.|192\.168\."
    r"|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$)"
)
COVER_MAX_BYTES = 8 * 1024 * 1024
_REDIRECT_CODES = (301, 302, 303, 307, 308)
_MAX_REDIRECTS = 3
# 图床抖动（whatslink 等）会偶发 5xx / 连接重置：GET 幂等，补两次就能吃掉。
_FETCH_ATTEMPTS = 3
_RETRYABLE_STATUS = (408, 425, 429, 500, 502, 503, 504)


class _RetryableFetchError(Exception):
    """上游可重试失败：连接抖动、超时、5xx、限流。"""


async def _fetch_once(
    client: httpx.AsyncClient,
    url: str,
    *,
    headers: dict[str, str],
    max_bytes: int,
    error_detail: str,
) -> tuple[bytes, httpx.Headers]:
    """单次拉取：逐跳校验重定向，并对响应体做大小限制。"""
    current = url
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
                if resp.status_code in _RETRYABLE_STATUS:
                    raise _RetryableFetchError(f"status {resp.status_code}")
                raise HTTPException(status_code=502, detail=error_detail)
            buf = bytearray()
            async for chunk in resp.aiter_bytes():
                buf.extend(chunk)
                if len(buf) > max_bytes:
                    raise HTTPException(status_code=413, detail="内容过大")
            return bytes(buf), resp.headers
    raise HTTPException(status_code=502, detail="重定向次数过多")


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
    上游抖动导致的 5xx / 超时会自动重试，避免预览图偶发缺图。
    """
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

    last_error = ""
    try:
        async with client:
            for attempt in range(_FETCH_ATTEMPTS):
                try:
                    return await _fetch_once(
                        client,
                        url,
                        headers=headers,
                        max_bytes=max_bytes,
                        error_detail=error_detail,
                    )
                except _RetryableFetchError as exc:
                    last_error = str(exc)
                except (httpx.TimeoutException, httpx.TransportError) as exc:
                    last_error = f"{type(exc).__name__}: {exc}"
                if attempt + 1 < _FETCH_ATTEMPTS:
                    await asyncio.sleep(0.25 * (attempt + 1))
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=error_detail) from exc
    raise HTTPException(status_code=502, detail=error_detail) from (
        RuntimeError(last_error) if last_error else None
    )


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
