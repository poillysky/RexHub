"""outbound_http 子模块：线程级超时 / 取消令牌 / 过盾开关上下文。"""

import threading
from typing import Any

_tls = threading.local()


def set_thread_allow_flare(allowed: bool) -> None:
    _tls.allow_flare = bool(allowed)


def thread_allow_flare() -> bool:
    return bool(getattr(_tls, "allow_flare", True))


def thread_request_timeout() -> float | None:
    v = getattr(_tls, "request_timeout", None)
    if v is None:
        return None
    try:
        return max(1.0, float(v))
    except (TypeError, ValueError):
        return None


def thread_cancel_event() -> Any:
    return getattr(_tls, "cancel_event", None)


def thread_is_cancelled() -> bool:
    ev = thread_cancel_event()
    if ev is None:
        return False
    try:
        return bool(ev.is_set())
    except Exception:  # noqa: BLE001
        return False


def set_thread_slot_meter(meter: Any) -> None:
    from app.core.outbound_scheduler import set_thread_slot_meter as _set

    _set(meter)
