"""扫库超时 / 行数上限等参数管理与调优常量。

模块级可变状态（_scan_timeout_lock + override）为进程级单例：
构建期临时抬高超时/行数上限时，前台查询共用同一份配置。
"""

import threading

from .patterns import _is_fc2_prefix

# 扫库上限：与库内命中对齐的硬顶；构建不得再降（降了会扫漏）
PREFIX_SCAN_ROW_CAP = 20000
# 构建与前台同一上限；速度靠并行 workers，不靠砍行数
PREFIX_SCAN_ROW_CAP_BUILD = PREFIX_SCAN_ROW_CAP
# 前台点进单前缀：20s；一键/全量并行时抬到 BUILD 超时
PREFIX_SCAN_TIMEOUT = "20s"
PREFIX_SCAN_TIMEOUT_BUILD = "90s"
PREFIX_CACHE_TTL_S = 300
PREFIX_CACHE_MAX = 256
# 每番号保留的帖文上限；满时按中文分替换，避免只留最新日文帖
PREFIX_POSTS_PER_CODE = 24
# 同 hash 多源会放大结果行数；1 足够（ORDER BY 已中文优先）
PREFIX_SOURCES_PER_HASH = 1
# 中文补扫：大区全量重建时额外一枪/前缀仍贵，默认关；需要时再开
PREFIX_ZH_BOOST_ROW_CAP = 3000
PREFIX_ZH_BOOST_ENABLED = False

_scan_timeout_lock = threading.Lock()
_scan_timeout_override: str | None = None
_scan_row_cap_override: int | None = None


def _active_scan_timeout() -> str:
    with _scan_timeout_lock:
        return _scan_timeout_override or PREFIX_SCAN_TIMEOUT


def _active_scan_row_cap(*, for_prefix: str | None = None) -> int:
    with _scan_timeout_lock:
        base = int(_scan_row_cap_override or PREFIX_SCAN_ROW_CAP)
    # FC2 体量大且多 pattern 分桶；构建降 cap 会从 ~4800 砍到三千出头
    if for_prefix and _is_fc2_prefix(for_prefix):
        return PREFIX_SCAN_ROW_CAP
    return base


def _prefix_result_row_cap(for_prefix: str | None = None) -> int:
    """最终行数上限；SOURCES=1 时与 ROW_CAP 相同。"""
    return _active_scan_row_cap(for_prefix=for_prefix) * max(
        1, PREFIX_SOURCES_PER_HASH
    )
