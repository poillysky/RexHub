"""资源搜索主流程：结果缓存、AV/Bitmagnet 快速通道与通用 SQL 检索。"""


import json
from typing import Any

import app.core.pg as pg
from app.core.region_board_allowlist import normalize_region, region_allowlist_sql
from app.search.av import (
    is_av_code_keyword,
    is_uncensored_maker_code,
)
from app.search.constants import (
    MAX_SEARCH_OFFSET,
    normalize_match_mode,
    normalize_sort_type,
    resolve_sort_type_for_query,
)
from app.search.keywords import (
    build_candidate_clause,
    build_cjk_bigram_clause,
    build_keyword_filter,
    build_relevance_order_by,
    extract_keywords,
    has_cjk,
    trgm_usable,
)
from app.search.prefer import build_prefer_filter_sql
from app.search.resource_format import (
    FILTERED_CORE_COLS,
    FILTER_META_JOIN,
    HASH_RE,
    LIST_META_JOIN,
    PUBLIC_RESOURCE_FILTER,
    RESOURCE_SELECT,
    format_resources,
)

from . import cache
from .av_union import _filter_rows_by_region
from .bm_union import search_count, search_list
from .browse import resource_by_hash
from .cache import (
    _search_cache_get,
    _search_cache_set,
    cjk_bigram_index_available,
    pg_trgm_available,
)
from .filters import (
    _BM_ARM_ORDER,
    _list_enrich_sql,
    SIZE_FILTERS,
    SORT_SQL,
    TIME_FILTERS,
)


def _page_params(p: int, ps: int) -> tuple[int, int, int, bool]:
    page = max(1, int(p or 1))
    # search pool may request up to 80
    page_size = min(max(int(ps or 10), 1), 80)
    raw_offset = (page - 1) * page_size
    # 超过深度上限直接收尾：夹住 offset 会让之后的页反复返回同一批数据
    return (
        page,
        page_size,
        min(raw_offset, MAX_SEARCH_OFFSET),
        raw_offset > MAX_SEARCH_OFFSET,
    )


def _search_count_sql(where_sql: str, *, meta_sql: str = "") -> str:
    """meta_sql 依赖 rs.*：先单表筛候选，再 JOIN meta 过滤。

    直接拼在一层会让 LATERAL meta join 对 74 万行逐行执行
    （中文关键词 + 中文字幕偏好实测 31s）。
    """
    if not meta_sql.strip():
        return f"""
SELECT COUNT(*)::int AS total_count
FROM ed2k_resources r
WHERE {where_sql}
"""
    return f"""
WITH cand AS MATERIALIZED (
  SELECT r.hash, r.filename
  FROM ed2k_resources r
  WHERE {where_sql}
)
SELECT COUNT(*)::int AS total_count
FROM cand r
{FILTER_META_JOIN}
WHERE TRUE
{meta_sql}
"""


def _search_list_sql(
    where_sql: str,
    order: str,
    *,
    meta_sql: str = "",
    with_meta: bool = False,
    with_total: bool = False,
) -> str:
    """候选先单表扫（where_sql）；meta 过滤/排序只跑候选行，再 enrich 10 行。

    with_total：排序本就要物化全部命中，顺带 count(*) OVER () 带出总数，
    省掉一次独立的候选全扫（中文查询每次全扫 ~1.5s）。
    """
    if not with_meta:
        return f"""
WITH filtered AS (
  SELECT {FILTERED_CORE_COLS}
  FROM ed2k_resources r
  WHERE {where_sql}
  ORDER BY {order}
  LIMIT %s OFFSET %s
)
{_list_enrich_sql("filtered")}
"""
    total_col = ", count(*) OVER () AS __total" if with_total else ""
    enrich = (
        f"""
SELECT {RESOURCE_SELECT}, r.__total
FROM filtered r
{LIST_META_JOIN}
"""
        if with_total
        else _list_enrich_sql("filtered")
    )
    return f"""
WITH cand AS MATERIALIZED (
  SELECT {FILTERED_CORE_COLS}
  FROM ed2k_resources r
  WHERE {where_sql}
),
filtered AS (
  SELECT {FILTERED_CORE_COLS}{total_col}
  FROM cand r
  {FILTER_META_JOIN}
  WHERE TRUE
  {meta_sql}
  ORDER BY {order}
  LIMIT %s OFFSET %s
)
{enrich}
"""


