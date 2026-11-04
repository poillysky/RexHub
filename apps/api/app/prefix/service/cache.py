"""前台查询缓存与对外 API。

模块级 _cache（TTL + 容量上限）为进程级单例；对外提供
list_prefix_resources / covers_for_codes / clear_prefix_cache。
"""

import logging
import time
from typing import Any

from app.core.pg import ResourceDbUnavailable
from app.core.ttl_cache import enforce_max, prune_by_age

from .codes import _std_code_key
from .params import PREFIX_CACHE_MAX, PREFIX_CACHE_TTL_S
from .scan import _scan_prefix_code_index

log = logging.getLogger(__name__)

_cache: dict[str, tuple[float, dict[str, Any]]] = {}


def _cache_key(prefix: str, region: str | None = None) -> str:
    p = str(prefix or "").strip().upper()
    r = str(region or "").strip().lower()
    return f"{p}|{r}" if r else p


def clear_prefix_cache(
    prefix: str | None = None, *, region: str | None = None
) -> None:
    if prefix is None:
        _cache.clear()
        return
    key = _cache_key(prefix, region)
    _cache.pop(key, None)
    # 兼容旧无 region 缓存键
    if region:
        _cache.pop(str(prefix or "").strip().upper(), None)


def _load_cached(
    prefix: str, bust: bool = False, *, region: str | None = None
) -> dict[str, Any]:
    key = _cache_key(prefix, region)
    now = time.time()
    prune_by_age(_cache, PREFIX_CACHE_TTL_S, now=now)
    if bust:
        _cache.pop(key, None)
    hit = _cache.get(key)
    if hit and now - hit[0] < PREFIX_CACHE_TTL_S:
        return hit[1]
    data = _scan_prefix_code_index(prefix, region=region)
    _cache[key] = (now, data)
    enforce_max(_cache, PREFIX_CACHE_MAX)
    return data


def list_prefix_resources(
    prefix: str,
    *,
    limit: int = 60,
    offset: int = 0,
    bust: bool = False,
    region: str | None = None,
) -> dict[str, Any]:
    needle = str(prefix or "").strip()
    if not needle:
        return {"items": [], "total_count": 0, "matched_rows": 0}

    safe_limit = min(max(int(limit or 60), 1), 200)
    safe_offset = max(int(offset or 0), 0)

    try:
        indexed = _load_cached(needle, bust=bust, region=region)
        items = indexed["items"]
        page = [
            {
                "code": it["code"],
                "coverUrl": it.get("coverUrl"),
                "coverUrls": list(it.get("coverUrls") or []),
            }
            for it in items[safe_offset : safe_offset + safe_limit]
        ]
        return {
            "items": page,
            "total_count": len(items),
            "matched_rows": int(indexed.get("matchedRows") or 0),
        }
    except ResourceDbUnavailable:
        raise
    except Exception as err:
        log.exception("list_prefix_resources failed")
        raise RuntimeError(f"Failed to list prefix resources: {err}") from err


def covers_for_codes(
    prefix: str,
    codes: list[str],
    *,
    bust: bool = False,
    region: str | None = None,
) -> dict[str, Any]:
    """为预设番号格批量回填库内封面（无图则空；可按区裁板）。"""
    needle = str(prefix or "").strip()
    wanted = [str(c).strip() for c in (codes or []) if str(c).strip()]
    if not needle or not wanted:
        return {"prefix": needle, "items": []}

    indexed = _load_cached(needle, bust=bust, region=region)
    by_key: dict[str, dict[str, Any]] = {}
    for it in indexed.get("items") or []:
        key = _std_code_key(str(it.get("code") or ""))
        if not key or key in by_key:
            continue
        urls = [u for u in (it.get("coverUrls") or []) if u][:6]
        by_key[key] = {
            "code": it.get("code"),
            "coverUrl": urls[0] if urls else it.get("coverUrl"),
            "coverUrls": urls,
        }

    items: list[dict[str, Any]] = []
    for code in wanted[:200]:
        hit = by_key.get(_std_code_key(code))
        if hit:
            items.append(
                {
                    "code": code,
                    "coverUrl": hit.get("coverUrl"),
                    "coverUrls": list(hit.get("coverUrls") or []),
                }
            )
        else:
            items.append({"code": code, "coverUrl": None, "coverUrls": []})
    return {"prefix": needle, "items": items}
