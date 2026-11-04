"""插件 / Stremio 仓库 / 服务的 PWA 管理接口。

原 ``/admin`` HTML 管理台已删除，这些写操作改为 PWA「更多 → 设置」调用，
统一挂在 ``/api/admin`` 下并校验 Web 会话 Cookie（与 ``/settings/*`` 一致）。
"""


from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.auth.routes import require_admin, require_user
from app.rexhub import addons_store, plugins_store, services_store

router = APIRouter(prefix="/api/admin", tags=["admin"])


class PluginSaveBody(BaseModel):
    source: str = ""
    category: str = ""


class PluginUpdateBody(BaseModel):
    title: str = ""
    description: str = ""
    note: str = ""
    apiUrl: str = ""
    apiKey: str = ""
    proxyUrl: str = ""
    proxyEnabled: bool = False
    enabled: bool = True
    category: str = ""


class EnabledBody(BaseModel):
    enabled: bool = True


class FeedBody(BaseModel):
    url: str = ""


class FeedWidgetBody(BaseModel):
    feedUrl: str = ""
    widgetId: str = ""
    title: str = ""
    description: str = ""
    note: str = ""
    apiUrl: str = ""
    enabled: bool = True


class FeedWidgetEnabledBody(BaseModel):
    feedUrl: str = ""
    widgetId: str = ""
    enabled: bool = True


class AddonBody(BaseModel):
    url: str = ""


class RepositoryBody(BaseModel):
    url: str = ""
    title: str = ""


class ServiceBody(BaseModel):
    id: str = ""
    name: str = ""
    category: str = "other"
    host: str = ""
    port: int = 0
    url: str = ""
    notes: str = ""


def _guard(fn, *args, **kwargs):
    """store 层用 ValueError 表达可读错误，这里统一转 400。"""
    try:
        return fn(*args, **kwargs)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


# ---------- 插件（本地源码 + 订阅） ----------


@router.get("/plugins")
def list_plugins(_user: dict = Depends(require_user)) -> dict:
    data = plugins_store.snapshot()
    return {
        **data,
        "categories": [
            {"key": key, "label": label} for key, label in plugins_store.CATEGORIES
        ],
        "autoConfig": plugins_store.auto_update_config(),
        "intervals": [
            {"minutes": minutes, "label": label}
            for minutes, label in plugins_store.AUTO_UPDATE_CHOICES
        ],
    }


