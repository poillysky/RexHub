"""AVDB 开放接口设置的 HTTP 路由。"""


from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

import app.core.settings_store as settings_store
import app.search.avdb_client as avdb_client
from app.auth.routes import require_admin
from app.rexhub.auth_guard import require_session
from app.core.service_config import normalize_base

router = APIRouter(tags=["avdb"])


def _wrap(data: Any, message: str = "ok", status: int = 200) -> dict[str, Any]:
    return {"data": data, "message": message, "status": status}


class AvdbConfigBody(BaseModel):
    enabled: bool = True
    baseUrl: str = Field(default=avdb_client.DEFAULT_BASE_URL, max_length=300)
    apiKey: str = Field(default="", max_length=200)
    timeoutSec: float = Field(default=avdb_client.DEFAULT_TIMEOUT_S, ge=5, le=120)
    note: str | None = Field(default=None, max_length=200)


class AvdbTestBody(BaseModel):
    baseUrl: str = Field(default="", max_length=300)
    apiKey: str = Field(default="", max_length=200)
    timeoutSec: float | None = Field(default=None, ge=5, le=120)


@router.get("/avdb/health")
def avdb_health(_user: dict = Depends(require_session)) -> dict[str, Any]:
    return _wrap(avdb_client.health())


@router.get("/settings/avdb")
def get_avdb_settings(_user: dict = Depends(require_session)) -> dict[str, Any]:
    return _wrap(avdb_client.get_config(include_secrets=False))


@router.post("/avdb/test")
def test_avdb_settings(
    body: AvdbTestBody,
    _admin: dict = Depends(require_admin),
) -> dict[str, Any]:
    """用请求里的草稿配置探测连接，不落库；令牌留空时复用已保存的令牌。"""
    prev = avdb_client.get_config(include_secrets=True)
    if body.baseUrl.strip():
        base = normalize_base(body.baseUrl)
        if not base:
            raise HTTPException(status_code=400, detail="地址需为 http(s):// 开头的有效地址")
    else:
        base = str(prev["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="请填写服务地址")
    api_key = body.apiKey.strip() or str(prev.get("apiKey") or "")
    if not api_key:
        raise HTTPException(status_code=400, detail="请填写 API 令牌")
    timeout = body.timeoutSec or float(prev["timeoutSec"])
    return _wrap(avdb_client.probe(base, api_key, timeout=timeout))


@router.put("/settings/avdb")
def put_avdb_settings(
    body: AvdbConfigBody,
    _admin: dict = Depends(require_admin),
) -> dict[str, Any]:
    base = normalize_base(body.baseUrl)
    if not base:
        raise HTTPException(status_code=400, detail="地址需为 http(s):// 开头的有效地址")
    api_key = body.apiKey.strip()
    note = body.note.strip() if body.note is not None else None

    def _merge(prev: dict[str, Any]) -> dict[str, Any]:
        return {
            "enabled": body.enabled,
            "baseUrl": base,
            "apiKey": api_key or str(prev.get("apiKey") or ""),
            "timeoutSec": body.timeoutSec,
            "note": note if note is not None else str(prev.get("note") or ""),
        }

    settings_store.update_setting(avdb_client.AVDB_KEY, _merge)
    return _wrap(avdb_client.get_config(include_secrets=False), "saved")
