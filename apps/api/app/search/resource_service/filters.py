"""查询过滤与排序的 SQL 片段：时间 / 容量过滤、排序与列表 enrich 模板。"""


from app.search.resource_format import (
    FILTERED_CORE_COLS,
    LIST_META_JOIN,
    RESOURCE_SELECT,
)

# Bitmagnet service.ts?1 week / 1 month / 1 year???? 7/31/365 day?
TIME_FILTERS = {
    "gt-1day": "AND r.created_at > now() - interval '1 day'",
    "gt-7day": "AND r.created_at > now() - interval '1 week'",
    "gt-31day": "AND r.created_at > now() - interval '1 month'",
    "gt-365day": "AND r.created_at > now() - interval '1 year'",
}

# Bitmagnet???? BETWEEN??? inclusive??gt5gb ? >
SIZE_FILTERS = {
    "lt100mb": "AND r.size < 100 * 1024 * 1024::bigint",
    "gt100mb-lt500mb": (
        "AND r.size BETWEEN 100 * 1024 * 1024::bigint "
        "AND 500 * 1024 * 1024::bigint"
    ),
    "gt500mb-lt1gb": (
        "AND r.size BETWEEN 500 * 1024 * 1024::bigint "
        "AND 1024 * 1024 * 1024::bigint"
    ),
    "gt1gb-lt5gb": (
        "AND r.size BETWEEN 1 * 1024 * 1024 * 1024::bigint "
        "AND 5 * 1024 * 1024 * 1024::bigint"
    ),
    "gt5gb": "AND r.size > 5 * 1024 * 1024 * 1024::bigint",
}

SORT_SQL = {
    "default": "r.created_at DESC",
    "size": "r.size DESC NULLS LAST, r.created_at DESC",
    # links_count ?? FILTER_META?????enrich ??? LIST_META ??? links
    "count": "coalesce(rs.links_count, 1) DESC, r.created_at DESC",
    "date": "r.created_at DESC",
}

# Bitmagnet UNION ?????????? rs?
_BM_ARM_ORDER = {
    "default": "r.created_at DESC",
    "date": "r.created_at DESC",
    "size": "r.size DESC NULLS LAST, r.created_at DESC",
}
_BM_OUTER_ORDER = {
    "default": "u.created_at DESC",
    "date": "u.created_at DESC",
    "size": "u.size DESC NULLS LAST, u.created_at DESC",
}

_ILIKE_ESC = "ESCAPE '\\'"


def _list_enrich_sql(from_filtered: str = "filtered") -> str:
    """Bitmagnet?CTE ????? LIST_META?????????"""
    return f"""
SELECT {RESOURCE_SELECT}
FROM {from_filtered} r
{LIST_META_JOIN}
"""