def _candidate_clause(
    kw: str, kw_items: list[dict[str, Any]], full_plain: str
) -> tuple[str, list[Any]]:
    """中文候选走 cjk_bigrams GIN；索引未就绪时退回 search_string ILIKE（AND 语义）。"""
    if has_cjk(kw):
        if cjk_bigram_index_available():
            return build_cjk_bigram_clause(kw_items, full_plain)
        sql, params, _ = build_keyword_filter(
            kw_items, "exact", full_keyword=full_plain, field="search"
        )
        return sql, params
    return build_candidate_clause(kw_items, full_plain)


def search_resources(
    *,
    keyword: str,
    p: int = 1,
    ps: int = 10,
    sort_type: str = "default",
    filter_time: str = "all",
    filter_size: str = "all",
    match_mode: str = "exact",
    with_total_count: bool = True,
    count_only: bool = False,
    prefer_chinese: bool = False,
    prefer_crack: bool = False,
    japan_censored: bool = False,
    exclude_uncensored: bool | None = None,
    region: str | None = None,
    include_optional_boards: bool = True,
) -> dict[str, Any]:
    kw = (keyword or "").strip()
    if len(kw) < 2:
        raise ValueError("????? 2 ???")

    page, page_size, offset, beyond_cap = _page_params(p, ps)
    mode = normalize_match_mode(match_mode)
    sort_key = resolve_sort_type_for_query(normalize_sort_type(sort_type))
    # 中文在本库 pg_trgm 提不出三元组（similarity 恒 0）；番号走 trigram 会拿 XWJ-0013 之类糊进来
    use_trgm = (
        pg_trgm_available()
        and trgm_usable(kw)
        and not is_av_code_keyword(kw)
    )
    # 中文没有三元组：强制按 created_at 索引倒序取够 page 即停；纯 ASCII 交给 gin_trgm。
    # 但库里有中文二元组 GIN 索引时不能再强制索引序——那会禁掉 bitmapscan，
    # 让中文查询退回「沿 created_at 全量扫 + 过滤」（排序=时间实测 8s 超时且返回空）。
    force_ordered = not trgm_usable(kw) and not (
        has_cjk(kw) and cjk_bigram_index_available()
    )
    full_plain = kw.replace('"', "").strip()

    cache_key = json.dumps(
        {
            "kw": kw,
            "p": page,
            "ps": page_size,
            "sort": sort_type,
            "time": filter_time,
            "size": filter_size,
            "mode": mode,
            "wtc": with_total_count,
            "co": count_only,
            "cn": prefer_chinese,
            "ck": prefer_crack,
            "yc": japan_censored,
            "xu": exclude_uncensored,
            "region": region or "",
            "optb": include_optional_boards,
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    cached = _search_cache_get(cache_key)
    if cached is not None:
        return cached

    def _cached(payload: dict[str, Any]) -> dict[str, Any]:
        _search_cache_set(cache_key, payload)
        return payload

    if HASH_RE.match(kw):
        one = resource_by_hash(kw)
        items = [one] if one else []
        return _cached(
            {
                "keywords": [kw.upper()],
                "resources": [] if count_only else items,
                "total_count": len(items),
                "has_more": False,
                "page": 1,
                "page_size": page_size,
                "match_mode": mode,
            }
        )

    crack = prefer_crack and not is_uncensored_maker_code(kw)
    # ?????????????? AV/Bitmagnet ?????? count ? SQL
    resolved_region = normalize_region(region) or (
        "japan_censored" if japan_censored else None
    )
    prefer_sql = build_prefer_filter_sql(
        prefer_chinese=prefer_chinese,
        prefer_crack=crack,
    )
    region_sql = (
        region_allowlist_sql(
            resolved_region, include_optional=include_optional_boards
        )
        if resolved_region
        else ""
    )
    # ??????region ??? prefer_sql
    del exclude_uncensored

    kw_items = extract_keywords(kw, mode)
    # 统一检索口径：一律以 search_string（文件名+标题+正文）为命中范围，
    # 与时间/大小排序的单表路径保持一致；相关性只影响 ORDER BY 档位，
    # 不再用 filename/title 精判收窄结果集（否则同一关键词切排序结果数会变）。
    cjk_kw = has_cjk(kw)

    if beyond_cap:
        # 翻过深度上限：直接返回空页并收掉 has_more（total 只给下界），
        # 避免 offset 被夹住后无限重复最后一页
        return _cached(
            {
                "keywords": [x["keyword"] for x in kw_items],
                "resources": [],
                "total_count": offset,
                "has_more": False,
                "page": page,
                "page_size": page_size,
                "match_mode": mode,
            }
        )

    time_sql = TIME_FILTERS.get(filter_time, "")
    size_sql = SIZE_FILTERS.get(filter_size, "")

    extra_filters = "\n".join(
        x for x in (time_sql, size_sql) if x
    )

    # search_string 已含文件名/标题/正文：番号也走这条单表快路径（边界正则防 SSIS-0012）
    # 地区/偏好过滤依赖 rs.*：留在单表路径只能「先取一屏再筛」，页码与总数都会失真
    # （实测 三浦歩美 + 日本有码 真实 85 条，却只报 9），故一律走两阶段通用路径。
    use_bitmagnet = (
        not prefer_sql.strip() and not region_sql and sort_key in _BM_ARM_ORDER
    )

    if use_bitmagnet:
        # 中文候选已直接命中 search_string（文件名+标题+正文），无需再精判；
        # 纯 ASCII 下走 trgm 索引 + 边扫边停，同样一次判定。
        if cjk_kw:
            cand_sql, cand_params = _candidate_clause(kw, kw_items, full_plain)
            precise_sql, precise_params = "", []
        else:
            cand_sql, cand_params, _ = build_keyword_filter(
                kw_items,
                mode,
                full_keyword=full_plain,
                field="search",
            )
            precise_sql, precise_params = "", []

        if count_only:
            try:
                total = search_count(
                    cand_sql,
                    cand_params,
                    extra_filters,
                    meta_where=precise_sql,
                    meta_params=precise_params,
                )
            except Exception as e:
                msg = str(e).lower()
                if "timeout" in msg or "canceling statement" in msg:
                    # 计数超时不影响翻页：给下界即可
                    total = offset + page_size
                else:
                    raise
            return _cached(
                {
                    "keywords": [x["keyword"] for x in kw_items],
                    "resources": [],
                    "total_count": total,
                    "has_more": offset + page_size < total,
                    "page": page,
                    "page_size": page_size,
                    "match_mode": mode,
                }
            )

        base_fetch = page_size if with_total_count else page_size + 1
        fetch_n = (
            min(max(base_fetch * 8, base_fetch + 40), 240)
            if resolved_region
            else base_fetch
        )
        need_count = with_total_count and not resolved_region

        rows = search_list(
            cand_sql,
            cand_params,
            extra_filters,
            sort_key=sort_key,
            fetch_limit=fetch_n,
            offset=offset,
            force_ordered=force_ordered,
            meta_where=precise_sql,
            meta_params=precise_params,
            with_total=need_count,
        )
        window_full = len(rows) >= fetch_n
        rows = _filter_rows_by_region(
            rows,
            resolved_region,
            include_optional=include_optional_boards,
        )

        total = 0
        has_more = False
        if need_count:
            # 中文（两阶段）列表已用窗口函数带出总数；ASCII 单表路径没有，需单独计数
            total = int(rows[0]["__total"]) if rows and "__total" in rows[0] else -1
            if total < 0 and not rows and offset == 0 and precise_sql.strip():
                total = 0  # 首页空结果即全库无命中，不必再扫一遍
            elif total < 0:
                # 空页（翻过末页）拿不到窗口计数，退回独立计数
                try:
                    total = search_count(
                        cand_sql,
                        cand_params,
                        extra_filters,
                        meta_where=precise_sql,
                        meta_params=precise_params,
                    )
                except Exception as e:
                    msg = str(e).lower()
                    if "timeout" in msg or "canceling statement" in msg:
                        total = offset + min(len(rows), page_size) + 1
                    else:
                        raise
            has_more = offset + min(len(rows), page_size) < total
            rows = rows[:page_size]
        else:
            overflow = len(rows) > page_size
            maybe_more = bool(resolved_region) and window_full and len(rows) <= page_size
            has_more = overflow or maybe_more
            rows = rows[:page_size]
            total = offset + len(rows) + (1 if has_more else 0)

        return _cached(
            {
                "keywords": [x["keyword"] for x in kw_items],
                "resources": format_resources(rows, prefetch_torrents=False),
                "total_count": total,
                "has_more": has_more,
                "page": page,
                "page_size": page_size,
                "match_mode": mode,
            }
        )

    order_params: list[Any] = []
    if sort_key == "relevance":
        order, order_params = build_relevance_order_by(
            kw_items, full_plain, use_trgm=use_trgm
        )
    else:
        order = SORT_SQL.get(sort_key, SORT_SQL["default"])

    need_meta = (
        bool(prefer_sql.strip())
        or bool(region_sql)
        or sort_key in {"count", "relevance"}
    )

    # 两阶段：prefer/地区/relevance/count 都依赖 rs.*，若与关键词条件拼在同一层，
    # LATERAL meta join 会对 74 万行逐行执行（实测 31s）。先单表按 search_string 收窄，
    # 再 JOIN meta 只做排序/偏好过滤。
    if need_meta:
        # relevance/count/prefer/region 需要 JOIN meta，但命中范围仍按 search_string 判定，
        # 与非 meta 路径完全同一口径（meta 只用于排序与偏好/地区过滤）。
        if cjk_kw:
            cand_sql, cand_params = _candidate_clause(kw, kw_items, full_plain)
        else:
            cand_sql, cand_params, _ = build_keyword_filter(
                kw_items, mode, full_keyword=full_plain, field="search"
            )
        meta_sql = "\n".join(x for x in (prefer_sql, region_sql) if x)
        all_params: list[Any] = [*cand_params]
    else:
        # 纯单表：search_string 覆盖文件名+标题+正文，无需 JOIN
        if cjk_kw:
            cand_sql, cand_params = _candidate_clause(kw, kw_items, full_plain)
        else:
            cand_sql, cand_params, _ = build_keyword_filter(
                kw_items, mode, full_keyword=full_plain, field="search"
            )
        meta_sql = ""
        all_params = [*cand_params]

    where = [
        "TRUE",
        PUBLIC_RESOURCE_FILTER.strip(),
        f"AND ({cand_sql})",
    ]
    if time_sql:
        where.append(time_sql)
    if size_sql:
        where.append(size_sql)
    where_sql = "\n".join(where)

    if count_only:
        count_rows = pg.query(
            _search_count_sql(where_sql, meta_sql=meta_sql), all_params
        )
        total = int(count_rows[0]["total_count"]) if count_rows else 0
        return _cached(
            {
                "keywords": [x["keyword"] for x in kw_items],
                "resources": [],
                "total_count": total,
                "has_more": offset + page_size < total,
                "page": page,
                "page_size": page_size,
                "match_mode": mode,
            }
        )

    base_fetch = page_size if with_total_count else page_size + 1
    fetch_n = (
        min(max(base_fetch * 8, base_fetch + 40), 240)
        if resolved_region
        else base_fetch
    )

    want_win_total = with_total_count and need_meta
    list_sql = _search_list_sql(
        where_sql,
        order,
        meta_sql=meta_sql,
        with_meta=need_meta,
        with_total=want_win_total,
    )
    try:
        rows = pg.query(
            list_sql, [*all_params, *order_params, fetch_n, offset]
        )
    except Exception as e:
        msg = str(e).lower()
        if use_trgm and ("similarity" in msg or "word_similarity" in msg):
            cache._trgm_ok = False
            if sort_key == "relevance":
                order, order_params = build_relevance_order_by(
                    kw_items, full_plain, use_trgm=False
                )
                list_sql = _search_list_sql(
                    where_sql,
                    order,
                    meta_sql=meta_sql,
                    with_meta=need_meta,
                    with_total=want_win_total,
                )
                rows = pg.query(
                    list_sql, [*all_params, *order_params, fetch_n, offset]
                )
            else:
                raise
        else:
            raise

    total = 0
    has_more = False
    if with_total_count:
        total = int(rows[0]["__total"]) if rows and "__total" in rows[0] else -1
        if total < 0 and want_win_total and not rows and offset == 0:
            total = 0  # 首页空结果即全库无命中
        elif total < 0:
            count_rows = pg.query(
                _search_count_sql(where_sql, meta_sql=meta_sql), all_params
            )
            total = int(count_rows[0]["total_count"]) if count_rows else 0
        has_more = offset + min(len(rows), page_size) < total
        rows = rows[:page_size]
    else:
        has_more = len(rows) > page_size
        rows = rows[:page_size]
        total = offset + len(rows) + (1 if has_more else 0)

    return _cached(
        {
            "keywords": [x["keyword"] for x in kw_items],
            "resources": format_resources(rows, prefetch_torrents=False),
            "total_count": total,
            "has_more": has_more,
            "page": page,
            "page_size": page_size,
            "match_mode": mode,
        }
    )
