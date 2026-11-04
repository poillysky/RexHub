"""Bitmagnet filename / title UNION 检索与封顶计数。"""


from typing import Any

import app.core.pg as pg
from app.search.resource_format import FILTERED_CORE_COLS, PUBLIC_RESOURCE_FILTER

from .filters import _BM_ARM_ORDER, _BM_OUTER_ORDER, _list_enrich_sql

# 搜索 SQL 超时（毫秒）；超时后前端可重试/收窄时间范围
_SEARCH_STATEMENT_TIMEOUT_MS = 8000
# 精确 COUNT 上限：超过则返回 cap（列表不依赖精确总数）
_SEARCH_COUNT_CAP = 1000


def _bitmagnet_union_count(
    file_sql: str,
    title_sql: str,
    file_params: list[Any],
    title_params: list[Any],
    extra_where: str,
) -> int:
    """filename ∪ title 命中数；封顶避免全库 COUNT 拖死。"""
    sql = f"""
SELECT COUNT(*)::int AS total FROM (
  SELECT hash FROM (
    SELECT r.hash FROM ed2k_resources r
    WHERE ({file_sql})
    {PUBLIC_RESOURCE_FILTER}
    {extra_where}
    UNION
    SELECT r.hash FROM resource_sources rs
    JOIN ed2k_resources r ON r.hash = rs.hash
    WHERE ({title_sql})
    {PUBLIC_RESOURCE_FILTER}
    {extra_where}
  ) u
  LIMIT %s
) t
"""
    rows = pg.query(
        sql,
        [*file_params, *title_params, _SEARCH_COUNT_CAP + 1],
        statement_timeout_ms=_SEARCH_STATEMENT_TIMEOUT_MS,
    )
    n = int(rows[0]["total"]) if rows else 0
    return min(n, _SEARCH_COUNT_CAP)


def _bitmagnet_union_list(
    file_sql: str,
    title_sql: str,
    file_params: list[Any],
    title_params: list[Any],
    extra_where: str,
    *,
    sort_key: str,
    fetch_limit: int,
    offset: int,
) -> list[dict[str, Any]]:
    """Bitmagnet?filename ? title ??????

    ???? title????????????????????? SONE-996 ????
    ???????????? title?????
    """
    arm_order = _BM_ARM_ORDER.get(sort_key, _BM_ARM_ORDER["default"])
    outer_order = _BM_OUTER_ORDER.get(sort_key, _BM_OUTER_ORDER["default"])
    arm_limit = min(max(fetch_limit, 40), 240)
    sql = f"""
WITH hits AS (
  (
    SELECT r.hash, r.created_at, r.size FROM ed2k_resources r
    WHERE ({file_sql})
    {PUBLIC_RESOURCE_FILTER}
    {extra_where}
    ORDER BY {arm_order}
    LIMIT %s
  )
  UNION
  (
    SELECT r.hash, r.created_at, r.size FROM resource_sources rs
    JOIN ed2k_resources r ON r.hash = rs.hash
    WHERE ({title_sql})
    {PUBLIC_RESOURCE_FILTER}
    {extra_where}
    ORDER BY {arm_order}
    LIMIT %s
  )
),
uniq AS (
  SELECT hash, MAX(created_at) AS created_at, MAX(size) AS size
  FROM hits GROUP BY hash
),
filtered AS (
  SELECT {FILTERED_CORE_COLS}
  FROM uniq u
  JOIN ed2k_resources r ON r.hash = u.hash
  ORDER BY {outer_order}
  LIMIT %s OFFSET %s
)
{_list_enrich_sql("filtered")}
"""
    return pg.query(
        sql,
        [*file_params, arm_limit, *title_params, arm_limit, fetch_limit, offset],
        statement_timeout_ms=_SEARCH_STATEMENT_TIMEOUT_MS,
    )
