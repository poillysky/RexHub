"""MoviePilot 服务配置：常量、配置读取与连通性探测。

鉴权方式：MoviePilot 开放 API 用 ``?apikey=<令牌>`` 查询参数，
例如 ``GET {base}/api/v1/user/?apikey=<令牌>``。
"""

from typing import Any

import httpx
from pydantic import BaseModel, Field

from app.core.service_config import normalize_base, read_service

MOVIEPILOT_KEY = "moviepilot"
DEFAULT_BASE_URL = ""
DEFAULT_TIMEOUT_S = 15.0
# 需要鉴权的轻量接口：能返回用户列表即代表地址与令牌都有效
_PROBE_PATH = "/api/v1/user/"


class MoviePilotConfigBody(BaseModel):
    enabled: bool = True
    baseUrl: str = Field(default=DEFAULT_BASE_URL, max_length=300)
    apiKey: str = Field(default="", max_length=200)
    timeoutSec: float = Field(default=DEFAULT_TIMEOUT_S, ge=5, le=120)
    note: str | None = Field(default=None, max_length=200)


class MoviePilotTestBody(BaseModel):
    baseUrl: str = Field(default="", max_length=300)
    apiKey: str = Field(default="", max_length=200)
    timeoutSec: float | None = Field(default=None, ge=5, le=120)


def get_config(*, include_secrets: bool = False) -> dict[str, Any]:
    raw, cfg = read_service(
        MOVIEPILOT_KEY,
        default_timeout=DEFAULT_TIMEOUT_S,
        timeout_min=5.0,
        timeout_max=120.0,
    )
    cfg["baseUrl"] = normalize_base(cfg["baseUrl"])
    api_key = str(raw.get("apiKey") or "").strip()
    cfg["hasApiKey"] = bool(api_key)
    if include_secrets:
        cfg["apiKey"] = api_key
    return cfg


def _probe(base: str, api_key: str, timeout: float) -> dict[str, Any]:
    try:
        with httpx.Client(
            timeout=timeout, trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(f"{base}{_PROBE_PATH}", params={"apikey": api_key})
    except Exception as e:
        return {"ok": False, "message": f"连接失败: {e}"}
    if resp.status_code == 401:
        return {"ok": False, "message": "令牌无效（401）"}
    if resp.status_code >= 400:
        return {"ok": False, "message": f"HTTP {resp.status_code}"}
    try:
        payload = resp.json()
    except ValueError:
        return {"ok": False, "message": "响应不是 JSON"}
    if not isinstance(payload, dict):
        return {"ok": False, "message": "响应格式异常"}
    if payload.get("success") is False:
        return {"ok": False, "message": str(payload.get("message") or "接口返回异常")}
    users = payload.get("data")
    return {
        "ok": True,
        "message": "连接成功",
        "userCount": len(users) if isinstance(users, list) else 0,
    }
