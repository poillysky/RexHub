"""Meta API — 应用装配入口。

这里**只做装配**：建 app、挂中间件、include 各域路由、启动/关闭生命周期。
具体端点实现请到对应域模块，例如 DB 设置端点在 ``app.core.db_settings_routes``。
"""


import logging
import os
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.auth.routes import router as auth_router
from app.core.bootstrap import seed_settings_from_config
from app.core.config_loader import config_paths
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
from app.search.pansou_routes import router as pansou_router
from app.search.cloudsaver_routes import router as cloudsaver_router
from app.translate.routes import router as translate_router

# DB 连接设置端点：resource-db / bitmagnet-db 由同一个参数化工厂生成。
from app.core.db_settings_routes import (
    BitmagnetDbConfig,
    ResourceDbConfig,
    build_db_settings_router,
)

import app.core.pg_data_backup as pg_data_backup
import app.core.settings_store as settings_store
import app.rexhub as rexhub_pkg
from app.rexhub.routes import include_rexhub

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    init_db()
    seed_settings_from_config()
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
    pansou_router,
    cloudsaver_router,
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
    embed_module="app.search.sehua_resource_embed_svc",
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
    embed_module="app.search.bitmagnet_embed_svc",
    operation_prefix="bitmagnet_db",
)
app.include_router(_bitmagnet_db_router, prefix="/api")

# RexHub 原生能力（原 RexHub/server 迁入）：/api/*、/plugins、/stremio、/addon
include_rexhub(app)


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "rexhub-api",
        "rexhub_version": rexhub_pkg.__version__,
        "meta_db": meta_db_label(),
        "config": [str(p) for p in config_paths()],
        "phase": "search",
    }
