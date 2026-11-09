"""查询过滤与排序的 SQL 片段：时间 / 容量过滤、排序与列表 enrich 模板。"""


from app.search.resource_format import (
    LIST_META_JOIN,
    RESOURCE_SELECT,
)

# Bitmagnet service.ts 的 1 week / 1 month / 1 year 对应 7/31/365 day
TIME_FILTERS = {
    "gt-1day": "AND r.created_at > now() - interval '1 day'",
    "gt-7day": "AND r.created_at > now() - interval '1 week'",
    "gt-31day": "AND r.created_at > now() - interval '1 month'",
    "gt-365day": "AND r.created_at > now() - interval '1 year'",
}

# Bitmagnet 的大小过滤是 BETWEEN（两端 inclusive）；gt5gb 用 >
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
    # links_count 由 FILTER_META 提供；enrich 后 LIST_META 才有 links
    "count": "coalesce(rs.links_count, 1) DESC, r.created_at DESC",
    "date": "r.created_at DESC",
}

# 单表检索排序（search_string 覆盖文件名+标题）
_BM_ARM_ORDER = {
    "default": "r.created_at DESC",
    "date": "r.created_at DESC",
    "size": "r.size DESC NULLS LAST, r.created_at DESC",
}

_ILIKE_ESC = "ESCAPE '\\'"


def _list_enrich_sql(from_filtered: str = "filtered") -> str:
    """Bitmagnet 的 CTE 结果接 LIST_META 以补齐列表字段。"""
    return f"""
SELECT {RESOURCE_SELECT}
FROM {from_filtered} r
{LIST_META_JOIN}
"""
