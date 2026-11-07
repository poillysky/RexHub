"""插件框架管理接口（PWA → 设置 → 插件中心）。

与旧 ForwardWidget 插件接口（``/api/admin/plugins``）分开，便于框架迁移期并存；
旧插件体系下线后，前端只需切换到本组接口。
"""


from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.auth.routes import require_admin, require_user
from app.rexhub.plugin_framework import dispatcher, manager, runtime

router = APIRouter(prefix="/api/admin/plugin-framework", tags=["plugin-framework"])


class RepositoryBody(BaseModel):
    id: str = ""
    name: str = ""
    url: str
    branch: str = ""
    index_path: str = "repository.json"
    format: str = "repository"
    enabled: bool = True


class InstallBody(BaseModel):
    repository: str
    id: str


class ConfigBody(BaseModel):
    config: dict[str, str] = Field(default_factory=dict)


class ProxyBody(BaseModel):
    enabled: bool = False


class ShortdramaBody(BaseModel):
    enabled: bool = False


class DispatchBody(BaseModel):
    capability: str
    payload: dict = Field(default_factory=dict)


class ProviderBody(BaseModel):
    id: str
    name: str = ""
    version: str = "1.0.0"
    description: str = ""
    author: str = ""
    category: str = "tool"
    api_version: str = "1.0"
    base_url: str
    capabilities: list[str] = Field(default_factory=list)
    endpoints: dict = Field(default_factory=dict)
    config: list = Field(default_factory=list)
    headers: dict = Field(default_factory=dict)
    healthcheck: str = "/health"


def _guard(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("")
def overview(_admin: dict = Depends(require_admin)) -> dict:
    return {
        "runtime": {"node": runtime.node_binary() or ""},
        "repositories": manager.repositories_list(),
        "installed": manager.installed(),
    }


@router.get("/repositories")
def list_repositories(_admin: dict = Depends(require_admin)) -> dict:
    return {"items": manager.repositories_list()}


@router.post("/repositories")
def add_repository(body: RepositoryBody, _admin: dict = Depends(require_admin)) -> dict:
    return {"repository": _guard(manager.save_repository, body.model_dump())}


@router.delete("/repositories/{repo_id}")
def remove_repository(repo_id: str, _admin: dict = Depends(require_admin)) -> dict:
    if not manager.delete_repository(repo_id):
        raise HTTPException(status_code=404, detail="插件仓库不存在")
    return {"ok": True}


@router.post("/repositories/{repo_id}/refresh")
def refresh_repository(repo_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.refresh_repository, repo_id)


@router.get("/market")
def market(repository: str = "", _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.market, repository)


@router.get("/installed")
def installed(_user: dict = Depends(require_user)) -> dict:
    return {"items": manager.installed()}


@router.get("/updates")
def updates(_admin: dict = Depends(require_admin)) -> dict:
    return {"items": _guard(manager.updates)}


@router.post("/update-all")
def update_all(_admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.update_all)


@router.post("/install")
def install(body: InstallBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.install, body.repository, body.id)


@router.post("/{plugin_id}/update")
def update(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.update, plugin_id)


@router.post("/{plugin_id}/rollback")
def rollback(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.rollback, plugin_id)


@router.post("/{plugin_id}/enable")
def enable(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.enable, plugin_id)


@router.post("/{plugin_id}/disable")
def disable(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.disable, plugin_id)


@router.post("/{plugin_id}/restart")
def restart(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.restart, plugin_id)


@router.get("/{plugin_id}/config")
def get_config(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.config_schema, plugin_id)


@router.put("/{plugin_id}/config")
def save_config(
    plugin_id: str, body: ConfigBody, _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(manager.save_config, plugin_id, body.config)


@router.put("/{plugin_id}/proxy")
def save_proxy(
    plugin_id: str, body: ProxyBody, _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(manager.set_proxy, plugin_id, body.enabled)


@router.put("/{plugin_id}/shortdrama")
def save_shortdrama(
    plugin_id: str, body: ShortdramaBody, _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(manager.set_shortdrama_visible, plugin_id, body.enabled)


@router.get("/{plugin_id}/export")
def export_plugin_js(
    plugin_id: str, base_url: str = "", _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(manager.export_js, plugin_id, base_url=base_url)


@router.get("/{plugin_id}/logs")
def plugin_logs(
    plugin_id: str, limit: int = 120, _admin: dict = Depends(require_admin)
) -> dict:
    return _guard(manager.logs, plugin_id, limit)


@router.get("/{plugin_id}/health")
def plugin_health(plugin_id: str, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.health, plugin_id)


@router.delete("/{plugin_id}")
def uninstall(
    plugin_id: str,
    purge_data: bool = False,
    _admin: dict = Depends(require_admin),
) -> dict:
    return _guard(manager.uninstall, plugin_id, purge_data=purge_data)


@router.get("/capabilities")
def capabilities(_user: dict = Depends(require_user)) -> dict:
    return {"items": manager.capabilities()}


@router.post("/dispatch")
def dispatch(body: DispatchBody, _admin: dict = Depends(require_admin)) -> dict:
    try:
        return dispatcher.dispatch(body.capability, body.payload)
    except dispatcher.DispatchError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@router.post("/providers")
def add_provider(body: ProviderBody, _admin: dict = Depends(require_admin)) -> dict:
    return _guard(manager.add_http_provider, body.model_dump())
