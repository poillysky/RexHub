"""CloudSaver 网盘搜索 HTTP 路由。"""


from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

import app.search.cloudsaver_client as cloudsaver_client
import app.core.settings_store as settings_store
from app.auth.routes import require_admin
from app.core.service_config import normalize_base
from app.rexhub.auth_guard import require_session

router = APIRouter(tags=["cloudsaver"])


def _wrap(data: Any, message: str = "ok", status: int = 200) -> dict[str, Any]:
    return {"data": data, "message": message, "status": status}


class CloudSaverConfigBody(BaseModel):
    enabled: bool = True
    baseUrl: str = Field(default=cloudsaver_client.DEFAULT_BASE_URL, max_length=300)
    username: str = Field(default="", max_length=80)
    password: str = Field(default="", max_length=200)
    timeoutSec: float = Field(default=60, ge=8, le=180)
    note: str = Field(default="", max_length=200)


class CloudSaverTestBody(BaseModel):
    baseUrl: str = Field(default="", max_length=300)
    username: str = Field(default="", max_length=80)
    password: str = Field(default="", max_length=200)
    timeoutSec: float | None = Field(default=None, ge=8, le=180)


@router.get("/cloudsaver/health")
def cloudsaver_health(_user: dict = Depends(require_session)) -> dict[str, Any]:
    return _wrap(cloudsaver_client.health())


@router.post("/cloudsaver/test")
def cloudsaver_test(
    body: CloudSaverTestBody,
    _admin: dict = Depends(require_admin),
) -> dict[str, Any]:
    """用表单里未保存的凭据试登录，不写配置；密码留空沿用已存密码。"""
    try:
        cloudsaver_client.test_login(
            base_url=body.baseUrl,
            username=body.username,
            password=body.password,
            timeout_sec=body.timeoutSec,
        )
    except cloudsaver_client.CloudSaverError as e:
        return _wrap({"ok": False, "message": str(e)})
    return _wrap({"ok": True, "message": "登录成功"})


@router.get("/cloudsaver/search")
def cloudsaver_search(
    keyword: str = Query(..., min_length=1, max_length=200),
    _user: dict = Depends(require_session),
) -> dict[str, Any]:
    try:
        data = cloudsaver_client.search(keyword)
        return _wrap(data, "success")
    except cloudsaver_client.CloudSaverError as e:
        msg = str(e)
        code = (
            400
            if ("未启用" in msg or "未配置" in msg or "为空" in msg or "账号" in msg)
            else 502
        )
        raise HTTPException(status_code=code, detail=msg) from e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"CloudSaver 搜索失败: {e}") from e


@router.get("/settings/cloudsaver")
def get_cloudsaver_settings(
    _user: dict = Depends(require_session),
) -> dict[str, Any]:
    return _wrap(cloudsaver_client.get_config(include_secrets=False))


@router.put("/settings/cloudsaver")
def put_cloudsaver_settings(
    body: CloudSaverConfigBody,
    _admin: dict = Depends(require_admin),
) -> dict[str, Any]:
    base = normalize_base(body.baseUrl)
    if not base:
        raise HTTPException(status_code=400, detail="baseUrl 不能为空")

    def _merged(prev: dict[str, Any]) -> dict[str, Any]:
        # 密码留空表示沿用已存值；不做 strip 落库，避免改动用户原始密码
        password = body.password if body.password.strip() else str(prev.get("password") or "")
        return {
            "enabled": body.enabled,
            "baseUrl": base,
            "username": body.username.strip(),
            "password": password,
            "timeoutSec": body.timeoutSec,
            "note": body.note.strip(),
            "token": "",  # 改配置后强制重新登录
        }

    settings_store.update_setting(cloudsaver_client.CLOUDSAVER_KEY, _merged)
    return _wrap(cloudsaver_client.get_config(include_secrets=False), "saved")
