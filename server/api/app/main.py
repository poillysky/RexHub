"""Meta API — 应用装配入口。

这里**只做装配**：建 app、挂中间件、include 各域路由、启动/关闭生命周期。
具体端点实现请到对应域模块，例如 DB 设置端点在 ``app.core.db_settings_routes``。
"""


import logging
import os
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.auth.routes import router as auth_router
from app.core.bootstrap import seed_settings_from_config
from app.core.db import close_meta_db, init_db, meta_db_label
from app.core.pg import close_pool
from app.search.bitmagnet_pg import close_pool as close_bitmagnet_pool

from app.search.resource_routes import router as resource_router
from app.core.conn_settings_routes import router as conn_settings_router
from app.ai.settings_routes import router as ai_settings_router
from app.ai.chat_routes import router as ai_chat_router
from app.ai.assistant_routes import router as ai_assistant_router
from app.ai.chat_preset_routes import router as ai_chat_preset_router
from app.search.magnet_routes import router as magnet_router
from app.search.scope_routes import router as scope_router
from app.search.cloudsaver_routes import router as cloudsaver_router
from app.search.avdb_client import AvdbError
from app.search.avdb_routes import router as avdb_router
from app.core.moviepilot_routes import router as moviepilot_router
from app.core.moreplay_routes import router as moreplay_router
from app.makers.router import router as makers_router
from app.translate.routes import router as translate_router

# DB 连接设置端点：resource-db / bitmagnet-db 由同一个参数化工厂生成。
from app.core.db_settings_routes import (
    BitmagnetDbConfig,
    ResourceDbConfig,
    build_db_settings_router,
)

import app.core.pg_data_backup as pg_data_backup
import app.core.settings_store as settings_store
import app.auth.store as auth_store
import app.rexhub as rexhub_pkg
from app.rexhub.routes import include_rexhub

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    init_db()
    seed_settings_from_config()
    invites = auth_store.ensure_invite_codes()
    auth_store.prune_sessions()
    if auth_store.admin_count() == 0:
        # 仅出现在启动日志，不通过任何匿名接口暴露；注册首个管理员后不再打印。
        log.warning("尚无管理员账号，管理员邀请码：%s", invites["admin"])
    from app.core.outbound_http import start_flare_monitor, stop_flare_monitor

    start_flare_monitor()
    yield
    stop_flare_monitor()
    close_pool()
    close_bitmagnet_pool()
    close_meta_db()


def _cors_origins() -> list[str]:
    """CORS 允许来源：默认通配（同源 rewrite 场景不需要 CORS）；可经 SNS_CORS_ORIGINS 收紧。"""
    raw = os.environ.get("SNS_CORS_ORIGINS", "").strip()
    if not raw:
        return ["*"]
    return [o.strip() for o in raw.split(",") if o.strip()]


app = FastAPI(title="RexHub API", version=rexhub_pkg.__version__, lifespan=lifespan)


@app.exception_handler(AvdbError)
async def _handle_avdb_error(_request: Any, exc: AvdbError) -> JSONResponse:
    """AVDB 不可用统一返回 502，避免列表类接口直接抛 500。"""
    return JSONResponse(status_code=502, content={"detail": str(exc)})


@app.exception_handler(RequestValidationError)
async def _handle_validation_error(
    _request: Any, exc: RequestValidationError
) -> JSONResponse:
    """参数校验失败统一转中文。

    Pydantic 默认返回英文原文（如 "List should have at most 50 items
    after validation, not 60"），直接透到前端会让用户看不出该怎么做。
    这里保留 422 状态码与 errors 明细，只把 detail 换成可操作的中文。
    """
    errors = exc.errors()
    return JSONResponse(
        status_code=422,
        content={
            "detail": _validation_message(errors),
            "errors": [
                {
                    "loc": [str(p) for p in e.get("loc", ())],
                    "type": str(e.get("type") or ""),
                    "msg": str(e.get("msg") or ""),
                }
                for e in errors
            ],
        },
    )


