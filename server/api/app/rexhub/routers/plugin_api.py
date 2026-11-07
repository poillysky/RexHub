"""统一插件 API（/api/v1/plugins）。

iOS 只调用这里的接口，不感知插件协议。Widget JS、Stremio、独立进程的结果
都在服务端归一为 RexHub DTO 后返回。
"""


import re
import urllib.parse
import urllib.request

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.rexhub import addons_store, network_store
from app.rexhub.auth_guard import require_session, session_token
from app.rexhub.plugin_framework import dispatcher, dto, manager, runtime, store

router = APIRouter(prefix="/api/v1/plugins", tags=["plugins"])

_ASSET_KEYS = {
    "cover",
    "coverUrl",
    "cover_url",
    "poster",
    "posterPath",
    "poster_path",
    "backdrop",
    "backdropPath",
    "backdrop_path",
    "detailPoster",
    "pic",
    "image",
    "thumbnail",
}
MAX_ASSET_BYTES = 12 * 1024 * 1024


def _origin_of(request: Request) -> str:
    scheme = request.headers.get("x-forwarded-proto") or request.url.scheme
    host = request.headers.get("x-forwarded-host") or request.headers.get("host")
    host = host or request.url.netloc
    return f"{scheme}://{host}".rstrip("/")


def _rewrite_assets(value: object, base: str, plugin_id: str, token: str) -> object:
    """把插件返回的相对资源地址（如 /v1/cover?url=…）改写为服务端可访问的绝对地址。"""
    if isinstance(value, dict):
        for key in list(value.keys()):
            item = value[key]
            if (
                isinstance(item, str)
                and item.startswith("/")
                and not item.startswith("//")
                and str(key) in _ASSET_KEYS
            ):
                url = (
                    f"{base}/api/v1/plugins/{urllib.parse.quote(plugin_id)}/media"
                    f"?path={urllib.parse.quote(item, safe='')}"
                )
                if token:
                    url += f"&token={urllib.parse.quote(token, safe='')}"
                value[key] = url
            elif isinstance(item, (dict, list)):
                _rewrite_assets(item, base, plugin_id, token)
    elif isinstance(value, list):
        for item in value:
            _rewrite_assets(item, base, plugin_id, token)
    return value


class ExecuteBody(BaseModel):
    moduleId: str
    params: dict = Field(default_factory=dict)


class SearchBody(BaseModel):
    params: dict = Field(default_factory=dict)


class DetailBody(BaseModel):
    link: str = ""


class ParamsBody(BaseModel):
    params: dict = Field(default_factory=dict)


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content={"success": False, "error": {"code": code, "message": message}},
    )


def _module_type(plugin_id: str, module_id: str) -> str:
    if plugin_id.startswith("stremio:"):
        if module_id == "stream":
            return "stream"
        if module_id == "subtitles":
            return "subtitle"
        if module_id == "meta":
            return "detail"
        if module_id.startswith("catalog:"):
            return "catalog"
        return ""
    try:
        meta = store.get_plugin(plugin_id).get("widget_meta") or {}
    except ValueError:
        return ""
    for module in meta.get("modules") or []:
        if str(module.get("id") or "") == module_id:
            return str(module.get("type") or "")
    if module_id == "loadResource":
        return "stream"
    if module_id == "loadSubtitle":
        return "subtitle"
    return ""


def _envelope(
    plugin_id: str,
    module_id: str,
    result: dict,
    data: object,
) -> dict:
    return {
        "success": True,
        "pluginId": plugin_id,
        "moduleId": module_id,
        "data": data,
        "cached": bool(result.get("cached")),
        "executionTime": int(result.get("executionTime") or 0),
    }


