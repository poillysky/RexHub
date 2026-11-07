"""插件 / Stremio 仓库 / 服务的 PWA 管理接口。

原 ``/admin`` HTML 管理台已删除，这些写操作改为 PWA「更多 → 设置」调用，
统一挂在 ``/api/admin`` 下并校验 Web 会话 Cookie（与 ``/settings/*`` 一致）。
"""


from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.auth.routes import require_admin, require_user
from app.rexhub import addons_store, services_store

router = APIRouter(prefix="/api/admin", tags=["admin"])


class EnabledBody(BaseModel):
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


# ---------- Stremio 插件库 ----------


@router.get("/stremio")
def list_addons(_user: dict = Depends(require_user)) -> dict:
    return addons_store.snapshot()


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


# ---------- 单个 addon 的内容浏览与播放 ----------


def _addon_row(slug: str) -> dict:
    row = addons_store.find_any(slug)
    if row is None:
        raise HTTPException(status_code=404, detail="addon 不存在")
    return row


@router.get("/stremio/addons/{slug}/catalogs")
def addon_catalogs(slug: str, _user: dict = Depends(require_user)) -> dict:
    return addons_store.browse.catalogs(_addon_row(slug))


@router.get("/stremio/addons/{slug}/catalog")
def addon_catalog(
    slug: str,
    mediaType: str,
    id: str,
    genre: str = "",
    search: str = "",
    skip: str = "",
    _user: dict = Depends(require_user),
) -> dict:
    extra = {
        key: value
        for key, value in (("genre", genre), ("search", search), ("skip", skip))
        if value
    }
    try:
        return addons_store.browse.catalog(_addon_row(slug), mediaType, id, extra)
    except addons_store.UpstreamError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/stremio/addons/{slug}/meta")
def addon_meta(
    slug: str,
    mediaType: str,
    id: str,
    _user: dict = Depends(require_user),
) -> dict:
    try:
        return addons_store.browse.meta(_addon_row(slug), mediaType, id)
    except addons_store.UpstreamError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/stremio/addons/{slug}/streams")
def addon_streams(
    slug: str,
    mediaType: str,
    id: str,
    season: int = 0,
    episode: int = 0,
    _user: dict = Depends(require_user),
) -> dict:
    try:
        return addons_store.browse.streams(
            _addon_row(slug), mediaType, id, season, episode
        )
    except addons_store.UpstreamError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


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
