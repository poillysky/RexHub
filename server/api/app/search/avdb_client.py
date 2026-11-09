"""AVDB 开放接口客户端（成人数据库管理服务）。

外部接入方式：请求头 ``X-API-Key`` 带令牌，
例如 ``GET {base}/api/v1/articles/torrents?keyword={code}``。
令牌可在 ``{base}/tokens`` 页面创建 / 查看。
"""


from typing import Any

import httpx

from app.core.service_config import normalize_base, read_service

AVDB_KEY = "avdb"
DEFAULT_BASE_URL = ""
DEFAULT_TIMEOUT_S = 15.0
TORRENTS_PATH = "/api/v1/articles/torrents"

# 只用来验令牌：返回 code=0 即鉴权通过，不关心命中条数
_PROBE_KEYWORD = "SSIS-001"
# 图片代理单次响应上限，避免被异常内容撑爆进程内存
MAX_IMAGE_BYTES = 8 * 1024 * 1024


class AvdbError(Exception):
    pass


def _http_error(resp: httpx.Response) -> AvdbError:
    """把 AVDB 的 4xx/5xx 转成带原因的错误，保留上游返回的 detail/message。"""
    detail = ""
    try:
        payload = resp.json()
    except ValueError:
        payload = None
    if isinstance(payload, dict):
        detail = str(payload.get("detail") or payload.get("message") or "").strip()
    if detail:
        return AvdbError(detail)
    return AvdbError(f"AVDB HTTP {resp.status_code}")


def get_config(*, include_secrets: bool = False) -> dict[str, Any]:
    raw, cfg = read_service(
        AVDB_KEY,
        default_timeout=DEFAULT_TIMEOUT_S,
        timeout_min=5.0,
        timeout_max=120.0,
    )
    cfg["baseUrl"] = normalize_base(cfg["baseUrl"])
    api_key = str(raw.get("apiKey") or "").strip()
    cfg["hasApiKey"] = bool(api_key)
    cfg["tokenPageUrl"] = f"{cfg['baseUrl']}/tokens" if cfg["baseUrl"] else ""
    if include_secrets:
        cfg["apiKey"] = api_key
    return cfg


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
    if not base:
        raise AvdbError("未配置 AVDB 服务地址")
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
        raise _http_error(resp) from None
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
    if not base:
        raise AvdbError("未配置 AVDB 服务地址")
    api_key = str(cfg.get("apiKey") or "")
    if not api_key:
        raise AvdbError("未配置 AVDB API 令牌")
    try:
        with httpx.Client(
            timeout=httpx.Timeout(float(timeout or cfg["timeoutSec"]), read=30.0),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            with client.stream(
                "GET",
                f"{base}{path}",
                params=params or {},
                headers={"X-API-Key": api_key},
            ) as resp:
                if resp.status_code == 401:
                    raise AvdbError("AVDB 令牌无效（401）")
                if resp.status_code >= 400:
                    raise AvdbError(f"AVDB HTTP {resp.status_code}")
                length = resp.headers.get("content-length")
                if length and length.isdigit() and int(length) > MAX_IMAGE_BYTES:
                    raise AvdbError("AVDB 返回内容过大，已拒绝")
                chunks: list[bytes] = []
                total = 0
                for chunk in resp.iter_bytes():
                    total += len(chunk)
                    if total > MAX_IMAGE_BYTES:
                        raise AvdbError("AVDB 返回内容过大，已拒绝")
                    chunks.append(chunk)
    except AvdbError:
        raise
    except Exception as e:
        raise AvdbError(f"连接失败: {e}") from e
    return b"".join(chunks)


def probe(
    base_url: str,
    api_key: str,
    *,
    timeout: float | None = None,
) -> dict[str, Any]:
    """用给定地址与令牌探一次 torrents 接口，不读写配置，供「测试连接」直接验证草稿。"""
    base = normalize_base(base_url)
    if not base:
        return {"ok": False, "configured": False, "baseUrl": "", "message": "地址无效"}
    key = str(api_key or "").strip()
    if not key:
        return {
            "ok": False,
            "configured": False,
            "baseUrl": base,
            "message": "未配置 API 令牌",
        }
    try:
        with httpx.Client(
            timeout=float(timeout or DEFAULT_TIMEOUT_S),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            resp = client.get(
                f"{base}{TORRENTS_PATH}",
                params={"keyword": _PROBE_KEYWORD},
                headers={"X-API-Key": key},
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
    if payload.get("code") not in (None, 0):
        return {
            "ok": False,
            "configured": True,
            "baseUrl": base,
            "message": str(payload.get("message") or "接口返回异常"),
        }
    return {"ok": True, "configured": True, "baseUrl": base, "message": "令牌有效"}


def health() -> dict[str, Any]:
    cfg = get_config(include_secrets=True)
    base = str(cfg["baseUrl"])
    if not base:
        return {"ok": False, "configured": False, "baseUrl": "", "message": "未配置"}
    if not cfg["enabled"]:
        return {"ok": False, "configured": False, "baseUrl": base, "message": "已停用"}
    return probe(
        base,
        str(cfg.get("apiKey") or ""),
        timeout=float(cfg["timeoutSec"]),
    )
