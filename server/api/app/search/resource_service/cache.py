"""搜索结果缓存与 pg_trgm 可用性探测。"""


import threading
import time
from typing import Any

import app.core.pg as pg

_trgm_ok: bool | None = None
_cjk_bigram_ok: bool | None = None
_SEARCH_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
_SEARCH_CACHE_TTL = 30.0
_SEARCH_CACHE_MAX = 64
_CACHE_LOCK = threading.RLock()


def _search_cache_get(key: str) -> dict[str, Any] | None:
    with _CACHE_LOCK:
        hit = _SEARCH_CACHE.get(key)
        if not hit:
            return None
        ts, data = hit
        if time.monotonic() - ts > _SEARCH_CACHE_TTL:
            _SEARCH_CACHE.pop(key, None)
            return None
        return data


def _search_cache_set(key: str, data: dict[str, Any]) -> None:
    with _CACHE_LOCK:
        if len(_SEARCH_CACHE) >= _SEARCH_CACHE_MAX:
            oldest = min(_SEARCH_CACHE.items(), key=lambda kv: kv[1][0])[0]
            _SEARCH_CACHE.pop(oldest, None)
        _SEARCH_CACHE[key] = (time.monotonic(), data)


def reset_cache_state() -> None:
    """换库后丢弃旧库的探测结果与搜索结果，避免沿用错误的能力判断。"""
    global _trgm_ok, _cjk_bigram_ok
    _trgm_ok = None
    _cjk_bigram_ok = None
    with _CACHE_LOCK:
        _SEARCH_CACHE.clear()


def pg_trgm_available() -> bool:
    global _trgm_ok
    if _trgm_ok is None:
        try:
            rows = pg.query(
                "SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm' LIMIT 1"
            )
            _trgm_ok = bool(rows)
        except Exception:
            _trgm_ok = False
    return _trgm_ok


def cjk_bigram_index_available() -> bool:
    """中文二元组 GIN 是否已就绪（未建库时退回 search_string ILIKE 全扫）。"""
    global _cjk_bigram_ok
    if _cjk_bigram_ok is None:
        try:
            rows = pg.query(
                "SELECT 1 FROM pg_proc WHERE proname = 'cjk_bigrams' LIMIT 1"
            )
            _cjk_bigram_ok = bool(rows)
        except Exception:
            _cjk_bigram_ok = False
    return _cjk_bigram_ok