@router.post("/plugins")
def create_plugin(body: PluginSaveBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(plugins_store.save_plugin, body.source, body.category)


@router.put("/plugins/{plugin_id}")
def update_plugin(
    plugin_id: str, body: PluginUpdateBody, _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(
        plugins_store.update_plugin_config,
        plugin_id,
        title=body.title,
        description=body.description,
        note=body.note,
        api_url=body.apiUrl,
        api_key=body.apiKey,
        proxy_url=body.proxyUrl,
        proxy_enabled=body.proxyEnabled,
        enabled=body.enabled,
        category=body.category,
    )


@router.put("/plugins/{plugin_id}/enabled")
def set_plugin_enabled(
    plugin_id: str, body: EnabledBody, _admin: dict = Depends(require_admin)
) -> dict:
    if not plugins_store.set_enabled(plugin_id, body.enabled):
        raise HTTPException(status_code=404, detail="插件不存在")
    return {"ok": True, "enabled": body.enabled}


@router.delete("/plugins/{plugin_id}")
def delete_plugin(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    if not plugins_store.delete_plugin(plugin_id):
        raise HTTPException(status_code=404, detail="插件不存在")
    return {"ok": True}


@router.post("/plugins/feeds")
def add_feed(body: FeedBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(plugins_store.add_feed, body.url)


@router.delete("/plugins/feeds")
def delete_feed(url: str, _admin: dict = Depends(require_admin)) -> dict:
    if not plugins_store.delete_feed(url):
        raise HTTPException(status_code=404, detail="订阅不存在")
    return {"ok": True}


@router.post("/plugins/feeds/refresh")
def refresh_feed(body: FeedBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(plugins_store.refresh_feed, body.url)


@router.post("/plugins/feeds/refresh-all")
def refresh_all_feeds(_admin: dict = Depends(require_admin)) -> dict:
    return plugins_store.refresh_all_feeds()


@router.put("/plugins/feeds/widget")
def update_feed_widget(
    body: FeedWidgetBody, _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(
        plugins_store.update_feed_widget,
        body.feedUrl,
        body.widgetId,
        title=body.title,
        description=body.description,
        note=body.note,
        api_url=body.apiUrl,
        enabled=body.enabled,
    )


@router.put("/plugins/feeds/widget/enabled")
def set_feed_widget_enabled(
    body: FeedWidgetEnabledBody, _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(
        plugins_store.set_feed_widget_enabled,
        body.feedUrl,
        body.widgetId,
        body.enabled,
    )


@router.put("/plugins/auto-update")
def set_auto_update(
    body: EnabledBody, interval: int = 0, _admin: dict = Depends(require_admin)
) -> dict:
    return plugins_store.set_auto_update(body.enabled, interval or None)


# ---------- Stremio 插件库 ----------


@router.get("/stremio")
def list_addons(_user: dict = Depends(require_user)) -> dict:
    return {
        **addons_store.snapshot(),
        "presets": [
            {"title": title, "url": url} for title, url in addons_store.REPOSITORY_PRESETS
        ],
        "official": addons_store.OFFICIAL_REPOSITORY,
    }


@router.post("/stremio/repositories")
def add_repository(body: RepositoryBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(addons_store.add_repository, body.url, body.title)


@router.post("/stremio/repositories/refresh")
def refresh_repository(body: RepositoryBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(addons_store.refresh_repository, body.url)


@router.delete("/stremio/repositories")
def delete_repository(url: str, _admin: dict = Depends(require_admin)) -> dict:
    if not addons_store.delete_repository(url):
        raise HTTPException(status_code=404, detail="仓库不存在")
    return {"ok": True}


@router.post("/stremio/addons")
def add_addon(body: AddonBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(addons_store.add_addon, body.url)


@router.post("/stremio/addons/{slug}/refresh")
def refresh_addon(slug: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(addons_store.refresh_addon, slug)


@router.post("/stremio/addons/{slug}/test")
def test_addon(slug: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(addons_store.test_addon, slug)


@router.put("/stremio/addons/{slug}/enabled")
def set_addon_enabled(
    slug: str, body: EnabledBody, _admin: dict = Depends(require_admin)
) -> dict:
    if not addons_store.set_addon_enabled(slug, body.enabled):
        raise HTTPException(status_code=404, detail="addon 不存在")
    return {"ok": True, "enabled": body.enabled}


@router.delete("/stremio/addons/{slug}")
def delete_addon(slug: str, _admin: dict = Depends(require_admin)) -> dict:
    if not addons_store.delete_addon(slug):
        raise HTTPException(status_code=404, detail="addon 不存在")
    return {"ok": True}


# ---------- NAS 服务卡片 ----------


@router.get("/services")
def list_services(_user: dict = Depends(require_user)) -> dict:
    items = services_store.list_services()
    return {
        "items": [
            {**item, "categoryLabel": services_store.category_label(str(item.get("category") or ""))}
            for item in items
        ],
        "categories": [
            {"key": key, "label": label} for key, label in services_store.CATEGORIES.items()
        ],
    }


@router.post("/services")
def save_service(body: ServiceBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(services_store.save_service, body.model_dump())


@router.delete("/services/{service_id}")
def delete_service(service_id: str, _admin: dict = Depends(require_admin)) -> dict:
    if not services_store.delete_service(service_id):
        raise HTTPException(status_code=404, detail="服务不存在")
    return {"ok": True}
