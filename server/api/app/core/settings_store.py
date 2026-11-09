
import json
import threading
import time
from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

from app.core import ttl_cache
from app.core.db import connect

RESOURCE_DB_KEY = "resource_db"
BITMAGNET_DB_KEY = "bitmagnet_db"
LIBRARY_KEY = "library"
P115_KEY = "p115"
TMDB_KEY = "tmdb"
FORUM_SEHUATANG_KEY = "forum.sehuatang"
AI_LLM_KEY = "ai.llm"
AI_EMBED_KEY = "ai.embed"
CLOUDSAVER_KEY = "cloudsaver"


# --- 进程内 TTL 缓存 -------------------------------------------------------
# `get_setting` 每次裸开池连接查 app_settings（实测 ~9ms）。它恰好落在**热路径**上：
#   - `resolve_proxy_url()` / `resolve_flaresolverr_url()` 在每次 HTTP 请求
#     前都会被调用，单次 ~10ms；
#   - 抓取路径上每个番号也会高频读取一次设置。
# 缓存的是**原始 JSON 文本**，读时再 `json.loads` 返回一个新对象 —— 语义上等于深拷贝，
# 调用方原地修改不会污染缓存（`_persist_provider_row` 等就有原地写的习惯）。
# `app_settings` 表在全项目只有本文件 `put_setting` 一个写点，
# 因此「写时失效」即可保证本进程永远读到最新；TTL 只兜底跨进程改动。
_SETTING_TTL_SEC = 3.0
_SETTING_CACHE_MAX = 128
_SETTING_CACHE: dict[str, tuple[float, str | None]] = {}
_SETTING_CACHE_LOCK = threading.RLock()


def invalidate_setting_cache(key: str | None = None) -> None:
    """失效缓存；key 为空表示全清（批量改库 / 测试用）。"""
    with _SETTING_CACHE_LOCK:
        if key is None:
            _SETTING_CACHE.clear()
        else:
            _SETTING_CACHE.pop(key, None)


# 派生缓存失效钩子：各模块把自己的缓存清理函数注册进来，配置一改就同步失效。
# 回调异常一律吞掉 —— 缓存失效失败绝不能连带写配置失败。
_CHANGE_HOOKS: list[Any] = []


def register_change_hook(fn: Any) -> None:
    """注册「设置已写入」回调（签名 `fn(key: str) -> None`）。"""
    if fn not in _CHANGE_HOOKS:
        _CHANGE_HOOKS.append(fn)


def get_setting(key: str) -> Any | None:
    now = time.monotonic()
    with _SETTING_CACHE_LOCK:
        cached = _SETTING_CACHE.get(key)
        if cached is not None:
            if cached[0] > now:
                payload = cached[1]
                return json.loads(payload) if payload is not None else None
            _SETTING_CACHE.pop(key, None)

    with connect() as conn:
        row = conn.execute(
            "SELECT value_json FROM app_settings WHERE key = ?",
            (key,),
        ).fetchone()
    payload = str(row["value_json"]) if row else None
    with _SETTING_CACHE_LOCK:
        # 查库期间可能已被 put_setting 失效，写入前再确认一次没有更新的值
        cached = _SETTING_CACHE.get(key)
        if cached is not None and cached[0] > now:
            payload = cached[1]
        else:
            ttl_cache.enforce_max(_SETTING_CACHE, _SETTING_CACHE_MAX - 1)
            _SETTING_CACHE[key] = (now + _SETTING_TTL_SEC, payload)
    if payload is None:
        return None
    return json.loads(payload)


def put_setting(key: str, value: Any) -> dict[str, Any]:
    payload = json.dumps(value, ensure_ascii=False)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO app_settings (key, value_json, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              value_json = excluded.value_json,
              updated_at = excluded.updated_at
            """,
            (key, payload, now),
        )
        conn.commit()
    invalidate_setting_cache(key)
    for hook in list(_CHANGE_HOOKS):
        try:
            hook(key)
        except Exception:  # noqa: BLE001
            pass
    return {"key": key, "value": value, "updated_at": now}


# 同一份配置有多个写点（转存目录、Cookie、解压配置），读-改-写必须串行，
# 否则后写会用旧快照覆盖别人刚存进去的字段。
_MUTATE_LOCK = threading.RLock()


def update_setting(
    key: str,
    mutate: Callable[[dict[str, Any]], dict[str, Any]],
) -> dict[str, Any]:
    """在锁内读-改-写一份配置；非 dict 的旧值按空对象处理。"""
    with _MUTATE_LOCK:
        current = get_setting(key)
        base = dict(current) if isinstance(current, dict) else {}
        return put_setting(key, mutate(base))
