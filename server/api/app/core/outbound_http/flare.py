"""outbound_http 子模块：FlareSolverr API、共享 session 单飞与过盾请求。"""

import threading
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

import httpx

from .classify import looks_blocked_html
from .clearance import _cookies_to_header, remember_clearance
from .proxy import normalize_flaresolverr_url, resolve_flaresolverr_url, resolve_scrape_proxy_url
from .shared import _host_key, log

_DEFAULT_FLARE_PORT = 8191
# 对齐 MDCS：单共享 session 可闲置较久；负载靠 monitor 回收控制
_SESSION_IDLE_MS = 25 * 60 * 1000
_FLARE_MIN_GAP_MS = 120
_FLARE_BUSY_GAP_MS = 250

_flare_lock = threading.Lock()
_shared_session: dict[str, Any] | None = None  # id, proxyUrl, lastUsedAt
_last_flare_finished_at = 0.0
_flare_queue_depth = 0
_flare_traffic_ok = 0
_flare_traffic_err = 0


def _cookie_domain_for_url(url: str) -> str:
    try:
        host = (urlparse(url).hostname or "").lower().rstrip(".")
    except Exception:
        return ""
    if not host:
        return ""
    parts = host.split(".")
    if len(parts) >= 2:
        return f".{'.'.join(parts[-2:])}"
    return host


def _cookie_header_to_fs_cookies(
    cookie_header: str | None, target_url: str | None = None
) -> list[dict[str, str]] | None:
    raw = str(cookie_header or "").strip()
    if not raw:
        return None
    domain = _cookie_domain_for_url(target_url) if target_url else ""
    out: list[dict[str, str]] = []
    for part in raw.split(";"):
        idx = part.find("=")
        if idx <= 0:
            continue
        name = part[:idx].strip()
        value = part[idx + 1 :].strip()
        if not name:
            continue
        item: dict[str, str] = {"name": name, "value": value}
        if domain:
            item["domain"] = domain
            item["path"] = "/"
        out.append(item)
    return out or None


def _flare_api(flare_base: str, body: dict[str, Any], timeout_ms: int) -> dict[str, Any]:
    endpoint = f"{flare_base.rstrip('/')}/v1"
    with httpx.Client(
        timeout=httpx.Timeout(timeout_ms / 1000 + 2, connect=8.0),
        trust_env=False,
    ) as client:
        r = client.post(endpoint, json=body)
    if r.status_code >= 400:
        raise RuntimeError(f"FlareSolverr HTTP {r.status_code}")
    data = r.json() if r.content else {}
    if not isinstance(data, dict):
        raise RuntimeError("FlareSolverr 响应无效")
    if str(data.get("status") or "").lower() != "ok":
        msg = str(data.get("message") or data.get("status") or "unknown")
        raise RuntimeError(f"FlareSolverr 失败：{msg}")
    return data


def _destroy_session(flare_base: str, session_id: str) -> None:
    sid = str(session_id or "").strip()
    if not sid:
        return
    try:
        # 短超时：卡死的 Chrome 绝不能拖住整条过盾队列
        _flare_api(flare_base, {"cmd": "sessions.destroy", "session": sid}, 1200)
        log.info("flare session destroy %s…", sid[:8])
    except Exception as e:
        log.warning("flare session destroy fail %s…: %s", sid[:8], e)


def _destroy_session_bg(flare_base: str, session_id: str) -> None:
    """后台销毁，不占用 _flare_lock。"""
    sid = str(session_id or "").strip()
    if not sid or not flare_base:
        return
    threading.Thread(
        target=_destroy_session,
        args=(flare_base, sid),
        name=f"flare-destroy-{sid[:8]}",
        daemon=True,
    ).start()


def _note_flare_request(ok: bool) -> None:
    global _flare_traffic_ok, _flare_traffic_err
    if ok:
        _flare_traffic_ok += 1
    else:
        _flare_traffic_err += 1


def get_flare_traffic_stats() -> dict[str, Any]:
    ok = _flare_traffic_ok
    err = _flare_traffic_err
    total = ok + err
    return {
        "ok": ok,
        "err": err,
        "sample": total,
        "errorRate": (err / total) if total else 0.0,
        "queueDepth": _flare_queue_depth,
    }


