"""服务卡片的 PWA 管理接口。

原 ``/admin`` HTML 管理台已删除，这些写操作改为 PWA「更多 → 设置」调用，
统一挂在 ``/api/admin`` 下并校验 Web 会话 Cookie（与 ``/settings/*`` 一致）。
"""


from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.auth.routes import require_admin
from app.rexhub import services_store

router = APIRouter(prefix="/api/admin", tags=["admin"])


class ServiceBody(BaseModel):
    id: str = ""
    name: str = ""
    category: str = "other"
    section: str = ""
    host: str = ""
    port: int = 0
    url: str = ""
    api_base: str = ""
    source_kind: str = ""
    enabled: bool = True
    username: str = ""
    password: str = ""
    database: str = ""
    api_key: str = ""
    notes: str = ""
    endpoints: dict = Field(default_factory=dict)
    ui: dict = Field(default_factory=dict)


class ServiceProbeBody(BaseModel):
    host: str = ""
    port: int = 0
    api_base: str = ""
    url: str = ""


def _guard(fn, *args, **kwargs):
    """store 层用 ValueError 表达可读错误，这里统一转 400。"""
    try:
        return fn(*args, **kwargs)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


# ---------- NAS 服务卡片 ----------


# 对外展示的服务字段白名单：密码、API Key、数据库账号等凭据一律不出接口。
_SERVICE_PUBLIC_FIELDS = (
    "id",
    "name",
    "category",
    "section",
    "host",
    "port",
    "url",
    "api_base",
    "source_kind",
    "enabled",
    "endpoints",
    "ui",
    "notes",
    "updated_at",
    "online",
    "latency",
)


def _public_service(item: dict) -> dict:
    view = {key: item[key] for key in _SERVICE_PUBLIC_FIELDS if key in item}
    view["categoryLabel"] = services_store.category_label(str(item.get("category") or ""))
    return view


@router.get("/services")
def list_services(_admin: dict = Depends(require_admin)) -> dict:
    return {
        "items": [_public_service(item) for item in services_store.list_services()],
        "categories": [
            {"key": key, "label": label} for key, label in services_store.CATEGORIES.items()
        ],
        "sourceKinds": [
            {"key": key, "label": label}
            for key, label in services_store.SOURCE_KINDS.items()
        ],
    }


@router.post("/services")
def save_service(body: ServiceBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(services_store.save_service, body.model_dump())


@router.post("/services/probe")
def probe_service(body: ServiceProbeBody, _admin: dict = Depends(require_admin)) -> dict:
    return services_store.probe_target(
        body.host, body.port, api_base=body.api_base, url=body.url
    )


@router.delete("/services/{service_id}")
def delete_service(service_id: str, _admin: dict = Depends(require_admin)) -> dict:
    if not services_store.delete_service(service_id):
        raise HTTPException(status_code=404, detail="服务不存在")
    return {"ok": True}
