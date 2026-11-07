"""资源库单表检索与封顶计数。

`ed2k_resources.search_string` 已包含文件名 + 帖子标题 + 正文，
一表一次扫描即可覆盖原来的 filename ∪ resource_sources.title 两支 UNION，
避免 74 万行 × 2 次全表扫描导致的 8s 超时。

正文也含关键词：只用 search_string 命中会把「合集帖正文提到某人」的
无关资源带出来。因此拆两步：search_string 圈候选（单表快扫），
再 JOIN meta 用 filename/title 精确判定（只跑候选行）。
"""


from typing import Any

import app.core.pg as pg
from app.search.resource_format import (
    FILTERED_CORE_COLS,
    FILTER_META_JOIN,
    LIST_META_JOIN,
    PUBLIC_RESOURCE_FILTER,
    RESOURCE_SELECT,
)

from .filters import _BM_ARM_ORDER, _list_enrich_sql

# 列表 SQL 超时（毫秒）
_SEARCH_STATEMENT_TIMEOUT_MS = 8000
# 计数单独给短超时：列表已拿到就先用，计数失败不拖累整次搜索
_SEARCH_COUNT_TIMEOUT_MS = 2500
# 精确 COUNT 上限：超过则返回 cap（列表不依赖精确总数）
_SEARCH_COUNT_CAP = 1000
# 计数先按候选封顶再精确过滤，候选需多取一些，避免过滤后不足 cap
_COUNT_SCAN_FACTOR = 4
# 中文 ILIKE 在 pg_trgm 下估不出选择率，规划器会走 74 万行并行全表扫描 + 排序；
# 强制按 created_at 索引倒序取够 page 即停（实测 8s+ → 0.1s）。
_ORDERED_PLAN_SETTINGS = {
    "enable_seqscan": "off",
    "enable_bitmapscan": "off",
}


def search_count(
    where_sql: str,
    params: list[Any],
    extra_where: str = "",
    *,
    meta_where: str = "",
    meta_params: list[Any] | None = None,
) -> int:
    """命中数（封顶 1000）；扫到 cap 即停，冷门词最多一次全表扫描。"""
    meta_params = meta_params or []
    if meta_where.strip():
        sql = f"""
WITH cand AS MATERIALIZED (
  SELECT r.hash, r.filename
  FROM ed2k_resources r
  WHERE ({where_sql})
  {PUBLIC_RESOURCE_FILTER}
  {extra_where}
  LIMIT %s
)
SELECT COUNT(*)::int AS total
FROM cand r
{FILTER_META_JOIN}
WHERE ({meta_where})
"""
        args = [*params, _SEARCH_COUNT_CAP * _COUNT_SCAN_FACTOR, *meta_params]
    else:
        sql = f"""
SELECT COUNT(*)::int AS total FROM (
  SELECT 1 FROM ed2k_resources r
  WHERE ({where_sql})
  {PUBLIC_RESOURCE_FILTER}
  {extra_where}
  LIMIT %s
) t
"""
        args = [*params, _SEARCH_COUNT_CAP + 1]
    rows = pg.query(
        sql,
        args,
        statement_timeout_ms=_SEARCH_COUNT_TIMEOUT_MS,
    )
    n = int(rows[0]["total"]) if rows else 0
    return min(n, _SEARCH_COUNT_CAP)


def search_list(
    where_sql: str,
    params: list[Any],
    extra_where: str = "",
    *,
    sort_key: str,
    fetch_limit: int,
    offset: int,
    force_ordered: bool = False,
    meta_where: str = "",
    meta_params: list[Any] | None = None,
    with_total: bool = False,
) -> list[dict[str, Any]]:
    """单表命中列表；排序走 created_at / size 索引，翻页只读窗口内行。

    force_ordered 仅用于中文：本库 pg_trgm 对中文提不出三元组，规划器会退化成
    全表扫描 + 排序；纯 ASCII 查询交给规划器走 gin_trgm 更快。

    meta_where 非空时两阶段：先单表圈候选，再 JOIN meta 精确判定后排序分页。
    with_total 时顺带用 count(*) OVER () 带出总数（排序本来就要物化全部命中，
    窗口计数免费），省掉一次独立的全表计数扫描。
    """
    meta_params = meta_params or []
    order = _BM_ARM_ORDER.get(sort_key, _BM_ARM_ORDER["default"])
    if meta_where.strip():
        total_col = "count(*) OVER () AS __total" if with_total else ""
        outer_extra = ", r.__total" if with_total else ""
        enrich = (
            f"""
SELECT {RESOURCE_SELECT}{outer_extra}
FROM filtered r
{LIST_META_JOIN}
"""
            if with_total
            else _list_enrich_sql("filtered")
        )
        sql = f"""
WITH cand AS MATERIALIZED (
  SELECT {FILTERED_CORE_COLS}
  FROM ed2k_resources r
  WHERE ({where_sql})
  {PUBLIC_RESOURCE_FILTER}
  {extra_where}
),
filtered AS (
  SELECT {FILTERED_CORE_COLS}{', ' + total_col if total_col else ''}
  FROM cand r
  {FILTER_META_JOIN}
  WHERE ({meta_where})
  ORDER BY {order}
  LIMIT %s OFFSET %s
)
{enrich}
"""
        args = [*params, *meta_params, fetch_limit, offset]
        # 候选阶段没有 LIMIT，强制索引序只会白扫一遍
        planner = None
    else:
        # 单表也有窗口计数：排序本就要物化全部命中，count(*) OVER () 免费，
        # 避免 total 落到封顶 1000 的 search_count 上（麻豆传媒 3065 会报成 1000）
        total_col = "count(*) OVER () AS __total" if with_total else ""
        enrich = (
            f"""
SELECT {RESOURCE_SELECT}, r.__total
FROM filtered r
{LIST_META_JOIN}
"""
            if with_total
            else _list_enrich_sql("filtered")
        )
        sql = f"""
WITH filtered AS (
  SELECT {FILTERED_CORE_COLS}{', ' + total_col if total_col else ''}
  FROM ed2k_resources r
  WHERE ({where_sql})
  {PUBLIC_RESOURCE_FILTER}
  {extra_where}
  ORDER BY {order}
  LIMIT %s OFFSET %s
)
{enrich}
"""
        args = [*params, fetch_limit, offset]
        planner = (
            _ORDERED_PLAN_SETTINGS
            if force_ordered and sort_key in {"default", "date"}
            else None
        )
    return pg.query(
        sql,
        args,
        statement_timeout_ms=_SEARCH_STATEMENT_TIMEOUT_MS,
        planner_settings=planner,
    )
