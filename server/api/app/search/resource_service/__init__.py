"""资源检索服务：浏览 / 搜索 / 详情的查询编排与结果信封组装。

原 ``resource_service.py`` 按职责拆分为包：
- filters    查询过滤与排序的 SQL 片段（时间 / 容量 / 排序 / enrich 模板）
- cache      搜索结果缓存与 pg_trgm 可用性探测
- browse     最新浏览、板块与关键词筛选、单条详情
- av_union   AV 番号 filename/title UNION 快速通道与地区过滤
- bm_union   Bitmagnet filename/title UNION 检索与封顶计数
- search     搜索主流程编排（缓存、快速通道与通用 SQL 检索）
"""

from .browse import browse_resources, resource_by_hash
from .cache import pg_trgm_available
from .filters import SIZE_FILTERS, SORT_SQL, TIME_FILTERS
from .search import search_resources

__all__ = [
    "SIZE_FILTERS",
    "SORT_SQL",
    "TIME_FILTERS",
    "browse_resources",
    "pg_trgm_available",
    "resource_by_hash",
    "search_resources",
]
