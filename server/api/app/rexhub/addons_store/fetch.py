"""上游拉取：仓库 / manifest / addon 代理转发的 HTTP 获取与限额。"""

import json
import urllib.error
import urllib.request
from typing import Any

from app.rexhub import network_store

FETCH_TIMEOUT = 20
MAX_REPO_BYTES = 8 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_PROXY_BYTES = 8 * 1024 * 1024
USER_AGENT = "RexHub-Stremio/1.0"


class UpstreamError(Exception):
    """上游 addon 请求失败，路由层转成 502。"""


def _fetch_json(url: str, limit: int) -> object:
    request = urllib.request.Request(
        network_store.rewrite_github(url),
        headers={"User-Agent": USER_AGENT, "Accept": "application/json, */*"},
    )
    try:
        try:
            with network_store.open_url(request, FETCH_TIMEOUT, "plugins") as response:
                raw = response.read(limit + 1)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if not network_store.proxy_in_use("plugins"):
                raise
            # 部分站点经代理会 TLS 握手失败，直连重试一次
            with network_store.open_direct(request, FETCH_TIMEOUT) as response:
                raw = response.read(limit + 1)
    except urllib.error.HTTPError as exc:
        raise ValueError(f"地址返回 HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ValueError("无法访问地址，请检查网络或代理") from exc
    if len(raw) > limit:
        raise ValueError("返回内容超过大小限制")
    head = raw[:200].lstrip().lower()
    if head.startswith((b"<!doctype", b"<html")):
        raise ValueError("该地址是网页而不是 addon 数据，请填写仓库 JSON 或 addon 的 manifest.json 地址")
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError as exc:
        raise ValueError("返回内容不是合法 JSON") from exc


def proxy_get(row: dict[str, Any], path: str, query: str = "") -> tuple[int, object]:
    """把 /stremio/{slug}/{path} 转发到 addon 的 transport 地址。"""
    clean = (path or "").lstrip("/")
    if not clean or clean.startswith("//") or ".." in clean or "://" in clean:
        raise UpstreamError("非法的 addon 路径")
    if not clean.endswith(".json"):
        raise UpstreamError("addon 路径必须以 .json 结尾")
    base = str(row.get("transport") or "").rstrip("/")
    url = f"{base}/{clean}"
    if query:
        url = f"{url}?{query}"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json, */*"},
    )
    try:
        try:
            with network_store.open_url(request, FETCH_TIMEOUT, "plugins") as response:
                status = int(getattr(response, "status", None) or response.getcode() or 200)
                raw = response.read(MAX_PROXY_BYTES + 1)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if not network_store.proxy_in_use("plugins"):
                raise
            # 代理握手失败时直连重试
            with network_store.open_direct(request, FETCH_TIMEOUT) as response:
                status = int(getattr(response, "status", None) or response.getcode() or 200)
                raw = response.read(MAX_PROXY_BYTES + 1)
    except urllib.error.HTTPError as exc:
        status = int(exc.code)
        raw = exc.read(MAX_PROXY_BYTES + 1)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise UpstreamError("无法连接 addon 上游") from exc
    if len(raw) > MAX_PROXY_BYTES:
        raise UpstreamError("上游返回内容过大")
    try:
        return status, json.loads(raw.decode("utf-8", "replace"))
    except ValueError as exc:
        raise UpstreamError(f"上游返回 HTTP {status}，且不是合法 JSON") from exc
