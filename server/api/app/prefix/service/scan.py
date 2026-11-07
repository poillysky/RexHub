"""前缀目录扫库与构建编排。

两条扫描路径：高选择性前缀走 anchored（PREFIX-% 先行）SQL；
FC2 / 欧美 / 带排除 pattern 的走多 pattern hash CTE。
板区分区在 Python 侧过滤封面，SQL 不限板以便讨论区中文译名。
"""

import logging
import time
from typing import Any

from app.search.av import is_western_studio_prefix
from app.search.constants import escape_ilike
from app.search.resource_format import PUBLIC_RESOURCE_FILTER

from .db import _PREFIX_META_LATERAL, _PREFIX_ROW_SELECT, _query_prefix_scan
from .index import _rows_to_prefix_index
from .params import _active_scan_row_cap, _prefix_result_row_cap
from .patterns import (
    _is_fc2_prefix,
    prefix_exclude_like_patterns,
    prefix_like_patterns,
)
from .posts import _apply_zh_title_boost

log = logging.getLogger(__name__)


def _scan_likes_via_hash_cte(
    needle: str,
    likes: list[str],
    excludes: list[str],
    *,
    region: str | None = None,
) -> dict[str, Any]:
    """多 pattern 走 hash CTE；板区分区在 Python 侧过滤封面，标题可跨板取中文。"""
    from app.core.region_board_allowlist import normalize_region

    if not likes:
        return {"items": [], "matchedRows": 0}

    # region 仅传给 _rows_to_prefix_index 做封面过滤
    _ = normalize_region(region)
    cap = _active_scan_row_cap(for_prefix=needle)
    if _is_fc2_prefix(needle):
        # 多 pattern 时勿再 /2，否则每路过窄丢番号
        per = max(5000, cap // max(1, len(likes)))
    else:
        per = max(800, cap // max(1, len(likes) * 2))

    union_parts: list[str] = []
    params: list[Any] = []
    for pat in likes:
        union_parts.append(
            f"""
  (
    SELECT r.hash
    FROM ed2k_resources r
    WHERE TRUE
    {PUBLIC_RESOURCE_FILTER}
      AND r.filename ILIKE %s ESCAPE '\\'
    LIMIT %s
  )"""
        )
        params.extend([pat, per])
        union_parts.append(
            f"""
  (
    SELECT rs.hash
    FROM resource_sources rs
    WHERE rs.title ILIKE %s ESCAPE '\\'
    LIMIT %s
  )"""
        )
        params.extend([pat, per])

    exclude_sql = ""
    for ex in excludes:
        exclude_sql += """
  AND COALESCE(r.filename, '') NOT ILIKE %s ESCAPE '\\'
  AND COALESCE(rs.title, '') NOT ILIKE %s ESCAPE '\\'"""
        params.extend([ex, ex])

    sql = f"""
WITH hashes AS (
{" UNION ".join(union_parts)}
)
SELECT
{_PREFIX_ROW_SELECT}
FROM hashes h
JOIN ed2k_resources r ON r.hash = h.hash
{_PREFIX_META_LATERAL}
WHERE TRUE
{PUBLIC_RESOURCE_FILTER}
{exclude_sql}
LIMIT %s
"""
    params.append(_prefix_result_row_cap(needle))
    t_sql = time.perf_counter()
    rows = _query_prefix_scan(sql, params)
    sql_ms = (time.perf_counter() - t_sql) * 1000
    t_py = time.perf_counter()
    indexed = _rows_to_prefix_index(needle, rows, region=region)
    indexed = _apply_zh_title_boost(needle, indexed, region=region)
    py_ms = (time.perf_counter() - t_py) * 1000
    log.debug(
        "prefix %s scan sql_ms=%.0f py_ms=%.0f matchedRows=%s items=%s",
        needle,
        sql_ms,
        py_ms,
        int(indexed.get("matchedRows") or 0),
        len(indexed.get("items") or []),
    )
    return indexed


def _scan_prefix_code_index(
    prefix: str, *, region: str | None = None
) -> dict[str, Any]:
    needle = str(prefix or "").strip()
    if not needle:
        return {"items": [], "matchedRows": 0}

    excludes = prefix_exclude_like_patterns(needle)
    use_anchored = (
        not _is_fc2_prefix(needle)
        and not is_western_studio_prefix(needle)
        and not excludes
    )

    if use_anchored:
        # 先扫 PREFIX-%（选择性更高），再补 %PREFIX-% / title，避免整段只有 leading-wildcard。
        # 板区分区在 Python 侧过滤封面；SQL 不限板，便于讨论区中文译名。
        esc = escape_ilike(needle)
        starts = f"{esc}-%"
        contains = f"%{esc}-%"
        cap = _active_scan_row_cap(for_prefix=needle)
        # 装饰前缀标题补扫：半量即可，多数命中已在 starts 桶
        tail = max(400, cap // 2)
        sql = f"""
WITH hashes AS (
  (
    SELECT r.hash
    FROM ed2k_resources r
    WHERE TRUE
    {PUBLIC_RESOURCE_FILTER}
      AND r.filename ILIKE %s ESCAPE '\\'
    LIMIT %s
  )
  UNION
  (
    SELECT r.hash
    FROM ed2k_resources r
    WHERE TRUE
    {PUBLIC_RESOURCE_FILTER}
      AND r.filename ILIKE %s ESCAPE '\\'
      AND r.filename NOT ILIKE %s ESCAPE '\\'
    LIMIT %s
  )
  UNION
  (
    SELECT rs.hash
    FROM resource_sources rs
    WHERE rs.title ILIKE %s ESCAPE '\\'
    LIMIT %s
  )
)
SELECT
{_PREFIX_ROW_SELECT}
FROM hashes h
JOIN ed2k_resources r ON r.hash = h.hash
{_PREFIX_META_LATERAL}
WHERE TRUE
{PUBLIC_RESOURCE_FILTER}
LIMIT %s
"""
        t_sql = time.perf_counter()
        rows = _query_prefix_scan(
            sql,
            [
                starts,
                cap,
                contains,
                starts,
                tail,
                contains,
                tail,
                _prefix_result_row_cap(needle),
            ],
        )
        sql_ms = (time.perf_counter() - t_sql) * 1000
        t_py = time.perf_counter()
        indexed = _rows_to_prefix_index(needle, rows, region=region)
        indexed = _apply_zh_title_boost(needle, indexed, region=region)
        py_ms = (time.perf_counter() - t_py) * 1000
        log.debug(
            "prefix %s scan sql_ms=%.0f py_ms=%.0f matchedRows=%s items=%s",
            needle,
            sql_ms,
            py_ms,
            int(indexed.get("matchedRows") or 0),
            len(indexed.get("items") or []),
        )
        return indexed

    likes = prefix_like_patterns(needle)
    return _scan_likes_via_hash_cte(
        needle, likes, excludes, region=region
    )
