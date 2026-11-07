"""AVDB 开放接口设置的 HTTP 路由。"""


from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

import app.core.settings_store as settings_store
import app.search.avdb_client as avdb_client
from app.search.pansou_client import _normalize_base

router = APIRouter(tags=["avdb"])


def _wrap(data: Any, message: str = "ok", status: int = 200) -> dict[str, Any]:
    return {"data": data, "message": message, "status": status}


class AvdbConfigBody(BaseModel):
    enabled: bool = True
    baseUrl: str = Field(default=avdb_client.DEFAULT_BASE_URL, max_length=300)
    apiKey: str = Field(default="", max_length=200)
    timeoutSec: float = Field(default=avdb_client.DEFAULT_TIMEOUT_S, ge=5, le=120)
    note: str = Field(default="", max_length=200)


@router.get("/avdb/health")
def avdb_health() -> dict[str, Any]:
    return _wrap(avdb_client.health())


@router.get("/settings/avdb")
def get_avdb_settings() -> dict[str, Any]:
    return _wrap(avdb_client.get_config(include_secrets=False))


@router.put("/settings/avdb")
def put_avdb_settings(body: AvdbConfigBody) -> dict[str, Any]:
    base = _normalize_base(body.baseUrl)
    if not base:
        raise HTTPException(status_code=400, detail="baseUrl 不能为空")
    prev = settings_store.get_setting(avdb_client.AVDB_KEY) or {}
    if not isinstance(prev, dict):
        prev = {}
    api_key = body.apiKey.strip()
    if not api_key:
        api_key = str(prev.get("apiKey") or "")
    settings_store.put_setting(
        avdb_client.AVDB_KEY,
        {
            "enabled": body.enabled,
            "baseUrl": base,
            "apiKey": api_key,
            "timeoutSec": body.timeoutSec,
            "note": body.note.strip(),
        },
    )
    return _wrap(avdb_client.get_config(include_secrets=False), "saved")
