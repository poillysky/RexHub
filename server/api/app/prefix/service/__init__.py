"""Maker-prefix code index — practical port of sehua-search prefixResources.

原 service.py（单文件）按职责拆分为内聚子模块包；对外公共名一律从本包
re-export，`import app.prefix.service as prefix_service` 的用法不变。

子模块职责（依赖单向、无环）：
- params:   扫库超时 / 行数上限参数管理与调优常量（锁 + override 单例）。
- patterns: 前缀分类（FC2 / 欧美 / 有码风格）与 LIKE / 排除 pattern 构建。
- codes:    番号键归一适配（委托 search_av.std_code_key）。
- covers:   封面挑选、排序与清洗（稳定图床优先，BT 板只补空缺）。
- db:       扫库 SQL 执行器与公共 SQL 片段（statement_timeout 分档）。
- posts:    中文帖评分、番号标题桶与中文题补扫（zh boost）。
- index:    前缀索引构建（扫库行 → 番号条目）。
- scan:     前缀目录扫库与构建编排（anchored / hash CTE 两条路径）。
- cache:    前台查询缓存与对外 API（list / covers / clear）。
"""

from .cache import (
    _cache,
    _cache_key,
    _load_cached,
    clear_prefix_cache,
    covers_for_codes,
    list_prefix_resources,
)
from .covers import BT_BOARD_ROOT_FID_SET
from .params import (
    PREFIX_CACHE_MAX,
    PREFIX_CACHE_TTL_S,
    PREFIX_POSTS_PER_CODE,
    PREFIX_SCAN_ROW_CAP,
    PREFIX_SCAN_ROW_CAP_BUILD,
    PREFIX_SCAN_TIMEOUT,
    PREFIX_SCAN_TIMEOUT_BUILD,
    PREFIX_SOURCES_PER_HASH,
    PREFIX_ZH_BOOST_ENABLED,
    PREFIX_ZH_BOOST_ROW_CAP,
    _active_scan_row_cap,
    _active_scan_timeout,
    _prefix_result_row_cap,
    _scan_row_cap_override,
    _scan_timeout_lock,
    _scan_timeout_override,
)
from .patterns import (
    _is_fc2_prefix,
    prefix_exclude_like_patterns,
    prefix_like_patterns,
)

__all__ = [
    "BT_BOARD_ROOT_FID_SET",
    "PREFIX_CACHE_MAX",
    "PREFIX_CACHE_TTL_S",
    "PREFIX_POSTS_PER_CODE",
    "PREFIX_SCAN_ROW_CAP",
    "PREFIX_SCAN_ROW_CAP_BUILD",
    "PREFIX_SCAN_TIMEOUT",
    "PREFIX_SCAN_TIMEOUT_BUILD",
    "PREFIX_SOURCES_PER_HASH",
    "PREFIX_ZH_BOOST_ENABLED",
    "PREFIX_ZH_BOOST_ROW_CAP",
    "clear_prefix_cache",
    "covers_for_codes",
    "list_prefix_resources",
    "prefix_exclude_like_patterns",
    "prefix_like_patterns",
]
