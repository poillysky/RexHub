"""能力注册与调度中心。

插件通过 Manifest 声明 ``capabilities`` 与 ``endpoints``，Core 只按能力调度，
不按插件名称写死业务逻辑。调度顺序：按插件声明的 ``priority``（默认 100）
升序，逐个尝试；单个插件失败自动换下一个，全部失败返回 503。

统一返回：

    {"ok": true, "capability": "…", "provider": "…", "data": {…}}
"""


import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from app.rexhub import network_store
from app.rexhub.plugin_framework import runtime, store

TIMEOUT = 20
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
_PLACEHOLDER_RE = re.compile(r"\{([A-Za-z0-9_.-]+)\}")
_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}


def _open(url: str, request: urllib.request.Request, timeout: float):
    """本机插件地址必须直连，避免把 127.0.0.1 的调度请求送进代理。"""
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    if host in _LOCAL_HOSTS:
        return network_store.open_direct(request, timeout)
    return network_store.open_plugin_url(request, timeout)


class DispatchError(RuntimeError):
    """所有可用插件都未能完成请求。"""


def _plugins_with(capability: str) -> list[dict[str, Any]]:
    items = []
    for row in store.list_plugins():
        if not row.get("enabled"):
            continue
        capabilities = row.get("capabilities") if isinstance(row.get("capabilities"), list) else []
        endpoints = row.get("endpoints") if isinstance(row.get("endpoints"), dict) else {}
        if capability not in capabilities or not endpoints.get(capability):
            continue
        items.append(row)
    items.sort(key=lambda row: int(row.get("priority") or 100))
    return items


def providers(capability: str) -> list[dict[str, Any]]:
    """列出某能力的插件（不启动插件，只报告当前可达地址）。"""
    result = []
    for row in _plugins_with(capability):
        info = runtime.status(row)
        spec = row["endpoints"][capability]
        endpoint = spec.get("path") if isinstance(spec, dict) else spec
        result.append(
            {
                "id": row["id"],
                "name": row.get("name") or row["id"],
                "category": row.get("category") or "",
                "capability": capability,
                "endpoint": endpoint,
                "running": bool(info.get("running")),
                "base_url": info.get("base_url") or "",
                "runtime": (row.get("runtime") or {}).get("type") or "isolated",
            }
        )
    return result


def _fill_endpoint(endpoint: str, payload: dict[str, Any]) -> str:
    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        value = payload.get(key, "")
        return urllib.parse.quote(str(value), safe="")

    return _PLACEHOLDER_RE.sub(replace, endpoint)


def _call(url: str, payload: dict[str, Any], method: str, timeout: int, headers: dict[str, str]) -> Any:
    data = None
    query = ""
    if method == "GET":
        query = urllib.parse.urlencode(
            {key: value for key, value in payload.items() if not isinstance(value, (dict, list))}
        )
        if query:
            url = f"{url}{'&' if '?' in url else '?'}{query}"
    else:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            **headers,
        },
        method=method,
    )
    try:
        with _open(url, request, timeout) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raw = exc.read(MAX_RESPONSE_BYTES + 1)
        try:
            body = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            body = {}
        message = (body.get("error") or {}).get("message") if isinstance(body, dict) else ""
        raise RuntimeError(f"插件返回 HTTP {exc.code}：{message or '请求失败'}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError("无法连接插件") from exc
    if len(raw) > MAX_RESPONSE_BYTES:
        raise RuntimeError("插件返回内容过大")
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError as exc:
        raise RuntimeError("插件返回不是合法 JSON") from exc


def dispatch(
    capability: str,
    payload: dict[str, Any] | None = None,
    *,
    method: str = "POST",
    timeout: int = TIMEOUT,
) -> dict[str, Any]:
    rows = _plugins_with(capability)
    if not rows:
        raise DispatchError(f"没有可用的插件处理 {capability}")
    errors: list[str] = []
    for row in rows:
        try:
            base = runtime.base_url(row)
        except (RuntimeError, ValueError) as exc:
            errors.append(f"{row['id']}: {exc}")
            continue
        spec = row["endpoints"][capability]
        if isinstance(spec, dict):
            endpoint = _fill_endpoint(str(spec.get("path") or ""), payload or {})
            call_method = str(spec.get("method") or method).upper()
        else:
            endpoint = _fill_endpoint(str(spec), payload or {})
            call_method = method.upper()
        runtime_spec = row.get("runtime") if isinstance(row.get("runtime"), dict) else {}
        headers = runtime_spec.get("headers") if isinstance(runtime_spec.get("headers"), dict) else {}
        url = f"{base}{endpoint}"
        try:
            data = _call(url, payload or {}, call_method, timeout, headers)
        except RuntimeError as exc:
            errors.append(f"{row['id']}: {exc}")
            continue
        return {
            "ok": True,
            "capability": capability,
            "provider": row["id"],
            "provider_name": row.get("name") or row["id"],
            "data": data,
            "fetched_at": int(time.time()),
        }
    raise DispatchError(f"{capability} 调用失败：{'；'.join(errors)}")


def health(row: dict[str, Any]) -> dict[str, Any]:
    """插件健康检查：GET manifest.healthcheck，缺省用 /。"""
    info = runtime.status(row)
    if not info.get("running"):
        return {"ok": False, "status": 0, "error": info.get("error") or "插件未运行"}
    base = str(info.get("base_url") or "").rstrip("/")
    if not base:
        return {"ok": False, "status": 0, "error": "插件未分配地址"}
    path = str(row.get("healthcheck") or "/")
    url = f"{base}{path}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    try:
        with _open(url, request, 8) as response:
            status_code = int(getattr(response, "status", None) or response.getcode() or 200)
            response.read(1024 * 1024)
        return {"ok": status_code < 500, "status": status_code, "url": url, "error": ""}
    except urllib.error.HTTPError as exc:
        return {"ok": exc.code < 500, "status": int(exc.code), "url": url, "error": ""}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {"ok": False, "status": 0, "url": url, "error": str(exc)}
