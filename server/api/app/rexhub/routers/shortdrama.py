"""短剧接口：通用插件框架。

任一插件只要声明 ``shortdrama.*`` 能力，就会被当作短剧站点：

- ``shortdrama.ranks``   榜单分组（可选；未声明时合成“热门/最新”）
- ``shortdrama.catalog`` 目录
- ``shortdrama.search``  搜索
- ``shortdrama.detail``  详情（含分集）
- ``shortdrama.stream``  播放（``redirect: true`` 时 302 跳到 CDN，否则服务端透传）

红果与其它短剧插件使用同一套接口，不再有内置站点特判。
"""


import asyncio
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import RedirectResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from app.rexhub import network_store
from app.rexhub.auth_guard import require_session
from app.rexhub.plugin_framework import runtime as plugin_runtime
from app.rexhub.plugin_framework import store as plugin_store
from app.rexhub.plugin_framework.manifest import clean_icon

router = APIRouter(prefix="/api/shortdrama", tags=["shortdrama"])

TIMEOUT = 15
CACHE_TTL = 60
CACHE_MAX = 256
UPSTREAM_STREAM_HEADERS = (
    "content-type",
    "content-length",
    "content-range",
    "accept-ranges",
    "cache-control",
)
REQUIRED_CAPS = {
    "shortdrama.catalog",
    "shortdrama.search",
    "shortdrama.detail",
    "shortdrama.stream",
}
# 旧的短剧路径使用 hongguo，保留别名映射到插件 ID。
SITE_ALIASES = {"hongguo": "rexhub.hongguo.video"}
DEFAULT_DRAMA_PLUGIN = "rexhub.hongguo.video"
_PLACEHOLDER_RE = re.compile(r"\{([A-Za-z0-9_.-]+)\}")

_cache: OrderedDict[str, tuple[float, dict]] = OrderedDict()
_lock = threading.Lock()


class SiteCard(BaseModel):
    id: str
    name: str
    enabled: bool
    capabilities: list[str]
    ui: dict = Field(default_factory=dict)