def _validation_message(errors: list[dict[str, Any]]) -> str:
    """把首条校验错误翻成中文提示。"""
    if not errors:
        return "请求参数不合法"
    first = errors[0]
    etype = str(first.get("type") or "")
    loc = [str(p) for p in first.get("loc", ()) if p != "body"]
    field = ".".join(loc) or "参数"
    ctx = first.get("ctx") or {}

    if etype == "too_long" and "max_length" in ctx:
        limit = ctx["max_length"]
        if field == "urls":
            return f"单批链接过多（上限 {limit} 条），请分批提交"
        return f"{field} 过长（上限 {limit}）"
    if etype == "too_short" and "min_length" in ctx:
        limit = ctx["min_length"]
        if field == "urls":
            return "请至少提供 1 条可转存链接"
        return f"{field} 过短（至少 {limit}）"
    if etype == "missing":
        return f"缺少必填参数：{field}"
    if etype in {"string_type", "int_type", "list_type", "dict_type"}:
        return f"参数类型不正确：{field}"
    if etype == "value_error":
        # 业务层 ValueError 已带中文提示，直接透出
        msg = str(first.get("msg") or "").replace("Value error, ", "").strip()
        if msg:
            return msg
    return str(first.get("msg") or "请求参数不合法")


app.add_middleware(
    CORSMiddleware,
    # 允许跨域来源（逗号分隔，如 SNS_CORS_ORIGINS=http://192.168.2.38:3020）
    allow_origins=_cors_origins(),
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# 路由挂载约定（唯一标准：一切对外接口都在 /api 下）
#
#   Web(PWA) 的 API_BASE=/api，Next rewrite 原样转发；iOS App 也统一调 /api/*。
#   因此这里**只挂一次**，不存在裸路径别名。
#
#   各 router 自身前缀以 / 开头（如 /auth、/settings、/search），
#   统一加 /api 前缀后成为 /api/auth、/api/settings、/api/search …
# ---------------------------------------------------------------------------

_BUSINESS_ROUTERS = [
    resource_router,
    conn_settings_router,
    ai_settings_router,
    ai_chat_router,
    ai_assistant_router,
    ai_chat_preset_router,
    magnet_router,
    scope_router,
    cloudsaver_router,
    avdb_router,
    moviepilot_router,
    moreplay_router,
    makers_router,
    translate_router,
]

# auth router 前缀已是 /api/auth，直接挂载
app.include_router(auth_router)

for _router in _BUSINESS_ROUTERS:
    app.include_router(_router, prefix="/api")


# /settings/resource-db/*：色花资源库（v1.2.21 前为手写的 7 个端点）
_resource_db_router = build_db_settings_router(
    prefix="/settings/resource-db",
    tag="settings",
    setting_key=settings_store.RESOURCE_DB_KEY,
    config_model=ResourceDbConfig,
    backup_kind=pg_data_backup.KIND_RESOURCE,
    dsn_required_detail="请先启用并保存色花资源库连接",
    refused_hint="连接被拒绝：请确认 Postgres 已启动且端口正确（色花常用 5435）",
    backup_filename_desc="backups/resource-db 下的 zip 文件名",
    close_pool=close_pool,
    operation_prefix="resource_db",
)
app.include_router(_resource_db_router, prefix="/api")

# /settings/bitmagnet-db/*：Bitmagnet 磁力库（与上面同构，仅参数不同）
_bitmagnet_db_router = build_db_settings_router(
    prefix="/settings/bitmagnet-db",
    tag="settings",
    setting_key=settings_store.BITMAGNET_DB_KEY,
    config_model=BitmagnetDbConfig,
    backup_kind=pg_data_backup.KIND_BITMAGNET,
    dsn_required_detail="请先启用并保存 Bitmagnet 连接",
    refused_hint="连接被拒绝：请确认 Bitmagnet Postgres 已启动且端口正确（默认 5432）",
    backup_filename_desc="backups/bitmagnet-db 下的 zip 文件名",
    close_pool=close_bitmagnet_pool,
    operation_prefix="bitmagnet_db",
)
app.include_router(_bitmagnet_db_router, prefix="/api")

# RexHub 原生能力（原 RexHub/server 迁入）：/api/*、/plugins
include_rexhub(app)


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "rexhub-api",
        "rexhub_version": rexhub_pkg.__version__,
        "meta_db": meta_db_label(),
        "phase": "search",
    }
