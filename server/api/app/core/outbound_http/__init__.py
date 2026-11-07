"""出站 HTTP：curl-impersonate + 面板代理 + FlareSolverr（对齐 MDCS）。

包结构（自底向上依赖，禁止反向 import，避免循环）：
    shared    跨职责底层工具与进程内状态（统一 logger、_host_key、
              cookie 合并、软门 cookie 缓存、旧 host 闸兼容状态）
    tls       线程级超时 / 取消令牌 / 过盾开关上下文（threading.local）
    slots     单源「等槽预算」source_queue_budget 与详情页槽 _page_slot
    proxy     面板代理 / FlareSolverr 地址解析（2s TTL 缓存 + 变更钩子）
              与 httpx 客户端工厂
    classify  风控拦截页 / R18 软门 HTML 判定与 access 模式归一
    clearance cf-clearance 凭证存取（内存表 + 磁盘持久化 + preferFlare 粘性）
    flare     FlareSolverr API、共享 session 单飞与过盾请求
    monitor   FlareSolverr session 监控回收定时器（start/stop_flare_monitor）
    client    对外拉页入口 fetch_page（curl → clearance → Flare 阶梯）

可变模块级状态（slot 深度、session 表、监控器标志等）只在其定义模块内
经 `global` 变更；跨模块读取一律 `from . import x` 后 `x.attr` 访问，
保证单例唯一、行为与拆包前完全一致。所有原公共名从本包 re-export，
调用方 `from app.core.outbound_http import X` 导入路径不变。
"""

from .shared import log, merge_cookie_headers  # noqa: F401
from .tls import (  # noqa: F401
    set_thread_allow_flare,
    set_thread_slot_meter,
    thread_allow_flare,
    thread_cancel_event,
    thread_is_cancelled,
    thread_request_timeout,
)
from .slots import source_queue_budget  # noqa: F401
from .proxy import (  # noqa: F401
    httpx_client,
    invalidate_outbound_config_cache,
    normalize_flaresolverr_url,
    normalize_proxy_url,
    resolve_flaresolverr_url,
    resolve_scrape_proxy_url,
)
from .classify import (  # noqa: F401
    extract_safeid,
    is_r18_safe_shell,
    looks_blocked_html,
    normalize_access,
)
from .clearance import (  # noqa: F401
    get_cached_clearance,
    mark_prefer_flare,
    remember_clearance,
)
from .flare import (  # noqa: F401
    FlareFetchResult,
    flaresolverr_ping,
    flaresolverr_request_full,
    get_flare_traffic_stats,
    get_shared_session_id,
    list_flare_sessions,
    recycle_flare_sessions,
    release_flare_session,
)
from .monitor import start_flare_monitor, stop_flare_monitor  # noqa: F401
from .client import FetchPageResult, decode_html_bytes, fetch_page  # noqa: F401
