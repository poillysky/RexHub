"""outbound_http 子模块：跨职责共享的底层工具与进程内状态。

- 统一日志通道（保持原模块名 `app.core.outbound_http`，日志行为不变）
- `_host_key` / `merge_cookie_headers` 等纯工具
- 非 CF 软门 cookie 的进程内缓存（`_soft_cookies_by_host`）
- 旧版 host 并发闸兼容状态（`_host_gates`，实际详情出站已改走 OutboundScheduler）

被所有上层子模块依赖，自身不依赖任何兄弟模块。
"""

import logging
import re
import threading
from urllib.parse import urlparse

# 保持与拆包前一致的 logger 名，日志输出通道零变化
log = logging.getLogger("app.core.outbound_http")

# 色花堂等域名族（软门识别 / skip-flare 判定共用）
_R18_HOST_HINT_RE = re.compile(r"(?:^|\.)sehuatang\.(?:net|org)$", re.I)

_soft_cookie_lock = threading.Lock()
# host → "safe=1; _safe=…" 等非 CF 软门 cookie（进程内复用）
_soft_cookies_by_host: dict[str, str] = {}

_host_gates: dict[str, threading.Semaphore] = {}


def _host_key(url: str) -> str:
    try:
        return (urlparse(url).hostname or "").lower()
    except Exception:
        return ""


def _sehuatang_like_host(host: str) -> bool:
    h = (host or "").lower().lstrip(".")
    return bool(_R18_HOST_HINT_RE.search(h))


def merge_cookie_headers(*parts: str | None) -> str:
    mapping: dict[str, str] = {}
    for raw in parts:
        for part in str(raw or "").split(";"):
            idx = part.find("=")
            if idx <= 0:
                continue
            name = part[:idx].strip()
            value = part[idx + 1 :].strip()
            if name:
                mapping[name] = value
    return "; ".join(f"{k}={v}" for k, v in mapping.items())


def _remember_soft_cookies(url: str, cookie_header: str) -> None:
    host = _host_key(url)
    header = str(cookie_header or "").strip()
    if not host or not header:
        return
    with _soft_cookie_lock:
        prev = _soft_cookies_by_host.get(host) or ""
        merged = merge_cookie_headers(prev, header)
        if merged:
            _soft_cookies_by_host[host] = merged


def _cached_soft_cookies(url: str) -> str:
    host = _host_key(url)
    if not host:
        return ""
    with _soft_cookie_lock:
        return str(_soft_cookies_by_host.get(host) or "")