class DramaCard(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site: str
    site_name: str = Field(alias="siteName")
    id: str
    title: str
    cover: str
    description: str
    season: int
    episode_count: int = Field(alias="episodeCount")


class Episode(BaseModel):
    id: str
    title: str
    episode: int
    duration: int
    disabled: bool


class SeriesDetail(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    site: str
    site_name: str = Field(alias="siteName")
    id: str
    title: str
    cover: str
    description: str
    season: int
    episode_count: int = Field(alias="episodeCount")
    album_id: str = Field(default="", alias="albumId")
    complete: bool = True
    episodes: list[Episode]
    seasons: list[DramaCard]


class DramaPage(BaseModel):
    site: str
    site_name: str = Field(default="", alias="siteName")
    items: list[DramaCard]
    has_more: bool = Field(default=False, alias="hasMore")
    next_page: int | None = Field(default=None, alias="nextPage")


class SiteListResponse(BaseModel):
    items: list[SiteCard]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """上游 302 由我们手动处理：插件直连本地，CDN 再按网络代理配置抓取。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def _opener_direct():
    return urllib.request.build_opener(_NoRedirect)


def _cached(key: str, loader) -> dict:
    now = time.time()
    with _lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < CACHE_TTL:
            _cache.move_to_end(key)
            return hit[1]
        if hit:
            _cache.pop(key, None)
    value = loader()
    with _lock:
        _cache[key] = (now, value)
        _cache.move_to_end(key)
        # key 带插件端口，插件重启后会换 key，必须有上限兜底
        while len(_cache) > CACHE_MAX:
            _cache.popitem(last=False)
    return value


def _get_json(path: str, base: str) -> dict:
    """带短 TTL 缓存的 GET；阻塞请求放到线程池里执行。"""
    base = base.rstrip("/")

    def load() -> dict:
        request = urllib.request.Request(
            base + path,
            headers={"Accept": "application/json"},
            method="GET",
        )
        try:
            # 本地插件地址必须直连，否则启用代理后会把 127.0.0.1 送进代理导致整体不可用
            host = (urllib.parse.urlparse(base).hostname or "").lower()
            if host in {"127.0.0.1", "localhost", "::1"}:
                with network_store.open_direct(request, TIMEOUT) as response:
                    return json.loads(response.read().decode("utf-8"))
            with network_store.open_url(request, TIMEOUT, "shortdrama") as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="ignore")
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                payload = {}
            message = (payload.get("error") or {}).get("message") or "短剧服务返回异常"
            if error.code == 404:
                raise HTTPException(status_code=404, detail=message) from error
            raise HTTPException(status_code=502, detail=message) from error
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise HTTPException(status_code=503, detail="短剧服务暂不可用") from error

    return _cached(f"{base}|{path}", load)


async def _fetch_json(path: str, base: str) -> dict:
    return await asyncio.to_thread(_get_json, path, base)


def _row(site: str) -> dict:
    plugin_id = SITE_ALIASES.get(site, site)
    try:
        row = plugin_store.get_plugin(plugin_id)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="短剧站点不存在") from exc
    if not row.get("enabled"):
        raise HTTPException(
            status_code=503,
            detail=f"{row.get('name') or plugin_id}插件已停用，请到 设置 → 插件中心 启用",
        )
    capabilities = set(row.get("capabilities") or [])
    if not REQUIRED_CAPS.issubset(capabilities):
        raise HTTPException(status_code=404, detail="该插件未声明完整的短剧接口")
    return row


def _visible_rows() -> list[dict]:
    rows: list[dict] = []
    for row in plugin_store.list_plugins():
        if not row.get("enabled"):
            continue
        if str(row.get("category") or "") != "shortdrama":
            continue
        visible_value = row.get("show_in_drama")
        if visible_value is None:
            visible_value = str(row.get("id") or "") == DEFAULT_DRAMA_PLUGIN
        if not visible_value:
            continue
        if not REQUIRED_CAPS.issubset(set(row.get("capabilities") or [])):
            continue
        rows.append(row)
    return rows


def _endpoint(row: dict, capability: str) -> dict:
    endpoints = row.get("endpoints") if isinstance(row.get("endpoints"), dict) else {}
    spec = endpoints.get(capability)
    if isinstance(spec, dict):
        path = str(spec.get("path") or "").strip()
        method = str(spec.get("method") or "GET").upper()
        redirect = bool(spec.get("redirect"))
    elif isinstance(spec, str):
        path = spec.strip()
        method = "GET"
        redirect = False
    else:
        return {}
    if not path:
        return {}
    return {"path": path, "method": method, "redirect": redirect}


def _base(row: dict) -> str:
    try:
        return plugin_runtime.base_url(row)
    except (RuntimeError, ValueError) as exc:
        name = row.get("name") or row.get("id") or "短剧"
        raise HTTPException(status_code=503, detail=f"{name}插件未运行：{exc}") from exc


def _fill(path: str, params: dict) -> str:
    return _PLACEHOLDER_RE.sub(
        lambda match: urllib.parse.quote(str(params.get(match.group(1)) or ""), safe=""),
        path,
    )


def _query(params: dict) -> str:
    clean = {
        key: value
        for key, value in params.items()
        if value is not None and value != "" and not isinstance(value, (dict, list))
    }
    return urllib.parse.urlencode(clean)


def _base_async(row: dict) -> "asyncio.Future[str]":
    """启动插件会阻塞（等待 healthcheck），不能在事件循环里直接跑。"""
    return asyncio.to_thread(_base, row)


async def _call(row: dict, capability: str, params: dict) -> dict:
    spec = _endpoint(row, capability)
    if not spec:
        raise HTTPException(status_code=404, detail=f"插件未声明 {capability} 接口")
    path = _fill(spec["path"], params)
    query = _query(params)
    if query:
        path += ("&" if "?" in path else "?") + query
    base = await _base_async(row)
    return await _fetch_json(path, base)


def _safe_int(value: object, default: int = 0) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _cover(site: str, value: object) -> str:
    text = str(value or "").strip()
    if re.match(r"^https?://", text):
        return text
    if text.startswith("/") and not text.startswith("//"):
        return (
            f"/api/v1/plugins/{urllib.parse.quote(site)}/media"
            f"?path={urllib.parse.quote(text, safe='')}"
        )
    return ""


def _card(site: str, site_name: str, item: dict) -> dict:
    return {
        "site": site,
        "siteName": site_name,
        "id": str(item.get("id") or ""),
        "title": str(item.get("title") or ""),
        "cover": _cover(site, item.get("cover")),
        "description": str(item.get("description") or ""),
        "season": _safe_int(item.get("season"), 1) or 1,
        "episodeCount": _safe_int(
            item.get("episodeCount") or item.get("total") or item.get("episode_count")
        ),
    }


def _page(payload: dict, page: int, site: str, site_name: str) -> dict:
    raw_items = payload.get("items") if isinstance(payload.get("items"), list) else []
    items = [
        _card(site, site_name, item)
        for item in raw_items
        if isinstance(item, dict) and item.get("id")
    ]
    next_page = _safe_int(
        payload.get("nextPage") or payload.get("next_page")
    )
    has_more = (
        bool(payload.get("hasMore") or payload.get("has_more")) or next_page > 0
    )
    return {
        "site": site,
        "siteName": site_name,
        "items": items,
        "hasMore": has_more,
        "nextPage": next_page if has_more else None,
    }


def _site_meta(row: dict) -> tuple[str, str]:
    return str(row.get("id") or ""), str(row.get("name") or row.get("id") or "")


def _site_ui(row: dict) -> dict:
    ui = row.get("ui") if isinstance(row.get("ui"), dict) else {}
    block = dict(ui.get("shortdrama") or {})
    if "icon" in block:
        # 老版本安装的插件可能没经过 manifest 净化
        block["icon"] = clean_icon(block.get("icon"))
    logo = str(block.get("logo") or "")
    if logo.startswith("/") and not logo.startswith("//"):
        site_id, _name = _site_meta(row)
        block["logo"] = (
            f"/api/v1/plugins/{urllib.parse.quote(site_id)}/media"
            f"?path={urllib.parse.quote(logo, safe='')}"
        )
    result = dict(ui)
    result["shortdrama"] = block
    return result


@router.get("/sites", response_model=SiteListResponse)
async def list_sites(request: Request) -> SiteListResponse:
    require_session(request)
    rows = _visible_rows()
    # 插件未启动时 _base 会阻塞到 healthcheck 超时，必须并发且放到线程池
    bases = await asyncio.gather(
        *(_base_async(row) for row in rows),
        return_exceptions=True,
    )
    items: list[SiteCard] = []
    for row, base in zip(rows, bases):
        if isinstance(base, BaseException):
            continue
        site_id, name = _site_meta(row)
        items.append(
            SiteCard(
                id=site_id,
                name=name,
                enabled=True,
                capabilities=["catalog", "search", "series", "stream"],
                ui=_site_ui(row),
            )
        )
    return SiteListResponse(items=items)


@router.get("/search", response_model=DramaPage)
async def search_all(
    request: Request,
    q: str = Query(min_length=1, max_length=100),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=0, ge=0, le=24),
) -> DramaPage:
    """全局搜索：依次尝试可见站点，跳过不可用的插件。"""
    require_session(request)
    rows = _visible_rows()
    last_error: HTTPException | None = None
    for row in rows:
        site_id, name = _site_meta(row)
        params: dict[str, object] = {"q": q, "page": page}
        if limit:
            params["limit"] = limit
        try:
            payload = await _call(row, "shortdrama.search", params)
        except HTTPException as error:
            if error.status_code in (404, 502, 503):
                last_error = error
                continue
            raise
        return DramaPage(**_page(payload, page, site_id, name))
    if last_error:
        raise last_error
    raise HTTPException(status_code=503, detail="暂无可用的短剧插件")


@router.get("/{site}/catalog", response_model=DramaPage)
async def catalog(
    request: Request,
    site: str,
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=0, ge=0, le=24),
) -> DramaPage:
    require_session(request)
    row = _row(site)
    site_id, name = _site_meta(row)
    sort = str(request.query_params.get("sort") or "")
    params: dict[str, object] = {"page": page}
    if sort:
        params["sort"] = sort
    if limit:
        params["limit"] = limit
    payload = await _call(row, "shortdrama.catalog", params)
    return DramaPage(**_page(payload, page, site_id, name))


@router.get("/{site}/search", response_model=DramaPage)
async def search_site(
    request: Request,
    site: str,
    q: str = Query(min_length=1, max_length=100),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=0, ge=0, le=24),
) -> DramaPage:
    require_session(request)
    row = _row(site)
    site_id, name = _site_meta(row)
    params: dict[str, object] = {"q": q, "page": page}
    if limit:
        params["limit"] = limit
    payload = await _call(row, "shortdrama.search", params)
    return DramaPage(**_page(payload, page, site_id, name))


@router.get("/{site}/lists")
async def rank_lists(request: Request, site: str) -> dict:
    """榜单分组：优先用插件声明的 ranks，否则合成通用热门/最新。"""
    require_session(request)
    row = _row(site)
    if not _endpoint(row, "shortdrama.ranks"):
        return {
            "groups": [
                {
                    "id": "default",
                    "title": "推荐",
                    "ranks": [
                        {"id": "hot", "title": "热门", "filters": []},
                        {"id": "new", "title": "最新", "filters": []},
                    ],
                }
            ]
        }
    payload = await _call(row, "shortdrama.ranks", {})
    groups = []
    for group in payload.get("groups") or []:
        if not isinstance(group, dict):
            continue
        ranks = []
        for item in group.get("ranks") or []:
            if not isinstance(item, dict) or not item.get("id"):
                continue
            filters = []
            for filter_group in item.get("filters") or []:
                if not isinstance(filter_group, dict):
                    continue
                filter_items = [
                    {
                        "id": str(option.get("id") or ""),
                        "title": str(option.get("title") or ""),
                    }
                    for option in filter_group.get("items") or []
                    if isinstance(option, dict)
                ]
                if filter_items:
                    filters.append(
                        {
                            "title": str(filter_group.get("title") or ""),
                            "items": filter_items,
                        }
                    )
            ranks.append(
                {
                    "id": str(item.get("id") or ""),
                    "title": str(item.get("title") or ""),
                    "filters": filters,
                }
            )
        if ranks:
            groups.append(
                {
                    "id": str(group.get("id") or ""),
                    "title": str(group.get("title") or ""),
                    "ranks": ranks,
                }
            )
    return {"groups": groups}


@router.get("/{site}/rank", response_model=DramaPage)
async def rank_list(
    request: Request,
    site: str,
    group: str = Query(min_length=1, max_length=60),
    rank: str = Query(min_length=1, max_length=60),
    page: int = Query(default=1, ge=1),
    filter_id: str = Query(default="", alias="filter", max_length=60),
    limit: int = Query(default=0, ge=0, le=24),
) -> DramaPage:
    require_session(request)
    row = _row(site)
    site_id, name = _site_meta(row)
    params: dict[str, object] = {
        "group": group,
        "rank": rank,
        "filter": filter_id,
        "page": page,
    }
    if limit:
        params["limit"] = limit
    if _endpoint(row, "shortdrama.ranks"):
        payload = await _call(row, "shortdrama.ranks", params)
    else:
        payload = await _call(
            row,
            "shortdrama.catalog",
            {"category": rank or "hot", "page": page, **({"limit": limit} if limit else {})},
        )
    return DramaPage(**_page(payload, page, site_id, name))


@router.get("/{site}/series/{series_id}", response_model=SeriesDetail)
async def series(
    site: str,
    series_id: str,
    request: Request,
) -> SeriesDetail:
    require_session(request)
    row = _row(site)
    site_id, name = _site_meta(row)
    payload = await _call(row, "shortdrama.detail", {"id": series_id})
    if not isinstance(payload, dict):
        raise HTTPException(status_code=502, detail="短剧详情返回异常")
    card = _card(site_id, name, payload)
    raw_episodes = payload.get("episodes") if isinstance(payload.get("episodes"), list) else []
    episodes = [
        Episode(
            id=str(item.get("id") or ""),
            title=str(item.get("title") or ""),
            episode=_safe_int(item.get("episode"), index + 1) or index + 1,
            duration=_safe_int(item.get("duration")),
            disabled=bool(item.get("disabled")),
        )
        for index, item in enumerate(raw_episodes)
        if isinstance(item, dict)
    ]
    raw_seasons = payload.get("seasons")
    seasons = [
        DramaCard(**_card(site_id, name, item))
        for item in (raw_seasons if isinstance(raw_seasons, list) else [])
        if isinstance(item, dict) and item.get("id")
    ] or [DramaCard(**card)]
    return SeriesDetail(
        site=site_id,
        siteName=name,
        id=card["id"] or series_id,
        title=card["title"],
        cover=card["cover"],
        description=card["description"],
        season=card["season"],
        episodeCount=card["episodeCount"] or len(episodes),
        albumId="",
        # 插件历史字段是 finished，统一按 complete 语义暴露
        complete=bool(payload.get("complete", payload.get("finished", True))),
        episodes=episodes,
        seasons=seasons,
    )


@router.get("/{site}/episodes/{episode_id}/stream")
async def stream(
    site: str,
    episode_id: str,
    request: Request,
    token: str | None = Query(default=None),
):
    """播放：插件声明 redirect 时直接 302 到 CDN，否则透传插件流。"""
    require_session(request, token)
    row = _row(site)
    spec = _endpoint(row, "shortdrama.stream")
    if not spec:
        raise HTTPException(status_code=404, detail="插件未声明播放接口")
    base = await _base_async(row)
    if spec["redirect"]:
        payload = await _call(
            row, "shortdrama.stream", {"id": episode_id, "json": "1"}
        )
        target = str(payload.get("url") or "")
        if not target:
            raise HTTPException(status_code=502, detail="播放地址为空")
        return RedirectResponse(target, status_code=302)
    url = f"{base}{_fill(spec['path'], {'id': episode_id})}"
    headers = {}
    range_header = request.headers.get("range")
    if range_header:
        headers["Range"] = range_header

    def open_upstream():
        request = urllib.request.Request(url, headers=headers, method="GET")
        # 先直连本地插件；插件返回 302 时再按网络代理抓取 CDN。
        try:
            return _opener_direct().open(request, timeout=20)
        except urllib.error.HTTPError as error:
            if error.code not in (301, 302, 303, 307, 308):
                raise
            target = error.headers.get("Location") or ""
            error.close()
            if not target:
                raise
            target = urllib.parse.urljoin(url, target)
            follow = urllib.request.Request(
                target,
                headers={
                    "User-Agent": (
                        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                        "AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
                    ),
                    "Accept": "*/*",
                    **headers,
                },
                method="GET",
            )
            return network_store.open_plugin_url(follow, 30)

    try:
        upstream = await asyncio.to_thread(open_upstream)
    except urllib.error.HTTPError as error:
        raise HTTPException(status_code=502, detail="播放源请求失败") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise HTTPException(status_code=503, detail="播放源暂不可用") from error

    response_headers = {
        key: upstream.headers.get(key)
        for key in UPSTREAM_STREAM_HEADERS
        if upstream.headers.get(key)
    }

    # 插件解码失败时可能把错误页当视频返回，直接拦掉避免播放器黑屏
    content_type = (
        str(upstream.headers.get("content-type") or "").split(";")[0].strip().lower()
    )
    if content_type in {"application/json", "text/html", "text/plain"}:
        upstream.close()
        raise HTTPException(status_code=502, detail="播放源返回异常内容，请切换剧集重试")
    if (
        content_type.startswith(("video/", "audio/"))
        and "accept-ranges" not in response_headers
    ):
        response_headers["accept-ranges"] = "bytes"

    def chunks():
        try:
            while True:
                chunk = upstream.read(64 * 1024)
                if not chunk:
                    break
                yield chunk
        finally:
            upstream.close()

    return StreamingResponse(
        chunks(),
        status_code=upstream.status,
        headers=response_headers,
        media_type=upstream.headers.get("content-type") or "video/mp4",
    )
