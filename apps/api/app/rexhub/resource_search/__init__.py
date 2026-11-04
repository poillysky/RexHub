"""资源检索：把各资源库统一成「资源名称 + 资源链接」的结果。

检索逻辑按服务的 label（notes / database / name）自动匹配，
新增同类型的数据库服务时无需改代码即可参与搜索。

包内按职责划分：
- constants     检索调优常量（候选池扩容 / 语句超时 / 缓存容量）
- keywords      关键词拆词分级与 SQL 匹配条件构造
- links         资源链接的文件哈希提取（跨库去重标识）
- relevance     Python 侧相关性打分与重排
- metadata      密码提取、元数据整理与结果条目组装
- db_source     Postgres 数据库源检索（bitmagnet / 色花堂）
- cloudsaver    CloudSaver 外部搜索源
- orchestrator  多源并发检索编排与跨库合并
"""

from .cloudsaver import (
    CLOUD_POOL_MAX,
    CLOUD_ROUNDS,
    CLOUDSAVER_TIMEOUT,
    CLOUDSAVER_TOKEN_TTL,
    CLOUD_STATE_MAX,
    PAN115_TYPES,
)
from .constants import (
    BITMAGNET_TIMEOUT_MS,
    CACHE_MAX,
    CACHE_TTL,
    CANDIDATE_GROWTH,
    CONNECT_TIMEOUT,
    MAX_CANDIDATES,
    MAX_TOKENS,
    PAGE_CANDIDATES,
    RESULT_LIMIT,
    STATEMENT_TIMEOUT_MS,
)
from .orchestrator import EXTERNAL_PROVIDERS, PROVIDERS, resolve_provider, search

__all__ = [
    "BITMAGNET_TIMEOUT_MS",
    "CACHE_MAX",
    "CACHE_TTL",
    "CANDIDATE_GROWTH",
    "CONNECT_TIMEOUT",
    "CLOUD_POOL_MAX",
    "CLOUD_ROUNDS",
    "CLOUDSAVER_TIMEOUT",
    "CLOUDSAVER_TOKEN_TTL",
    "CLOUD_STATE_MAX",
    "EXTERNAL_PROVIDERS",
    "MAX_CANDIDATES",
    "MAX_TOKENS",
    "PAGE_CANDIDATES",
    "PAN115_TYPES",
    "PROVIDERS",
    "RESULT_LIMIT",
    "STATEMENT_TIMEOUT_MS",
    "resolve_provider",
    "search",
]
