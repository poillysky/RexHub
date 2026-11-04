"""资源搜索主流程：结果缓存、AV/Bitmagnet 快速通道与通用 SQL 检索。"""


import json
from typing import Any

import app.core.pg as pg
from app.core.region_board_allowlist import normalize_region, region_allowlist_sql
from app.search.av import (
    apply_av_code_boundary_filter,
    build_av_code_continuation_reject,
    build_av_code_ilike_patterns,
    is_uncensored_maker_code,
)
from app.search.constants import (
    MAX_SEARCH_OFFSET,
    normalize_match_mode,
    normalize_sort_type,
    resolve_sort_type_for_query,
)
from app.search.keywords import (
    build_keyword_filter,
    build_relevance_order_by,
    extract_keywords,
)
from app.search.prefer import build_prefer_filter_sql
from app.search.resource_format import (
    FILTERED_CORE_COLS,
    FILTER_META_JOIN,
    HASH_RE,
    PUBLIC_RESOURCE_FILTER,
    format_resources,
)

from . import cache
from .av_union import _av_union_count, _av_union_list, _filter_rows_by_region
from .bm_union import _bitmagnet_union_count, _bitmagnet_union_list
from .browse import resource_by_hash
from .cache import _search_cache_get, _search_cache_set, pg_trgm_available
from .filters import (
    _BM_ARM_ORDER,
    _list_enrich_sql,
    SIZE_FILTERS,
    SORT_SQL,
    TIME_FILTERS,
)


def _page_params(p: int, ps: int) -> tuple[int, int, int]:
    page = max(1, int(p or 1))
    # search pool may request up to 80
    page_size = min(max(int(ps or 10), 1), 80)
    offset = min((page - 1) * page_size, MAX_SEARCH_OFFSET)
    return page, page_size, offset


def _search_count_sql(where_sql: str, *, with_meta: bool) -> str:
    join = FILTER_META_JOIN if with_meta else ""
    return f"""
SELECT COUNT(*)::int AS total_count
FROM ed2k_resources r
{join}
WHERE {where_sql}
"""


