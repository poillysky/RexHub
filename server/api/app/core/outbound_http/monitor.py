"""outbound_http 子模块：FlareSolverr session 监控回收定时器。"""

import threading

from . import flare
from .proxy import resolve_flaresolverr_url
from .shared import log

_FLARE_MONITOR_INTERVAL_MS = 30_000
_FLARE_MAX_SESSIONS_WARN = 1
_FLARE_MAX_SESSIONS_CRITICAL = 2

_flare_monitor_timer: threading.Timer | None = None
_flare_monitor_ticking = False
_flare_monitor_started = False


def _flare_monitor_tick() -> None:
    global _flare_monitor_ticking
    if _flare_monitor_ticking:
        return
    _flare_monitor_ticking = True
    try:
        # 有过盾请求在排队时，本轮不抢回收
        if flare._flare_queue_depth > 0:
            return
        base = resolve_flaresolverr_url()
        if not base:
            return
        try:
            remote = flare.list_flare_sessions(base)
        except Exception as e:
            log.warning("flare-monitor list failed: %s", e)
            return
        owned = flare.get_shared_session_id()
        orphans = [sid for sid in remote if not owned or sid != owned]
        traffic = flare.get_flare_traffic_stats()

        if orphans:
            log.info(
                "flare-monitor orphans=%s total=%s owned=%s → recycle keepOwned",
                len(orphans),
                len(remote),
                (owned or "-")[:8],
            )
            flare.recycle_flare_sessions(keep_owned=True)
            return

        if len(remote) >= _FLARE_MAX_SESSIONS_CRITICAL:
            log.info(
                "flare-monitor critical sessions=%s → recycle keepOwned=false",
                len(remote),
            )
            flare.recycle_flare_sessions(keep_owned=False)
            return

        if len(remote) > _FLARE_MAX_SESSIONS_WARN:
            log.info(
                "flare-monitor warn sessions=%s → recycle keepOwned",
                len(remote),
            )
            flare.recycle_flare_sessions(keep_owned=True)
            return

        if traffic["sample"] >= 5 and float(traffic["errorRate"]) >= 0.55:
            log.info(
                "flare-monitor high errorRate=%.2f sample=%s → recycle keepOwned",
                traffic["errorRate"],
                traffic["sample"],
            )
            flare.recycle_flare_sessions(keep_owned=True)
    except Exception as e:
        log.warning("flare-monitor tick failed: %s", e)
    finally:
        _flare_monitor_ticking = False


def _schedule_flare_monitor() -> None:
    global _flare_monitor_timer
    if not _flare_monitor_started:
        return
    _flare_monitor_timer = threading.Timer(
        _FLARE_MONITOR_INTERVAL_MS / 1000.0, _flare_monitor_loop
    )
    _flare_monitor_timer.daemon = True
    _flare_monitor_timer.start()


def _flare_monitor_loop() -> None:
    _flare_monitor_tick()
    _schedule_flare_monitor()


def start_flare_monitor() -> None:
    """API 启动时开启：定时清孤儿 session、会话数超阈回收。"""
    global _flare_monitor_started
    if _flare_monitor_started:
        return
    _flare_monitor_started = True
    log.info(
        "flare-monitor started interval=%sms warn=%s critical=%s",
        _FLARE_MONITOR_INTERVAL_MS,
        _FLARE_MAX_SESSIONS_WARN,
        _FLARE_MAX_SESSIONS_CRITICAL,
    )
    # 首跳延迟，避开启动尖峰
    t = threading.Timer(8.0, _flare_monitor_loop)
    t.daemon = True
    t.start()


def stop_flare_monitor() -> None:
    global _flare_monitor_started, _flare_monitor_timer
    _flare_monitor_started = False
    if _flare_monitor_timer is not None:
        _flare_monitor_timer.cancel()
        _flare_monitor_timer = None
    flare.release_flare_session("shutdown")
