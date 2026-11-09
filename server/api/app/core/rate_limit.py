"""进程内滑动窗口限流。

单实例部署够用；多副本部署应换成 Redis 或网关层限流。
key 通常是「作用域 + 客户端 IP」，只保留最近一个窗口内的命中时间。
"""

from __future__ import annotations

import threading
import time
from collections import deque

_lock = threading.Lock()
_windows: dict[tuple[str, str], deque[float]] = {}
_last_sweep = 0.0

# 所有窗口都不超过 10 分钟，超过该时长没命中的桶可以直接丢弃
_SWEEP_EVERY_S = 300.0
_STALE_S = 600.0


def allow(scope: str, key: str, *, limit: int, window_s: float) -> bool:
    """窗口内未超限则记录本次命中并返回 True；超限返回 False（不记录）。"""
    now = time.monotonic()
    with _lock:
        _sweep(now)
        bucket = _windows.setdefault((scope, key), deque())
        while bucket and now - bucket[0] >= window_s:
            bucket.popleft()
        if len(bucket) >= limit:
            return False
        bucket.append(now)
        return True


def _sweep(now: float) -> None:
    global _last_sweep
    if now - _last_sweep < _SWEEP_EVERY_S:
        return
    _last_sweep = now
    stale = [k for k, q in _windows.items() if not q or now - q[-1] > _STALE_S]
    for key in stale:
        _windows.pop(key, None)
