"""AVDB 开放接口客户端（成人数据库管理服务）。

外部接入方式：请求头 ``X-API-Key`` 带令牌，
例如 ``GET {base}/api/v1/articles/torrents?keyword={code}``。
令牌可在 ``{base}/tokens`` 页面创建 / 查看。
"""


from typing import Any

import httpx

import app.core.settings_store as settings_store
from app.search.pansou_client import _normalize_base

AVDB_KEY = "avdb"
DEFAULT_BASE_URL = ""
DEFAULT_TIMEOUT_S = 15.0
TORRENTS_PATH = "/api/v1/articles/torrents"

# 只用来验令牌：返回 code=0 即鉴权通过，不关心命中条数
_PROBE_KEYWORD = "SSIS-001"


class AvdbError(Exception):
    pass


def get_config(*, include_secrets: bool = False) -> dict[str, Any]:
    raw = settings_store.get_setting(AVDB_KEY) or {}
    if not isinstance(raw, dict):
        raw = {}
    base = _normalize_base(str(raw.get("baseUrl") or ""))
    api_key = str(raw.get("apiKey") or "").strip()
    enabled = raw.get("enabled")
    if enabled is None:
        enabled = True
    timeout = float(raw.get("timeoutSec") or DEFAULT_TIMEOUT_S)
    out: dict[str, Any] = {
        "enabled": bool(enabled),
        "baseUrl": base,
        "timeoutSec": max(5.0, min(timeout, 120.0)),
        "hasApiKey": bool(api_key),
        "tokenPageUrl": f"{base}/tokens",
        "note": str(raw.get("note") or ""),
    }
    if include_secrets:
        out["apiKey"] = api_key
    return out


def request_json(
    path: str,
    params: dict[str, Any] | None = None,
    *,
    timeout: float | None = None,
) -> Any:
    """GET 一个 AVDB 接口，返回 ``payload["data"]``。失败统一抛 :class:`AvdbError`。"""
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise AvdbError("AVDB 未启用")
    base = str(cfg["baseUrl"]).rstrip("/")
    api_key = str(cfg.get("apiKey") or "")
    if not api_key:
        raise AvdbError("未配置 AVDB API 令牌")
    try:
        with httpx.Client(
            timeout=float(timeout or cfg["timeoutSec"]),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            resp = client.get(
                f"{base}{path}",
                params=params or {},
                headers={"X-API-Key": api_key},
            )
    except Exception as e:
        raise AvdbError(f"连接失败: {e}") from e
    if resp.status_code == 401:
        raise AvdbError("AVDB 令牌无效（401）")
    if resp.status_code == 404:
        raise AvdbError("AVDB 未找到该资源（404）")
    if resp.status_code >= 400:
        raise AvdbError(f"AVDB HTTP {resp.status_code}")
    try:
        payload = resp.json()
    except ValueError as e:
        raise AvdbError("AVDB 响应不是 JSON") from e
    if payload.get("code") not in (None, 0):
        raise AvdbError(str(payload.get("message") or "AVDB 接口返回异常"))
    return payload.get("data")


def request_bytes(
    path: str,
    params: dict[str, Any] | None = None,
    *,
    timeout: float | None = None,
) -> bytes:
    """GET 一个 AVDB 接口，返回原始字节（图片代理等二进制资源）。"""
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise AvdbError("AVDB 未启用")
    base = str(cfg["baseUrl"]).rstrip("/")
    api_key = str(cfg.get("apiKey") or "")
    if not api_key:
        raise AvdbError("未配置 AVDB API 令牌")
    try:
        with httpx.Client(
            timeout=httpx.Timeout(float(timeout or cfg["timeoutSec"]), read=30.0),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            resp = client.get(
                f"{base}{path}",
                params=params or {},
                headers={"X-API-Key": api_key},
            )
    except Exception as e:
        raise AvdbError(f"连接失败: {e}") from e
    if resp.status_code == 401:
        raise AvdbError("AVDB 令牌无效（401）")
    if resp.status_code >= 400:
        raise AvdbError(f"AVDB HTTP {resp.status_code}")
    return resp.content


def health() -> dict[str, Any]:
    cfg = get_config(include_secrets=True)
    base = str(cfg["baseUrl"])
    if not cfg["enabled"] or not base:
        return {"ok": False, "configured": False, "baseUrl": base, "message": "未配置"}
    api_key = str(cfg.get("apiKey") or "")
    if not api_key:
        return {
            "ok": False,
            "configured": False,
            "baseUrl": base,
            "message": "未配置 API 令牌",
        }
    try:
        with httpx.Client(
            timeout=float(cfg["timeoutSec"]), trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(
                f"{base}{TORRENTS_PATH}",
                params={"keyword": _PROBE_KEYWORD},
                headers={"X-API-Key": api_key},
            )
    except Exception as e:
        return {
            "ok": False,
            "configured": True,
            "baseUrl": base,
            "message": f"连接失败: {e}",
        }
    if resp.status_code == 401:
        return {
            "ok": False,
            "configured": True,
            "baseUrl": base,
            "message": "令牌无效（401）",
        }
    if resp.status_code >= 400:
        return {
            "ok": False,
            "configured": True,
            "baseUrl": base,
            "message": f"HTTP {resp.status_code}",
        }
    try:
        payload = resp.json()
    except ValueError:
        return {
            "ok": False,
            "configured": True,
            "baseUrl": base,
            "message": "响应不是 JSON",
        }
    code = payload.get("code")
    if code not in (None, 0):
        return {
            "ok": False,
            "configured": True,
            "baseUrl": base,
            "message": str(payload.get("message") or "接口返回异常"),
        }
    return {"ok": True, "configured": True, "baseUrl": base, "message": "令牌有效"}
