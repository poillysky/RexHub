"""资源浏览与详情：最新列表、板块/关键词筛选与单条详情。"""


from typing import Any

import app.core.pg as pg
from app.search.constants import MAX_SEARCH_OFFSET, escape_ilike
from app.search.resource_format import (
    FILTERED_CORE_COLS,
    PUBLIC_RESOURCE_FILTER,
    RESOURCE_SELECT,
    SOURCE_META_JOIN,
    format_resource,
    format_resources,
)

from .filters import _ILIKE_ESC, _list_enrich_sql


def _browse_page_params(p: int, ps: int) -> tuple[int, int, int]:
    page = max(1, int(p or 1))
    # 「最新」首屏可一次拉到 500
    page_size = min(max(int(ps or 10), 1), 500)
    offset = min((page - 1) * page_size, MAX_SEARCH_OFFSET)
    return page, page_size, offset


_browse_indexes_ready = False


def _ensure_browse_indexes() -> None:
    """?????? board_fid ??????????"""
    global _browse_indexes_ready
    if _browse_indexes_ready:
        return
    try:
        pg.query(
            "CREATE INDEX IF NOT EXISTS idx_resource_sources_board_fid "
            "ON resource_sources (board_fid)"
        )
    except Exception:
        pass
    _browse_indexes_ready = True


def browse_resources(
    *,
    p: int = 1,
    ps: int = 10,
    link_kind: str | None = None,
    board_fid: str | None = None,
    board: str | None = None,
    board_parent: str | None = None,
    keyword: str | None = None,
    with_total_count: bool = False,
) -> dict[str, Any]:
    """???? / ?????

    ? board_fid ?? resource_sources ???``fid`` ? ``fid:%``??
    ???? COUNT?``ps+1`` ? has_more???? 5?10s ?????
    """
    page, page_size, offset = _browse_page_params(p, ps)
    kind = (link_kind or "").strip()
    link_sql = ""
    if kind == "magnet":
        link_sql = "AND lower(COALESCE(r.ed2k_link, '')) LIKE 'magnet:%%'"
    elif kind == "ed2k":
        link_sql = "AND lower(COALESCE(r.ed2k_link, '')) LIKE 'ed2k://%%'"

    kw = (keyword or "").strip()
    kw_sql = ""
    kw_params: list[Any] = []
    if len(kw) >= 2:
        pat = f"%{escape_ilike(kw)}%"
        kw_sql = (
            f"AND (r.filename ILIKE %s {_ILIKE_ESC} "
            f"OR COALESCE(rs.title, '') ILIKE %s {_ILIKE_ESC})"
        )
        kw_params = [pat, pat]

    fid = (board_fid or "").strip()
    board_name = (board or "").strip()
    parent = (board_parent or "").strip()
    fetch_limit = page_size if with_total_count else page_size + 1

    # ?? ????? board_fid???? fid:%???
    if fid:
        _ensure_browse_indexes()
        # ?? 141 ? 141 + 141:%??? 141:689 ? ?? + ?????
        fid_params: list[Any] = [fid, f"{fid}:%%", *kw_params]
        list_sql = f"""
WITH filtered AS (
  SELECT {FILTERED_CORE_COLS}
  FROM resource_sources rs
  JOIN ed2k_resources r ON r.hash = rs.hash
  WHERE (rs.board_fid = %s OR rs.board_fid LIKE %s)
  {PUBLIC_RESOURCE_FILTER}
  {link_sql}
  {kw_sql}
  ORDER BY r.created_at DESC
  LIMIT %s OFFSET %s
)
{_list_enrich_sql("filtered")}
"""
        rows = pg.query(list_sql, [*fid_params, fetch_limit, offset])
        if with_total_count:
            count_sql = f"""
SELECT COUNT(*)::int AS total_count
FROM resource_sources rs
JOIN ed2k_resources r ON r.hash = rs.hash
WHERE (rs.board_fid = %s OR rs.board_fid LIKE %s)
{PUBLIC_RESOURCE_FILTER}
{link_sql}
{kw_sql}
"""
            total = int(
                (pg.query(count_sql, fid_params) or [{}])[0].get(
                    "total_count", 0
                )
                or 0
            )
            rows = rows[:page_size]
            has_more = offset + len(rows) < total
        else:
            has_more = len(rows) > page_size
            rows = rows[:page_size]
            total = offset + len(rows) + (1 if has_more else 0)
        return {
            "resources": format_resources(rows, prefetch_torrents=False),
            "total_count": total,
            "page": page,
            "page_size": page_size,
            "has_more": has_more,
        }

    # ?? ???????????????????? COUNT???
    where = ["TRUE", PUBLIC_RESOURCE_FILTER.strip()]
    params: list[Any] = []
    if link_sql:
        where.append(link_sql)
    need_meta = bool(board_name or parent or kw_sql)
    if parent:
        where.append(
            "AND (rs.board_name = %s OR rs.board_name LIKE %s OR rs.board_name LIKE %s)"
        )
        params.extend([parent, f"{parent} ? %", f"{parent}-%"])
    elif board_name:
        where.append(
            "AND replace(COALESCE(rs.board_name, ''), '-', ' ? ') = %s"
        )
        params.append(board_name.replace("-", " ? "))
    if kw_sql:
        where.append(kw_sql)
        params.extend(kw_params)

    where_sql = "\n".join(where)

    if need_meta:
        list_sql = f"""
WITH filtered AS (
  SELECT {FILTERED_CORE_COLS}
  FROM resource_sources rs
  JOIN ed2k_resources r ON r.hash = rs.hash
  WHERE {where_sql}
  ORDER BY r.created_at DESC
  LIMIT %s OFFSET %s
)
{_list_enrich_sql("filtered")}
"""
    else:
        list_sql = f"""
WITH filtered AS (
  SELECT {FILTERED_CORE_COLS}
  FROM ed2k_resources r
  WHERE {where_sql}
  ORDER BY r.created_at DESC
  LIMIT %s OFFSET %s
)
{_list_enrich_sql("filtered")}
"""

    rows = pg.query(list_sql, [*params, fetch_limit, offset])
    if with_total_count:
        if need_meta:
            count_sql = f"""
SELECT COUNT(*)::int AS total_count
FROM resource_sources rs
JOIN ed2k_resources r ON r.hash = rs.hash
WHERE {where_sql}
"""
        else:
            count_sql = f"""
SELECT COUNT(*)::int AS total_count
FROM ed2k_resources r
WHERE {where_sql}
"""
        total = int(
            (pg.query(count_sql, params) or [{}])[0].get("total_count", 0) or 0
        )
        rows = rows[:page_size]
        has_more = offset + len(rows) < total
    else:
        has_more = len(rows) > page_size
        rows = rows[:page_size]
        total = offset + len(rows) + (1 if has_more else 0)

    return {
        "resources": format_resources(rows, prefetch_torrents=False),
        "total_count": total,
        "page": page,
        "page_size": page_size,
        "has_more": has_more,
    }


def resource_by_hash(hash_: str) -> dict[str, Any] | None:
    h = (hash_ or "").strip().upper()
    if not h:
        return None
    sql = f"""
SELECT {RESOURCE_SELECT}
FROM ed2k_resources r
{SOURCE_META_JOIN}
WHERE r.hash = %s
{PUBLIC_RESOURCE_FILTER}
LIMIT 1
"""
    rows = pg.query(sql, [h])
    if not rows:
        return None
    # 色花详情不拉外网 .torrent 补文件树（会卡住首屏）；文件列表前端也不再展示
    return format_resource(rows[0], enrich_magnets=False)