def get_shared_session_id() -> str | None:
    hit = _shared_session
    return str(hit["id"]) if hit and hit.get("id") else None


def list_flare_sessions(flare_base: str | None = None) -> list[str]:
    base = normalize_flaresolverr_url(flare_base) if flare_base else resolve_flaresolverr_url()
    if not base:
        return []
    data = _flare_api(base, {"cmd": "sessions.list"}, 10000)
    sessions = data.get("sessions") if isinstance(data.get("sessions"), list) else []
    return [str(s).strip() for s in sessions if str(s or "").strip()]


def recycle_flare_sessions(*, keep_owned: bool = False) -> dict[str, Any]:
    """回收 FS Chrome 会话。list/destroy 在锁外，避免卡住拉页。"""
    global _shared_session
    base = resolve_flaresolverr_url()
    if not base:
        return {"destroyed": 0, "kept": None, "sessionsBefore": 0}
    owned = get_shared_session_id()
    try:
        remote = list_flare_sessions(base)
    except Exception:
        remote = [owned] if owned else []
    to_destroy = [
        sid for sid in remote if not (keep_owned and owned and sid == owned)
    ]
    with _flare_lock:
        if not keep_owned:
            _shared_session = None
        elif owned and owned not in remote:
            _shared_session = None
    for sid in to_destroy:
        _destroy_session_bg(base, sid)
    log.info(
        "flare recycle destroyed=%s keepOwned=%s owned=%s",
        len(to_destroy),
        keep_owned,
        (owned or "-")[:8],
    )
    return {
        "destroyed": len(to_destroy),
        "kept": owned if keep_owned else None,
        "sessionsBefore": len(remote),
    }


def release_flare_session(reason: str = "release") -> None:
    """进程退出 / 停机：关掉本进程持有的 shared Chrome。"""
    global _shared_session
    with _flare_lock:
        hit = _shared_session
        _shared_session = None
    if not hit:
        return
    base = resolve_flaresolverr_url()
    if not base:
        return
    log.info("flare session release (%s) %s…", reason, str(hit.get("id") or "")[:8])
    _destroy_session_bg(base, str(hit.get("id") or ""))


def _ensure_shared_session(flare_base: str, proxy_url: str) -> tuple[str, bool]:
    """返回 (session_id, created)。调用方已持有 _flare_lock。"""
    global _shared_session
    now = int(time.time() * 1000)
    hit = _shared_session
    if (
        hit
        and hit.get("proxyUrl") == proxy_url
        and now - int(hit.get("lastUsedAt") or 0) < _SESSION_IDLE_MS
    ):
        hit["lastUsedAt"] = now
        return str(hit["id"]), False
    if hit:
        old = str(hit.get("id") or "")
        _shared_session = None
        if old:
            _destroy_session_bg(flare_base, old)
    # 孤儿清理交给 monitor，勿在锁内同步 destroy/list
    created = _flare_api(flare_base, {"cmd": "sessions.create"}, 20000)
    sid = str(created.get("session") or "").strip()
    if not sid:
        raise RuntimeError("flaresolverr sessions.create empty")
    _shared_session = {
        "id": sid,
        "proxyUrl": proxy_url,
        "lastUsedAt": now,
    }
    log.info("flare session create session=%s…", sid[:8])
    return sid, True


@dataclass
class FlareFetchResult:
    html: str
    final_url: str
    cookie_header: str = ""
    user_agent: str = ""


