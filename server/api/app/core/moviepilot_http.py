"""MoviePilot HTTP 访问层：请求封装、路径校验与进程内缓存。"""

import time
from typing import Any
from urllib.parse import quote

import httpx
from fastapi import HTTPException

from app.core.moviepilot_config import get_config
from app.core.moviepilot_normalize import _normalize_item

_CACHE_TTL_S = 300.0
_cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}
_detail_cache: dict[str, tuple[float, Any]] = {}
_person_cache: dict[str, tuple[float, Any]] = {}
_search_cache: dict[str, tuple[float, Any]] = {}

_SEARCH_CACHE_TTL_S = 120.0
# PT 站点搜索逐页拉取的总预算：避免 10 页 × 60s 串行拖到 10 分钟
_PT_SEARCH_BUDGET_S = 30.0

# 提交下载时要把搜索结果里的 torrent_info（含站点 Cookie / UA）原样回传给 MP，
# 这些字段不适合透出到前端，按资源生成 downloadKey 在服务端短时缓存。
_DOWNLOAD_CACHE_TTL_S = 1800.0
_download_cache: dict[
    str, tuple[float, list[tuple[dict[str, Any], dict[str, Any]]]]
] = {}

# 豆瓣详情里的演员是旧版 celebrity id，MoviePilot 只认新版 personage id：
# 用旧 id 请求 MP 只会拿到空壳（name 为 null）。这里借豆瓣 rexxar 接口取
# personage id（payload.id）做一次换算并缓存。
_DOUBAN_REXXAR_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
)
_DOUBAN_MAP_TTL_S = 86400.0
_douban_personage_cache: dict[str, tuple[float, str | None]] = {}


def _guard_path(path: str) -> str:
    """拒绝路径段穿越（``..`` / ``.`` / 空段 / 反斜杠），返回清理后的路径。"""
    text = (path or "").strip().strip("/")
    parts = text.split("/")
    if not text or any(p in {"", ".", ".."} or "\\" in p for p in parts):
        raise HTTPException(status_code=400, detail="非法的 MoviePilot 路径")
    return text


def _seg(value: str, field: str = "ID") -> str:
    """用户传入的路径段：拒绝穿越字符后做 URL 编码。"""
    text = (value or "").strip()
    if not text or "/" in text or "\\" in text or "%" in text or ".." in text:
        raise HTTPException(status_code=400, detail=f"{field} 非法")
    return quote(text, safe="")


def _mp_get(
    path: str, params: dict[str, str] | None = None, *, timeout_s: float | None = None
) -> Any:
    path = _guard_path(path)
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise HTTPException(status_code=400, detail="MoviePilot 未启用")
    base = str(cfg["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="MoviePilot 未配置服务地址")
    try:
        with httpx.Client(
            timeout=float(timeout_s or cfg["timeoutSec"]),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            resp = client.get(
                f"{base}/api/v1/{path}",
                params={**(params or {}), "apikey": str(cfg.get("apiKey") or "")},
            )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"MoviePilot 请求失败: {e}") from e
    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502, detail=f"MoviePilot 返回 HTTP {resp.status_code}"
        )
    try:
        payload = resp.json()
    except ValueError as e:
        raise HTTPException(status_code=502, detail="MoviePilot 响应不是 JSON") from e
    if isinstance(payload, dict) and payload.get("success") is False:
        raise HTTPException(
            status_code=502,
            detail=str(payload.get("message") or "MoviePilot 接口返回异常"),
        )
    return payload.get("data") if isinstance(payload, dict) else payload


def _mp_post(
    path: str, body: dict[str, Any], *, timeout_s: float | None = None
) -> dict[str, Any]:
    """POST 到 MoviePilot，返回原始响应体（success=false 交由调用方判定）。"""
    path = _guard_path(path)
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise HTTPException(status_code=400, detail="MoviePilot 未启用")
    base = str(cfg["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="MoviePilot 未配置服务地址")
    try:
        with httpx.Client(
            timeout=float(timeout_s or cfg["timeoutSec"]),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            resp = client.post(
                f"{base}/api/v1/{path}",
                params={"apikey": str(cfg.get("apiKey") or "")},
                json=body,
            )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"MoviePilot 请求失败: {e}") from e
    if resp.status_code == 401:
        raise HTTPException(status_code=502, detail="MoviePilot 令牌无效（401）")
    try:
        payload = resp.json()
    except ValueError as e:
        raise HTTPException(
            status_code=502, detail=f"MoviePilot 返回 HTTP {resp.status_code}"
        ) from e
    if not isinstance(payload, dict):
        raise HTTPException(status_code=502, detail="MoviePilot 响应格式异常")
    return payload


def _mp_get_rows(path: str) -> list[dict[str, Any]]:
    try:
        rows = _mp_get(path)
    except HTTPException:
        return []
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def _fetch_list(path: str, params: dict[str, str]) -> list[dict[str, Any]]:
    path = _guard_path(path)
    key = path + "?" + "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    now = time.time()
    hit = _cache.get(key)
    if hit and now - hit[0] < _CACHE_TTL_S:
        return hit[1]

    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise HTTPException(status_code=400, detail="MoviePilot 未启用")
    base = str(cfg["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="MoviePilot 未配置服务地址")
    api_key = str(cfg.get("apiKey") or "")
    try:
        with httpx.Client(
            timeout=float(cfg["timeoutSec"]), trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(
                f"{base}/api/v1/{path}", params={**params, "apikey": api_key}
            )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"MoviePilot 请求失败: {e}") from e
    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502, detail=f"MoviePilot 返回 HTTP {resp.status_code}"
        )
    try:
        payload = resp.json()
    except ValueError as e:
        raise HTTPException(status_code=502, detail="MoviePilot 响应不是 JSON") from e
    if not isinstance(payload, dict):
        raise HTTPException(status_code=502, detail="MoviePilot 响应格式异常")
    if payload.get("success") is False:
        raise HTTPException(
            status_code=502,
            detail=str(payload.get("message") or "MoviePilot 接口返回异常"),
        )
    raw_items = payload.get("data")
    if not isinstance(raw_items, list):
        raw_items = []
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in raw_items:
        item = _normalize_item(raw)
        if not item:
            continue
        uniq = f"{item['source']}:{item['id']}"
        if uniq in seen:
            continue
        seen.add(uniq)
        items.append(item)
    _cache[key] = (now, items)
    if len(_cache) > 256:
        _cache.clear()
    return items


def _douban_personage_id(celebrity_id: str) -> str | None:
    key = celebrity_id.strip()
    if not key:
        return None
    now = time.time()
    hit = _douban_personage_cache.get(key)
    if hit and now - hit[0] < _DOUBAN_MAP_TTL_S:
        return hit[1]
    resolved: str | None = None
    try:
        with httpx.Client(
            timeout=8.0, trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(
                f"https://m.douban.com/rexxar/api/v2/celebrity/{key}",
                headers={
                    "User-Agent": _DOUBAN_REXXAR_UA,
                    "Referer": f"https://m.douban.com/movie/celebrity/{key}/",
                },
            )
        if resp.status_code < 400:
            payload = resp.json()
            if str(payload.get("subtype") or "") == "person":
                pid = str(payload.get("id") or "").strip()
                if pid and pid != key:
                    resolved = pid
    except Exception:
        resolved = None
    if len(_douban_personage_cache) > 512:
        _douban_personage_cache.clear()
    _douban_personage_cache[key] = (now, resolved)
    return resolved
