"""把原 RexHub Server 的能力挂到新后端。

原服务端（``RexHub/server``）是一套独立 FastAPI 应用，逻辑迁入本仓库后
不再单独启动：这里集中 include 各域路由，避免 ``app.main`` 里堆一大段 include。

路由前缀保持原样（``/api/*`` 给 iOS App / 插件系统使用），与 next-web 原生的
``/auth``、``/resource``、``/settings/*`` 互不冲突。

管理操作统一在 PWA（``web``）里做，原 ``/admin`` HTML 管理台已移除，
写接口见 ``routers/admin.py``（``/api/admin/*``，校验 Web 会话 Cookie）。
"""


from fastapi import FastAPI

from app.rexhub.routers import (
    admin,
    media,
    pan,
    plugin_api,
    plugin_framework,
    search,
    services,
    settings,
    shortdrama,
    stremio,
)

# 注意：不含 auth —— 登录/会话统一由 ``app.auth.routes`` 提供（/api/auth/*），
# 同时支持 Web 的 Cookie 与 iOS 的 Bearer，避免两套账号库并存。
REXHUB_ROUTERS = (
    pan.router,
    search.router,
    services.router,
    media.router,
    shortdrama.router,
    stremio.router,
    settings.router,
    admin.router,
    plugin_framework.router,
    plugin_api.router,
)


def include_rexhub(app: FastAPI) -> None:
    for router in REXHUB_ROUTERS:
        app.include_router(router)
