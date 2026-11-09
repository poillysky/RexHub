"""媒体流代理公共实现（P1-1）。

统一处理：URL/重定向 SSRF 校验、Range 透传、响应头白名单、流式转发与资源释放。
调用方只需传入已解析好的直链与必要请求头（例如网盘 Cookie / UA / Referer）。
"""

import ipaddress
import socket
from urllib.parse import urljoin, urlparse

import httpx
from fastapi import HTTPException, Request
from fastapi.responses import StreamingResponse

REDIRECT_LIMIT = 3
REDIRECT_CODES = (301, 302, 303, 307, 308)
ALLOWED_MEDIA_TYPES = (
    "video/",
    "audio/",
    "application/vnd.apple.mpegurl",
    "application/x-mpegurl",
    "application/dash+xml",
    "application/octet-stream",
    "binary/octet-stream",
)
_STRIPPED_HEADERS = ("Cookie", "cookie", "Referer", "referer")


def is_public_host(host: str) -> bool:
    """主机名/IP 必须是公网地址：拦掉内网、回环、链路本地与保留段。"""
    if not host:
        return False
    try:
        return bool(ipaddress.ip_address(host).is_global)
    except ValueError:
        pass
    if host.lower().endswith(".localhost"):
        return False
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except OSError:
        return False
    if not infos:
        return False
    for info in infos:
        ip_text = str(info[4][0]).split("%")[0]
        try:
            if not ipaddress.ip_address(ip_text).is_global:
                return False
        except ValueError:
            return False
    return True


def is_safe_media_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return False
    return is_public_host(parsed.hostname or "")


def open_stream(
    client: httpx.Client,
    url: str,
    headers: dict[str, str],
) -> httpx.Response:
    """手动逐跳跟随重定向，并校验每一跳都是公网 http(s) 地址。"""
    current = url
    for _ in range(REDIRECT_LIMIT + 1):
        if not is_safe_media_url(current):
            raise HTTPException(status_code=400, detail="片源地址不安全")
        resp = client.send(
            client.build_request("GET", current, headers=headers), stream=True
        )
        if resp.status_code in REDIRECT_CODES:
            location = resp.headers.get("location")
            resp.close()
            if not location:
                raise HTTPException(status_code=502, detail="片源重定向地址缺失")
            nxt = urljoin(current, location)
            if not is_safe_media_url(nxt):
                raise HTTPException(status_code=400, detail="片源重定向到不安全地址")
            if urlparse(nxt).hostname != urlparse(current).hostname:
                # 跨域重定向不把网盘 Cookie 带过去
                for key in _STRIPPED_HEADERS:
                    headers.pop(key, None)
            current = nxt
            continue
        return resp
    raise HTTPException(status_code=502, detail="片源重定向次数过多")


def proxy_media_stream(
    request: Request,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    fallback_content_type: str = "",
) -> StreamingResponse:
    """拉取远端音视频流并透传给客户端。"""
    if not is_safe_media_url(url):
        raise HTTPException(status_code=400, detail="片源地址不安全")

    merged = dict(headers or {})
    merged.setdefault("User-Agent", "RexHub-Media/1.0")
    merged.setdefault("Accept", "*/*")
    range_header = request.headers.get("range")
    if range_header:
        merged["Range"] = range_header

    client = httpx.Client(
        follow_redirects=False,
        timeout=httpx.Timeout(20.0, read=120.0),
        trust_env=False,
    )
    try:
        upstream = open_stream(client, url, merged)
    except HTTPException:
        client.close()
        raise
    except httpx.HTTPError as exc:
        client.close()
        raise HTTPException(status_code=502, detail="片源直链拉取失败") from exc

    if upstream.status_code >= 400:
        code = upstream.status_code
        upstream.close()
        client.close()
        if code == 429:
            detail = "片源直链被上游限流（429），请稍后重试或换一条片源"
        elif code in (401, 403):
            detail = f"片源直链需要鉴权或已失效（{code}），可换一条或外部打开"
        else:
            detail = f"片源直链返回 {code}，可能已失效，可换一条或外部打开"
        raise HTTPException(status_code=502, detail=detail)

    content_type = (
        (upstream.headers.get("content-type") or "").split(";")[0].strip().lower()
    )
    if content_type and not content_type.startswith(ALLOWED_MEDIA_TYPES):
        upstream.close()
        client.close()
        raise HTTPException(
            status_code=502,
            detail=f"片源返回的不是音视频流（{content_type}），可外部打开",
        )

    def body():
        try:
            for chunk in upstream.iter_bytes(64 * 1024):
                yield chunk
        finally:
            upstream.close()
            client.close()

    passthrough = {
        "Cache-Control": "private, max-age=0",
        "Accept-Ranges": "bytes",
        "X-Content-Type-Options": "nosniff",
    }
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
    # 部分 CDN 不给类型或返回 octet-stream，按调用方约定兜底为 MP4
    if fallback_content_type and passthrough.get("content-type") in (
        None,
        "",
        "application/octet-stream",
        "binary/octet-stream",
    ):
        passthrough["content-type"] = fallback_content_type

    return StreamingResponse(
        body(), status_code=upstream.status_code, headers=passthrough
    )