def flaresolverr_request_full(
    url: str,
    *,
    max_timeout_ms: int = 60000,
    referer: str | None = None,
    cookie: str | None = None,
    use_proxy: bool = True,
    no_session_retry: bool = False,
    wait_in_seconds: int = 0,
) -> FlareFetchResult:
    """过盾：同进程复用 FS session；写回 cf_clearance。全局单飞 + 间隔，保护 FS 负载。"""
    global _shared_session, _flare_queue_depth, _last_flare_finished_at
    base = resolve_flaresolverr_url()
    if not base:
        raise RuntimeError("未启用 FlareSolverr")

    max_timeout = max(10000, int(max_timeout_ms))
    proxy = resolve_scrape_proxy_url() if use_proxy else ""
    wait_s = max(0, min(30, int(wait_in_seconds or 0)))
    host = _host_key(url) or "default"
    pad = (
        min(4000, max(1500, int(max_timeout * 0.15)))
        if no_session_retry
        else min(15000, max(3000, max_timeout))
    )

    def run_once(session_id: str | None, reused: bool) -> FlareFetchResult:
        body: dict[str, Any] = {
            "cmd": "request.get",
            "url": url,
            "maxTimeout": max_timeout,
        }
        if session_id:
            body["session"] = session_id
        if proxy:
            body["proxy"] = {"url": proxy}
        if wait_s > 0:
            body["waitInSeconds"] = wait_s
        cookies = _cookie_header_to_fs_cookies(cookie, url)
        if cookies:
            body["cookies"] = cookies
        if referer:
            body["headers"] = {"Referer": referer}
        t0 = time.time()
        try:
            data = _flare_api(base, body, max_timeout + pad)
            sol = data.get("solution") if isinstance(data.get("solution"), dict) else {}
            html = str(sol.get("response") or "")
            if not html:
                raise RuntimeError("flaresolverr empty response")
            st = sol.get("status")
            if isinstance(st, int) and st >= 400:
                raise RuntimeError(f"flaresolverr target HTTP {st}")
            sol_cookies = sol.get("cookies") if isinstance(sol.get("cookies"), list) else []
            ua = str(sol.get("userAgent") or "").strip()
            final = str(sol.get("url") or url).strip() or url
            remember_clearance(final or url, [c for c in sol_cookies if isinstance(c, dict)], ua)
            ms = int((time.time() - t0) * 1000)
            log.info(
                "flare %s host=%s%s %sms",
                "reuse" if reused else "fresh",
                host,
                f" wait={wait_s}s" if wait_s else "",
                ms,
            )
            if looks_blocked_html(html) and len(html) < 12000:
                raise RuntimeError("FlareSolverr 仍遇 CF 盾")
            if len(html) < 200:
                raise RuntimeError("FlareSolverr 返回页面过短")
            _note_flare_request(True)
            return FlareFetchResult(
                html=html,
                final_url=final,
                cookie_header=_cookies_to_header([c for c in sol_cookies if isinstance(c, dict)]),
                user_agent=ua,
            )
        except Exception:
            _note_flare_request(False)
            raise

    _flare_queue_depth += 1
    try:
        with _flare_lock:
            gap_ms = (
                _FLARE_BUSY_GAP_MS if _flare_queue_depth > 3 else _FLARE_MIN_GAP_MS
            )
            wait = _last_flare_finished_at + gap_ms / 1000.0 - time.time()
            if wait > 0:
                time.sleep(wait)
            try:
                if no_session_retry or wait_s > 0:
                    if wait_s > 0:
                        return run_once(None, False)
                    hit = _shared_session
                    if (
                        hit
                        and hit.get("proxyUrl") == proxy
                        and int(time.time() * 1000)
                        - int(hit.get("lastUsedAt") or 0)
                        < _SESSION_IDLE_MS
                    ):
                        hit["lastUsedAt"] = int(time.time() * 1000)
                        try:
                            return run_once(str(hit["id"]), True)
                        except Exception:
                            pass
                    return run_once(None, False)

                try:
                    sid, created = _ensure_shared_session(base, proxy)
                    try:
                        return run_once(sid, not created)
                    except Exception as e:
                        dead = (_shared_session or {}).get("id") or sid
                        _shared_session = None
                        if dead:
                            _destroy_session_bg(base, str(dead))
                        log.warning(
                            "flare session request fail host=%s → destroy+no-session: %s",
                            host,
                            e,
                        )
                        return run_once(None, False)
                except Exception:
                    return run_once(None, False)
            finally:
                _last_flare_finished_at = time.time()
    finally:
        _flare_queue_depth = max(0, _flare_queue_depth - 1)


def flaresolverr_ping(base_url: str | None = None) -> dict[str, Any]:
    """探测 FlareSolverr 是否可达。"""
    base = normalize_flaresolverr_url(base_url) if base_url is not None else resolve_flaresolverr_url()
    if not base:
        raise RuntimeError("请先填写 FlareSolverr 地址")
    data = _flare_api(base, {"cmd": "sessions.list"}, 10000)
    return {
        "ok": True,
        "version": data.get("version") or data.get("startTimestamp"),
        "sessions": data.get("sessions") if isinstance(data.get("sessions"), list) else [],
    }
