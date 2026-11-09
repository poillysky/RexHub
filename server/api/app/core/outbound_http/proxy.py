"""outbound_http 子模块：面板代理 / FlareSolverr 地址解析与出站 httpx 客户端。

地址从 library 配置解析，带 2s TTL 缓存；配置写入经 settings_store
变更钩子立即失效（见文件尾的 register_change_hook）。
"""

import time
from typing import Any
from urllib.parse import urlparse

import httpx

import app.core.settings_store as settings_store


def normalize_proxy_url(raw: str | None) -> str:
    """裸 host:port → http://；非法则空串。"""
    s = str(raw or "").strip()
    if not s:
        return ""
    if "://" not in s:
        s = f"http://{s}"
    s = s.rstrip("/")
    parsed = urlparse(s)
    if parsed.scheme not in ("http", "https", "socks4", "socks5") or not parsed.netloc:
        return ""
    return s


def normalize_flaresolverr_url(raw: str | None) -> str:
    """FlareSolverr 基址，如 http://127.0.0.1:8191（不含 /v1）。"""
    s = str(raw or "").strip()
    if not s:
        return ""
    if "://" not in s:
        s = f"http://{s}"
    s = s.rstrip("/")
    if s.lower().endswith("/v1"):
        s = s[:-3].rstrip("/")
    parsed = urlparse(s)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return ""
    return s


def _library_raw() -> dict[str, Any]:
    raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
    return raw if isinstance(raw, dict) else {}


# `resolve_proxy_url()` / `resolve_flaresolverr_url()` 在**每次 HTTP 请求**
# 前都会被调用，而它们每次都要 `json.loads` 整个 library 配置（~1ms）。
# 返回值是纯字符串，故加 2s TTL 缓存；配置写入经 `settings_store` 变更钩子
# 立即失效（所以保存后无需等 TTL）。
_CFG_TTL_SEC = 2.0
_proxy_cache: tuple[float, str] | None = None
_flare_cache: tuple[float, str] | None = None


def invalidate_outbound_config_cache(key: str | None = None) -> None:
    """清代理 / FlareSolverr 解析缓存（`key` 仅为适配变更钩子签名）。"""
    global _proxy_cache, _flare_cache
    _proxy_cache = None
    _flare_cache = None


settings_store.register_change_hook(invalidate_outbound_config_cache)


def resolve_proxy_url() -> str:
    """仅在面板启用且填写代理时使用；否则直连。"""
    global _proxy_cache
    now = time.monotonic()
    hit = _proxy_cache
    if hit is not None and hit[0] > now:
        return hit[1]
    val = _proxy_url_uncached()
    _proxy_cache = (now + _CFG_TTL_SEC, val)
    return val


def _proxy_url_uncached() -> str:
    raw = _library_raw()
    enabled = raw.get("proxyEnabled")
    if enabled is None:
        enabled = raw.get("proxy_enabled")
    hit = normalize_proxy_url(
        str(raw.get("proxyUrl") or raw.get("proxy_url") or "")
    )
    if hit:
        if enabled is False or enabled == 0 or enabled == "0" or enabled == "false":
            return ""
        return hit
    return ""


def resolve_flaresolverr_url() -> str:
    """面板启用且填写 FlareSolverr 时返回基址；否则空。"""
    global _flare_cache
    now = time.monotonic()
    hit = _flare_cache
    if hit is not None and hit[0] > now:
        return hit[1]
    val = _flaresolverr_url_uncached()
    _flare_cache = (now + _CFG_TTL_SEC, val)
    return val


def _flaresolverr_url_uncached() -> str:
    raw = _library_raw()
    enabled = raw.get("flareSolverrEnabled")
    if enabled is None:
        enabled = raw.get("flare_solverr_enabled")
    hit = normalize_flaresolverr_url(
        str(
            raw.get("flareSolverrUrl")
            or raw.get("flare_solverr_url")
            or raw.get("flaresolverrUrl")
            or ""
        )
    )
    if not hit:
        return ""
    if enabled is False or enabled == 0 or enabled == "0" or enabled == "false":
        return ""
    return hit


def httpx_client(**kwargs: Any) -> httpx.Client:
    """创建出站客户端；面板启用代理才走代理，否则直连。"""
    proxy = resolve_proxy_url()
    opts: dict[str, Any] = {"trust_env": False, "follow_redirects": True}
    opts.update(kwargs)
    if proxy:
        opts["proxy"] = proxy
    return httpx.Client(**opts)
