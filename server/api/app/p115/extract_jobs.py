"""115 网盘压缩包解压任务（兼容门面）。

实现已拆分：
- 状态、持久化、配置与任务调度辅助：`app.p115.extract_store`
- 扫描、云端解压、本地兜底等作业逻辑：`app.p115.extract_worker`

本模块只保留现有调用点使用的对外函数。
"""

from __future__ import annotations

from app.p115.extract_store import (  # noqa: F401
    get_config,
    save_config,
    snapshot,
)
from app.p115.extract_worker import (  # noqa: F401
    preview,
    start,
    stop,
)

__all__ = [
    "get_config",
    "save_config",
    "snapshot",
    "preview",
    "start",
    "stop",
]