def _search_list_sql(where_sql: str, order: str, *, with_meta: bool) -> str:
    """filtered CTE ? LIST_META enrich?with_meta ???? FILTER_META?prefer/count??"""
    join = FILTER_META_JOIN if with_meta else ""
    return f"""
WITH filtered AS (
  SELECT {FILTERED_CORE_COLS}
  FROM ed2k_resources r
  {join}
  WHERE {where_sql}
  ORDER BY {order}
  LIMIT %s OFFSET %s
)
{_list_enrich_sql("filtered")}
"""


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

    page, page_size, offset = _page_params(p, ps)
    mode = normalize_match_mode(match_mode)
    sort_key = resolve_sort_type_for_query(normalize_sort_type(sort_type))
    use_trgm = pg_trgm_available()
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
    kw_sql, kw_params, code_bound = build_keyword_filter(
        kw_items,
        mode,
        full_keyword=full_plain,
        use_trgm=use_trgm,
    )

    time_sql = TIME_FILTERS.get(filter_time, "")
    size_sql = SIZE_FILTERS.get(filter_size, "")

    # count+region ?????????? SQL???????? + ?????
    av_fast = (
        bool(code_bound)
        and mode == "exact"
        and not prefer_sql.strip()
        and not time_sql
        and not size_sql
        and not (count_only and bool(region_sql))
    )

    # AV UNION fast path
    if av_fast and code_bound:
        patterns: list[str] = []
        seen: set[str] = set()
        for ck in code_bound:
            for pat in build_av_code_ilike_patterns(ck):
                if pat not in seen:
                    seen.add(pat)
                    patterns.append(pat)
        reject = (
            build_av_code_continuation_reject(code_bound[0])
            if len(code_bound) == 1
            else None
        )

        if count_only:
            total = _av_union_count(patterns, reject)
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
        # ? region ????????????????
        if resolved_region:
            fetch_limit = min(max(base_fetch * 16, base_fetch + 80), 400)
        else:
            fetch_limit = min(max(base_fetch * 8, base_fetch + 40), 240)
        raw_rows = _av_union_list(
            patterns, reject, fetch_limit=fetch_limit, offset=offset
        )
        # ???????????????????????????????
        window_full = len(raw_rows) >= fetch_limit
        rows = apply_av_code_boundary_filter(raw_rows, code_bound)
        rows = _filter_rows_by_region(
            rows,
            resolved_region,
            include_optional=include_optional_boards,
        )
        has_more = False
        total = 0
        if with_total_count and not resolved_region:
            total = _av_union_count(patterns, reject)
            has_more = offset + min(len(rows), page_size) < total
            rows = rows[:page_size]
        else:
            overflow = len(rows) > page_size
            # ???????/??????????????????
            maybe_more = window_full and len(rows) <= page_size
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

    extra_filters = "\n".join(
        x for x in (time_sql, size_sql) if x
    )

    # Bitmagnet ??????/title ?? ILIKE ? UNION ? LIMIT ? enrich
    # ?? prefer?? count/relevance?? exact-???region ???????
    use_bitmagnet = (
        not prefer_sql.strip()
        and sort_key in _BM_ARM_ORDER
        and not (mode == "exact" and code_bound)
        and not (count_only and bool(region_sql))
    )

    if use_bitmagnet:
        file_sql, file_params, _ = build_keyword_filter(
            kw_items,
            mode,
            full_keyword=full_plain,
            use_trgm=use_trgm and mode == "fuzzy",
            field="filename",
        )
        title_sql, title_params, _ = build_keyword_filter(
            kw_items,
            mode,
            full_keyword=full_plain,
            use_trgm=use_trgm and mode == "fuzzy",
            field="title",
        )

        if count_only:
            try:
                total = _bitmagnet_union_count(
                    file_sql,
                    title_sql,
                    file_params,
                    title_params,
                    extra_filters,
                )
            except Exception as e:
                msg = str(e).lower()
                if use_trgm and ("similarity" in msg or "word_similarity" in msg):
                    cache._trgm_ok = False
                    file_sql, file_params, _ = build_keyword_filter(
                        kw_items, mode, full_keyword=full_plain, field="filename"
                    )
                    title_sql, title_params, _ = build_keyword_filter(
                        kw_items, mode, full_keyword=full_plain, field="title"
                    )
                    total = _bitmagnet_union_count(
                        file_sql,
                        title_sql,
                        file_params,
                        title_params,
                        extra_filters,
                    )
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
        try:
            rows = _bitmagnet_union_list(
                file_sql,
                title_sql,
                file_params,
                title_params,
                extra_filters,
                sort_key=sort_key,
                fetch_limit=fetch_n,
                offset=offset,
            )
        except Exception as e:
            msg = str(e).lower()
            if use_trgm and ("similarity" in msg or "word_similarity" in msg):
                cache._trgm_ok = False
                file_sql, file_params, _ = build_keyword_filter(
                    kw_items, mode, full_keyword=full_plain, field="filename"
                )
                title_sql, title_params, _ = build_keyword_filter(
                    kw_items, mode, full_keyword=full_plain, field="title"
                )
                rows = _bitmagnet_union_list(
                    file_sql,
                    title_sql,
                    file_params,
                    title_params,
                    extra_filters,
                    sort_key=sort_key,
                    fetch_limit=fetch_n,
                    offset=offset,
                )
            else:
                raise

        window_full = len(rows) >= fetch_n
        rows = _filter_rows_by_region(
            rows,
            resolved_region,
            include_optional=include_optional_boards,
        )

        total = 0
        has_more = False
        if with_total_count and not resolved_region:
            total = _bitmagnet_union_count(
                file_sql,
                title_sql,
                file_params,
                title_params,
                extra_filters,
            )
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

    # prefer / count+region / exact-???????? JOIN meta
    where = [
        "TRUE",
        PUBLIC_RESOURCE_FILTER.strip(),
        f"AND ({kw_sql})",
    ]
    params: list[Any] = list(kw_params)
    if prefer_sql:
        where.append(prefer_sql)
    # ???? JOIN meta?region ??? SQL?count ???cn/ck ?????
    if region_sql:
        where.append(region_sql)
    if time_sql:
        where.append(time_sql)
    if size_sql:
        where.append(size_sql)
    where_sql = "\n".join(where)

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
        or sort_key == "count"
        or sort_key == "relevance"
    )

    if count_only:
        count_rows = pg.query(
            _search_count_sql(where_sql, with_meta=need_meta), params
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
        if code_bound
        else base_fetch
    )

    list_sql = _search_list_sql(where_sql, order, with_meta=need_meta)
    try:
        rows = pg.query(list_sql, [*params, *order_params, fetch_n, offset])
    except Exception as e:
        msg = str(e).lower()
        if use_trgm and ("similarity" in msg or "word_similarity" in msg):
            cache._trgm_ok = False
            if sort_key == "relevance":
                order, order_params = build_relevance_order_by(
                    kw_items, full_plain, use_trgm=False
                )
            kw_sql2, kw_params2, _ = build_keyword_filter(
                kw_items, mode, full_keyword=full_plain, use_trgm=False
            )
            where[2] = f"AND ({kw_sql2})"
            where_sql = "\n".join(where)
            list_sql = _search_list_sql(where_sql, order, with_meta=need_meta)
            rows = pg.query(
                list_sql, [*kw_params2, *order_params, fetch_n, offset]
            )
            params = list(kw_params2)
        else:
            raise

    if code_bound:
        rows = apply_av_code_boundary_filter(rows, code_bound)

    total = 0
    has_more = False
    if with_total_count:
        count_rows = pg.query(
            _search_count_sql(where_sql, with_meta=need_meta), params
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
