"""搜索结果缓存与 pg_trgm 可用性探测。"""


import time
from typing import Any

import app.core.pg as pg

_trgm_ok: bool | None = None
_SEARCH_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
_SEARCH_CACHE_TTL = 30.0
_SEARCH_CACHE_MAX = 64


def _search_cache_get(key: str) -> dict[str, Any] | None:
    hit = _SEARCH_CACHE.get(key)
    if not hit:
        return None
    ts, data = hit
    if time.monotonic() - ts > _SEARCH_CACHE_TTL:
        _SEARCH_CACHE.pop(key, None)
        return None
    return data


def _search_cache_set(key: str, data: dict[str, Any]) -> None:
    if len(_SEARCH_CACHE) >= _SEARCH_CACHE_MAX:
        oldest = min(_SEARCH_CACHE.items(), key=lambda kv: kv[1][0])[0]
        _SEARCH_CACHE.pop(oldest, None)
    _SEARCH_CACHE[key] = (time.monotonic(), data)


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
