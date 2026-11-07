"""outbound_http 子模块：cf-clearance 凭证存取（内存表 + 磁盘持久化）。"""

import json
import threading
import time
from pathlib import Path
from typing import Any

from app.core.db import data_dir

from .shared import _host_key, log

_DEFAULT_CLEARANCE_TTL_MS = 45 * 60 * 1000
# preferFlare 粘性过久会把越来越多站拖进慢通道；到期后允许再试 curl
_PREFER_FLARE_TTL_MS = 12 * 60 * 1000

_clearance_lock = threading.Lock()
_clearance_by_host: dict[str, dict[str, Any]] = {}
_clearance_loaded = False
_persist_timer: threading.Timer | None = None


def _clearance_store_path() -> Path:
    return data_dir() / "meta" / "cf-clearance.json"


def _ensure_clearance_loaded() -> None:
    global _clearance_loaded
    if _clearance_loaded:
        return
    with _clearance_lock:
        if _clearance_loaded:
            return
        path = _clearance_store_path()
        try:
            if path.is_file():
                raw = json.loads(path.read_text(encoding="utf-8"))
                hosts = raw.get("hosts") if isinstance(raw, dict) else None
                now = int(time.time() * 1000)
                n = 0
                if isinstance(hosts, dict):
                    for host, hit in hosts.items():
                        if not isinstance(hit, dict):
                            continue
                        cookie = str(hit.get("cookieHeader") or "").strip()
                        exp = int(hit.get("expiresAt") or 0)
                        if not cookie or exp <= now:
                            continue
                        _clearance_by_host[str(host).lower()] = {
                            "cookieHeader": cookie,
                            "userAgent": str(hit.get("userAgent") or ""),
                            "expiresAt": exp,
                            "preferFlare": bool(hit.get("preferFlare")),
                        }
                        n += 1
                if n:
                    log.info("loaded %s cf-clearance host(s) from disk", n)
        except Exception as e:
            log.warning("cf-clearance load failed: %s", e)
        _clearance_loaded = True


def _persist_clearance_to_disk() -> None:
    path = _clearance_store_path()
    try:
        now = int(time.time() * 1000)
        hosts: dict[str, Any] = {}
        with _clearance_lock:
            for host, hit in _clearance_by_host.items():
                if int(hit.get("expiresAt") or 0) > now:
                    hosts[host] = hit
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {"updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "hosts": hosts},
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
    except OSError as e:
        log.warning("cf-clearance persist failed: %s", e)


def _schedule_persist_clearance() -> None:
    global _persist_timer
    with _clearance_lock:
        if _persist_timer is not None:
            _persist_timer.cancel()
        _persist_timer = threading.Timer(0.25, _persist_clearance_to_disk)
        _persist_timer.daemon = True
        _persist_timer.start()


def _flush_persist_clearance() -> None:
    global _persist_timer
    with _clearance_lock:
        if _persist_timer is not None:
            _persist_timer.cancel()
            _persist_timer = None
    _persist_clearance_to_disk()


def get_cached_clearance(url: str) -> dict[str, str] | None:
    _ensure_clearance_loaded()
    key = _host_key(url)
    if not key:
        return None
    with _clearance_lock:
        hit = _clearance_by_host.get(key)
        if not hit:
            return None
        now_ms = int(time.time() * 1000)
        if now_ms >= int(hit.get("expiresAt") or 0):
            _clearance_by_host.pop(key, None)
            _schedule_persist_clearance()
            return None
        prefer = bool(hit.get("preferFlare"))
        if prefer:
            at = int(hit.get("preferFlareAt") or 0)
            # 旧数据无时间戳：给一次宽限期后衰减
            if at <= 0:
                hit["preferFlareAt"] = now_ms
                at = now_ms
            if now_ms - at >= int(_PREFER_FLARE_TTL_MS):
                hit["preferFlare"] = False
                hit["preferFlareAt"] = 0
                prefer = False
                _schedule_persist_clearance()
        return {
            "cookieHeader": str(hit.get("cookieHeader") or ""),
            "userAgent": str(hit.get("userAgent") or ""),
            "preferFlare": prefer,
        }


def _cookies_to_header(cookies: list[dict[str, Any]]) -> str:
    mapping: dict[str, str] = {}
    for c in cookies:
        name = str(c.get("name") or "").strip()
        if not name:
            continue
        mapping[name] = str(c.get("value") if c.get("value") is not None else "")
    return "; ".join(f"{k}={v}" for k, v in mapping.items())


def _clearance_expiry(cookies: list[dict[str, Any]]) -> int:
    now = int(time.time() * 1000)
    soonest = now + _DEFAULT_CLEARANCE_TTL_MS
    for c in cookies:
        exp = c.get("expires")
        try:
            exp_n = float(exp)
        except (TypeError, ValueError):
            continue
        if exp_n <= 0:
            continue
        ms = int(exp_n if exp_n > 1e12 else exp_n * 1000)
        if ms <= now:
            continue
        soonest = min(soonest, ms)
    return max(now + 60_000, soonest - 120_000)


def remember_clearance(
    url: str,
    cookies: list[dict[str, Any]],
    user_agent: str,
    *,
    prefer_flare: bool | None = None,
) -> None:
    _ensure_clearance_loaded()
    key = _host_key(url)
    header = _cookies_to_header(cookies)
    if not key or not header:
        return
    with _clearance_lock:
        prev = _clearance_by_host.get(key) or {}
        prefer = (
            bool(prefer_flare)
            if prefer_flare is not None
            else bool(prev.get("preferFlare"))
        )
        now_ms = int(time.time() * 1000)
        prefer_at = int(prev.get("preferFlareAt") or 0)
        if prefer_flare is True:
            prefer_at = now_ms
        elif prefer_flare is False:
            prefer_at = 0
        elif prefer and prefer_at <= 0:
            prefer_at = now_ms
        _clearance_by_host[key] = {
            "cookieHeader": header,
            "userAgent": user_agent or "",
            "expiresAt": _clearance_expiry(cookies),
            "preferFlare": prefer,
            "preferFlareAt": prefer_at if prefer else 0,
        }
    _flush_persist_clearance()


def mark_prefer_flare(url: str, prefer: bool = True) -> None:
    """curl 无法吃下 Flare 凭证时，后续直接走 Flare 会话，避免每次再烧 curl→全量过盾。

    粘性带 TTL（见 get_cached_clearance）：到期后恢复优先 curl，避免跑越久越慢。
    """
    _ensure_clearance_loaded()
    key = _host_key(url)
    if not key:
        return
    with _clearance_lock:
        hit = _clearance_by_host.get(key)
        if not hit:
            return
        now_ms = int(time.time() * 1000)
        want = bool(prefer)
        cur = bool(hit.get("preferFlare"))
        if cur == want and (
            not want or int(hit.get("preferFlareAt") or 0) > 0
        ):
            return
        hit["preferFlare"] = want
        hit["preferFlareAt"] = now_ms if want else 0
    _schedule_persist_clearance()