def _run(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except addons_store.UpstreamError as exc:
        return _error(502, "NETWORK_ERROR", str(exc))
    except ValueError as exc:
        message = str(exc)
        if "不存在" in message:
            return _error(404, "PLUGIN_NOT_FOUND", message)
        if "停用" in message:
            return _error(403, "PLUGIN_DISABLED", message)
        return _error(400, "INVALID_PARAMS", message)
    except RuntimeError as exc:
        message = str(exc)
        if "超时" in message:
            return _error(504, "PLUGIN_TIMEOUT", message)
        return _error(502, "PLUGIN_RUNTIME_ERROR", message)


@router.get("")
def list_plugins(_user: dict = Depends(require_session)) -> dict:
    return {"success": True, "data": manager.plugin_catalog()}


@router.get("/{plugin_id}")
def plugin_detail(plugin_id: str, _user: dict = Depends(require_session)) -> dict:
    try:
        return {"success": True, "data": manager.plugin_detail(plugin_id)}
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.api_route(
    "/{plugin_id}/proxy/{capability}", methods=["GET", "POST"], tags=["plugins"]
)
async def proxy_plugin(
    plugin_id: str,
    capability: str,
    request: Request,
    _user: dict = Depends(require_session),
):
    """导出 JS 使用的服务端转发：按插件声明的 capability 直接转发到插件接口。"""
    try:
        row = store.get_plugin(plugin_id)
        if not row.get("enabled"):
            raise ValueError("插件已停用")
        endpoints = row.get("endpoints") if isinstance(row.get("endpoints"), dict) else {}
        spec = endpoints.get(capability)
        if not spec:
            raise ValueError("插件未声明该能力接口")
        if isinstance(spec, dict):
            path = str(spec.get("path") or "")
            method = str(spec.get("method") or "GET").upper()
        else:
            path = str(spec)
            method = "GET"
        if not path:
            raise ValueError("插件接口路径为空")
        params = dict(request.query_params)
        if request.method == "POST":
            try:
                body = await request.json()
            except ValueError:
                body = {}
            if isinstance(body, dict):
                params.update({str(k): v for k, v in body.items()})
        path = re.sub(
            r"\{([A-Za-z0-9_.-]+)\}",
            lambda m: urllib.parse.quote(str(params.get(m.group(1)) or ""), safe=""),
            path,
        )
        base = runtime.base_url(row)
        data = dispatcher._call(f"{base}{path}", params, method, 30, {})
        data = _rewrite_assets(
            data, _origin_of(request), plugin_id, session_token(request)
        )
        return JSONResponse(content=data)
    except ValueError as exc:
        return _error(400, "INVALID_PARAMS", str(exc))
    except RuntimeError as exc:
        return _error(502, "PLUGIN_RUNTIME_ERROR", str(exc))


@router.get("/{plugin_id}/media")
def plugin_media(
    plugin_id: str,
    request: Request,
    path: str = "",
    token: str = "",
):
    """转发插件产出的图片等资源；支持 token 查询参数，供图片加载器使用。"""
    try:
        require_session(request, token or None)
        row = store.get_plugin(plugin_id)
        if not row.get("enabled"):
            raise ValueError("插件已停用")
        if not path.startswith("/") or "://" in path:
            raise ValueError("资源路径不合法")
        base = runtime.base_url(row)
        url = f"{base}{path}"
        extra = {
            key: value
            for key, value in request.query_params.items()
            if key not in ("path", "token")
        }
        if extra:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(extra)
        upstream = urllib.request.Request(
            url, headers={"Accept": request.headers.get("accept") or "*/*"}
        )
        with network_store.open_direct(upstream, 30) as resp:
            body = resp.read(MAX_ASSET_BYTES + 1)
            content_type = str(resp.headers.get("content-type") or "application/octet-stream")
        if len(body) > MAX_ASSET_BYTES:
            raise ValueError("资源体积过大")
        return Response(
            content=body,
            media_type=content_type.split(";", 1)[0],
            headers={"Cache-Control": "public, max-age=600"},
        )
    except ValueError as exc:
        return _error(400, "INVALID_PARAMS", str(exc))
    except RuntimeError as exc:
        return _error(502, "PLUGIN_RUNTIME_ERROR", str(exc))


@router.get("/{plugin_id}/playback/url")
async def playback_url(
    plugin_id: str,
    request: Request,
    _user: dict = Depends(require_session),
):
    """返回 App 可直连的插件播放地址，播放流量不经过 RexHub 中转。"""
    try:
        row = store.get_plugin(plugin_id)
        if not row.get("enabled"):
            raise ValueError("插件已停用")
        endpoints = row.get("endpoints") if isinstance(row.get("endpoints"), dict) else {}
        spec = endpoints.get("playback.stream")
        if not spec:
            raise ValueError("插件未声明 playback.stream 接口")
        path = str(spec.get("path") if isinstance(spec, dict) else spec or "")
        if not path:
            raise ValueError("插件播放接口路径为空")
        params = dict(request.query_params)
        path = re.sub(
            r"\{([A-Za-z0-9_.-]+)\}",
            lambda m: urllib.parse.quote(str(params.get(m.group(1)) or ""), safe=""),
            path,
        )
        base = runtime.base_url(row)
        parsed = urllib.parse.urlparse(base)
        host = request.url.hostname or parsed.hostname or "127.0.0.1"
        port = parsed.port
        public = f"http://{host}:{port}" if port else f"{parsed.scheme}://{host}"
        url = f"{public}{path}"
        query = urllib.parse.urlencode(params)
        if query:
            url = f"{url}{'&' if '?' in url else '?'}{query}"
        return {"success": True, "url": url, "headers": {}}
    except ValueError as exc:
        return _error(400, "INVALID_PARAMS", str(exc))
    except RuntimeError as exc:
        return _error(502, "PLUGIN_RUNTIME_ERROR", str(exc))


@router.post("/{plugin_id}/execute")
def execute(
    plugin_id: str, body: ExecuteBody, _user: dict = Depends(require_session)
):
    result = _run(manager.execute, plugin_id, body.moduleId, body.params)
    if isinstance(result, JSONResponse):
        return result
    module_type = _module_type(plugin_id, body.moduleId)
    if module_type == "stream":
        data = dto.video_resources(result.get("data"))
    elif module_type == "subtitle":
        data = dto.subtitles(result.get("data"))
    elif module_type == "danmu":
        data = result.get("data")
    elif module_type == "detail":
        data = result.get("data")
    else:
        data = dto.resources(plugin_id, result.get("data"))
    return _envelope(plugin_id, body.moduleId, result, data)


@router.post("/{plugin_id}/search")
def search(plugin_id: str, body: SearchBody, _user: dict = Depends(require_session)):
    result = _run(manager.search, plugin_id, body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(plugin_id, "search", result, dto.resources(plugin_id, result.get("data")))


@router.post("/{plugin_id}/detail")
def detail(plugin_id: str, body: DetailBody, _user: dict = Depends(require_session)):
    result = _run(manager.detail, plugin_id, body.link)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(plugin_id, "loadDetail", result, dto.detail(plugin_id, result.get("data")))


@router.post("/{plugin_id}/resource")
def resource(plugin_id: str, body: ParamsBody, _user: dict = Depends(require_session)):
    result = _run(manager.resource, plugin_id, body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(plugin_id, "loadResource", result, dto.video_resources(result.get("data")))


@router.post("/{plugin_id}/subtitle")
def subtitle(plugin_id: str, body: ParamsBody, _user: dict = Depends(require_session)):
    result = _run(manager.subtitle, plugin_id, body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(plugin_id, "loadSubtitle", result, dto.subtitles(result.get("data")))


@router.post("/{plugin_id}/subtitle/archive")
def subtitle_archive(plugin_id: str, body: ParamsBody, _user: dict = Depends(require_session)):
    result = _run(manager.subtitle_archive, plugin_id, body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(
        plugin_id, "resolveSubtitleArchive", result, result.get("data")
    )


@router.post("/{plugin_id}/danmu/search")
def danmu_search(plugin_id: str, body: ParamsBody, _user: dict = Depends(require_session)):
    result = _run(manager.danmu, plugin_id, "search", body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(plugin_id, "searchDanmu", result, dto.danmu_search(result.get("data")))


@router.post("/{plugin_id}/danmu/detail")
def danmu_detail(plugin_id: str, body: ParamsBody, _user: dict = Depends(require_session)):
    result = _run(manager.danmu, plugin_id, "detail", body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(plugin_id, "getDetail", result, dto.danmu_episodes(result.get("data")))


@router.post("/{plugin_id}/danmu/comments")
def danmu_comments(plugin_id: str, body: ParamsBody, _user: dict = Depends(require_session)):
    result = _run(manager.danmu, plugin_id, "comments", body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(plugin_id, "getComments", result, dto.danmu_comments(result.get("data")))


@router.post("/{plugin_id}/danmu/segment")
def danmu_segment(plugin_id: str, body: ParamsBody, _user: dict = Depends(require_session)):
    result = _run(manager.danmu, plugin_id, "segment", body.params)
    if isinstance(result, JSONResponse):
        return result
    return _envelope(
        plugin_id, "getDanmuWithSegmentTime", result, result.get("data")
    )
