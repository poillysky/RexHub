"""AV 番号 UNION 检索：filename / title 双臂并集与地区内存过滤。"""


from typing import Any

import app.core.pg as pg
from app.core.region_board_allowlist import board_fid_allowed
from app.search.resource_format import FILTERED_CORE_COLS, PUBLIC_RESOURCE_FILTER

from .filters import _ILIKE_ESC, _list_enrich_sql


def _av_union_count(
    patterns: list[str], reject: str | None
) -> int:
    file_or = " OR ".join(
        [f"r.filename ILIKE %s {_ILIKE_ESC}"] * len(patterns)
    )
    title_or = " OR ".join(
        [f"rs.title ILIKE %s {_ILIKE_ESC}"] * len(patterns)
    )
    file_reject = " AND r.filename !~* %s" if reject else ""
    title_reject = " AND rs.title !~* %s" if reject else ""
    sql = f"""
SELECT COUNT(*)::int AS total FROM (
  SELECT r.hash FROM ed2k_resources r
  WHERE ({file_or}){file_reject}
  {PUBLIC_RESOURCE_FILTER}
  UNION
  SELECT r.hash FROM resource_sources rs
  JOIN ed2k_resources r ON r.hash = rs.hash
  WHERE ({title_or}){title_reject}
  {PUBLIC_RESOURCE_FILTER}
) t
"""
    params: list[Any] = [*patterns]
    if reject:
        params.append(reject)
    params.extend(patterns)
    if reject:
        params.append(reject)
    rows = pg.query(sql, params)
    return int(rows[0]["total"]) if rows else 0


def _filter_rows_by_region(
    rows: list[dict[str, Any]],
    region: str | None,
    *,
    include_optional: bool = True,
) -> list[dict[str, Any]]:
    """????????????????? board_fid SQL ?? AV/Bitmagnet??"""
    if not region:
        return rows
    return [
        r
        for r in rows
        if board_fid_allowed(
            r.get("board_fid"), region, include_optional=include_optional
        )
    ]


def _av_union_list(
    patterns: list[str],
    reject: str | None,
    *,
    fetch_limit: int,
    offset: int,
) -> list[dict[str, Any]]:
    file_or = " OR ".join(
        [f"r.filename ILIKE %s {_ILIKE_ESC}"] * len(patterns)
    )
    title_or = " OR ".join(
        [f"rs.title ILIKE %s {_ILIKE_ESC}"] * len(patterns)
    )
    file_reject = " AND r.filename !~* %s" if reject else ""
    title_reject = " AND rs.title !~* %s" if reject else ""
    # ???? 480??? region ???????????
    arm_limit = min(max(fetch_limit + offset, fetch_limit), 480)
    sql = f"""
WITH hits AS (
  (
    SELECT r.hash, r.created_at FROM ed2k_resources r
    WHERE ({file_or}){file_reject}
    {PUBLIC_RESOURCE_FILTER}
    ORDER BY r.created_at DESC
    LIMIT %s
  )
  UNION
  (
    SELECT r.hash, r.created_at FROM resource_sources rs
    JOIN ed2k_resources r ON r.hash = rs.hash
    WHERE ({title_or}){title_reject}
    {PUBLIC_RESOURCE_FILTER}
    ORDER BY r.created_at DESC
    LIMIT %s
  )
),
uniq AS (
  SELECT hash, MAX(created_at) AS created_at FROM hits GROUP BY hash
),
filtered AS (
  SELECT {FILTERED_CORE_COLS}
  FROM uniq u
  JOIN ed2k_resources r ON r.hash = u.hash
  ORDER BY u.created_at DESC
  LIMIT %s OFFSET %s
)
{_list_enrich_sql("filtered")}
"""
    params: list[Any] = [*patterns]
    if reject:
        params.append(reject)
    params.append(arm_limit)
    params.extend(patterns)
    if reject:
        params.append(reject)
    params.extend([arm_limit, fetch_limit, offset])
    return pg.query(sql, params)
