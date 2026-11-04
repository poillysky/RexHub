"""短剧聚合接口：把上游短剧数据解析成 App 可用的统一模型。

上游有两种形态：
1. 多站点（/v1/sites、/v1/sites/{site}/...），逐个站点聚合；
2. 单站点（hongguo-api，/v1/catalog、/v1/search、/v1/series/{id}），
   自动识别后合成一个虚拟站点「红果漫剧」，App 侧协议不变。
播放流按 Range 原样转发，App 只连 RexHub，不直接依赖上游。
"""


import asyncio
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from app.rexhub import network_store, plugin_runtime, plugins_store
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/shortdrama", tags=["shortdrama"])

TIMEOUT = 15
CACHE_TTL = 60
UPSTREAM_STREAM_HEADERS = (
    "content-type",
    "content-length",
    "content-range",
    "accept-ranges",
    "cache-control",
)

_cache: dict[str, tuple[float, dict]] = {}
_single_sites: dict[str, bool] = {}
# 插件只返回数组时，用首页条数推断是否还有下一页
_page_sizes: dict[str, int] = {}
_lock = threading.Lock()

# 单站点上游对外合成的虚拟站点
SINGLE_SITE = {
    "id": "hongguo",
    "name": "红果漫剧",
    "enabled": True,
    "capabilities": ["catalog", "search", "series", "stream"],
}


class SiteCard(BaseModel):
    id: str
    name: str
    enabled: bool
    capabilities: list[str]


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



def _cached(key: str, loader) -> dict:
    now = time.time()
    with _lock:
        hit = _cache.get(key)
    if hit and now - hit[0] < CACHE_TTL:
        return hit[1]
    value = loader()
    with _lock:
        _cache[key] = (now, value)
    return value


def _base_url() -> str:
    base = plugins_store.shortdrama_base_url()
    if not base:
        raise HTTPException(
            status_code=503,
            detail="未配置短剧聚合 API 地址，请在插件管理中编辑插件填写接口地址",
        )
    return base


def _get_json(path: str, base: str | None = None) -> dict:
    """带短 TTL 缓存的 GET；阻塞请求放到线程池里执行。"""
    base = base or _base_url()

    def load() -> dict:
        request = urllib.request.Request(
            base + path,
            headers={"Accept": "application/json"},
            method="GET",
        )
        try:
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


async def _fetch_json(path: str, base: str | None = None) -> dict:
    return await asyncio.to_thread(_get_json, path, base)


DRAMA_CATEGORIES = {"drama", "短剧"}


def _drama_provider() -> tuple[dict, str, dict] | None:
    """找一个可执行的明文短剧插件，列表/搜索/取流都由它完成。"""
    data = plugins_store.snapshot()
    candidates: list[dict] = [
        row
        for row in data.get("plugins") or []
        if str(row.get("category") or "") in DRAMA_CATEGORIES
    ]
    for feed in data.get("feeds") or []:
        for item in feed.get("widgets") or []:
            category = str(item.get("category") or "")
            label = f"{item.get('id')} {item.get('title')}".lower()
            # 订阅索引没有分类字段，按名称识别短剧模块
            if category in DRAMA_CATEGORIES or (
                not category and ("drama" in label or "短剧" in label)
            ):
                candidates.append(item)
    for row in candidates:
        if not row.get("enabled", True):
            continue
        full, source = plugins_store.find_with_source(str(row.get("id") or ""))
        if not full or not source or plugin_runtime.is_encrypted(source):
            continue
        analysis = plugin_runtime.analysis_of(full, source)
        if not analysis.get("ok"):
            continue
        modules = plugin_runtime.modules_of(analysis)
        if not any(plugin_runtime.module_kind(item) == "catalog" for item in modules):
            continue
        return full, source, analysis
    return None


def _provider_function(analysis: dict, keyword: str | None = None, sort: str | None = None, stream: bool = False) -> str:
    modules = plugin_runtime.modules_of(analysis)
    if stream:
        module = next(
            (item for item in modules if plugin_runtime.module_kind(item) == "stream"), None
        )
        return str((module or {}).get("function") or "")
    if keyword:
        return str((analysis.get("search") or {}).get("function") or "")
    wanted = "latest" if sort else "catalog"
    for item in modules:
        if str(item.get("id")) == wanted and item.get("function"):
            return str(item["function"])
    for item in modules:
        if plugin_runtime.module_kind(item) == "catalog" and item.get("function"):
            return str(item["function"])
    return ""


def _plugin_run(provider: tuple[dict, str, dict], function: str, extra: dict, cache: bool = True):
    row, source, analysis = provider
    params = plugin_runtime.build_params(row, analysis, extra)
    if not cache:
        return plugin_runtime.run_function(source, function, params)
    key = f"plugin|{row.get('id')}|{function}|{json.dumps(params, sort_keys=True, ensure_ascii=False)}"
    return _cached(key, lambda: plugin_runtime.run_function(source, function, params))


def _plugin_cards(value: object) -> list[dict]:
    if isinstance(value, dict):
        value = value.get("items") or value.get("list") or value.get("data") or []
    cards: list[dict] = []
    for item in value if isinstance(value, list) else []:
        if not isinstance(item, dict):
            continue
        raw_id = str(item.get("id") or "")
        content_id = raw_id[raw_id.rfind(":") + 1 :] if ":" in raw_id else raw_id
        remark = str(item.get("remark") or "")
        match = re.search(r"(\d+)", remark)
        cards.append(
            {
                "site": SINGLE_SITE["id"],
                "siteName": SINGLE_SITE["name"],
                "id": content_id,
                "title": str(item.get("title") or item.get("name") or ""),
                "cover": _cover(
                    item.get("coverUrl") or item.get("cover") or item.get("posterPath")
                ),
                "description": str(item.get("description") or ""),
                "season": 1,
                "episodeCount": int(match.group(1)) if match else 0,
            }
        )
    return cards


def _plugin_page(provider: tuple[dict, str, dict], function: str, extra: dict) -> dict:
    value = _plugin_run(provider, function, extra)
    cards = _plugin_cards(value)
    page = int(extra.get("page") or 1)
    has_more: bool | None = None
    if isinstance(value, dict):
        if isinstance(value.get("hasMore"), bool):
            has_more = value["hasMore"]
        elif value.get("nextPage") is not None:
            has_more = bool(value.get("nextPage"))
    if has_more is None:
        key = f"{provider[0].get('id')}|{function}"
        with _lock:
            full = _page_sizes.get(key)
        if cards and (page == 1 or full is None):
            with _lock:
                _page_sizes[key] = len(cards)
            has_more = True
        else:
            has_more = bool(cards) and (full is None or len(cards) >= full)
    return {
        "site": SINGLE_SITE["id"],
        "siteName": SINGLE_SITE["name"],
        "items": cards,
        "hasMore": has_more,
        "nextPage": page + 1 if has_more else None,
    }


def _cover(value: object) -> str:
    text = str(value or "")
    return text if re.match(r"^https?://", text) else ""


def _card(site: str, site_name: str, item: dict) -> dict:
    return {
        "site": site,
        "siteName": site_name,
        "id": str(item.get("id") or ""),
        "title": str(item.get("title") or ""),
        "cover": _cover(item.get("cover")),
        "description": str(item.get("description") or ""),
        "season": int(item.get("season") or 1),
        "episodeCount": int(item.get("episodeCount") or 0),
    }


def _is_single_site() -> bool:
    """上游没有 /v1/sites 时按单站点处理（hongguo-api 形态）。"""
    base = _base_url()
    with _lock:
        cached = _single_sites.get(base)
    if cached is not None:
        return cached
    try:
        _get_json("/v1/sites")
        single = False
    except HTTPException as error:
        if error.status_code != 404:
            raise
        single = True
    with _lock:
        _single_sites[base] = single
    return single


def _site_names() -> dict[str, str]:
    if _is_single_site():
        return {SINGLE_SITE["id"]: SINGLE_SITE["name"]}
    payload = _get_json("/v1/sites")
    return {
        str(item.get("id") or ""): str(item.get("name") or "")
        for item in payload.get("items") or []
    }


def _enabled_sites() -> list[str]:
    if _is_single_site():
        return [SINGLE_SITE["id"]]
    payload = _get_json("/v1/sites")
    return [
        str(item.get("id") or "")
        for item in payload.get("items") or []
        if item.get("enabled")
    ]


def _page(site: str, site_name: str, payload: dict) -> dict:
    return {
        "site": site,
        "siteName": site_name,
        "items": [_card(site, site_name, item) for item in payload.get("items") or []],
        "hasMore": bool(payload.get("hasMore")),
        "nextPage": payload.get("nextPage"),
    }


@router.get("/sites", response_model=SiteListResponse)
async def list_sites(request: Request) -> SiteListResponse:
    require_session(request)
    if await asyncio.to_thread(_is_single_site):
        return SiteListResponse(items=[SiteCard(**SINGLE_SITE)])
    payload = await _fetch_json("/v1/sites")
    return SiteListResponse(items=[SiteCard(**item) for item in payload.get("items") or []])


@router.get("/search", response_model=DramaPage)
async def search_all(
    request: Request,
    q: str = Query(min_length=1, max_length=100),
    page: int = Query(default=1, ge=1),
) -> DramaPage:
    """跨站点搜索：只查已启用的站点，单个站点失败不影响整体结果。"""
    require_session(request)
    query = urllib.parse.urlencode({"q": q, "page": page})
    if await asyncio.to_thread(_is_single_site):
        payload = await _fetch_json(f"/v1/search?{query}")
        return DramaPage(**_page(SINGLE_SITE["id"], SINGLE_SITE["name"], payload))

    names = await asyncio.to_thread(_site_names)
    sites = await asyncio.to_thread(_enabled_sites)

    async def one(site: str):
        try:
            return site, await _fetch_json(f"/v1/sites/{urllib.parse.quote(site)}/search?{query}")
        except HTTPException:
            return site, None

    results = await asyncio.gather(*(one(site) for site in sites))
    items: list[dict] = []
    has_more = False
    for site, payload in results:
        if not payload:
            continue
        items.extend(_card(site, names.get(site, site), item) for item in payload.get("items") or [])
        has_more = has_more or bool(payload.get("hasMore"))
    return DramaPage(site="all", siteName="全部", items=items, hasMore=has_more, nextPage=page + 1 if has_more else None)


@router.get("/{site}/catalog", response_model=DramaPage)
async def catalog(
    request: Request,
    site: str,
    page: int = Query(default=1, ge=1),
) -> DramaPage:
    require_session(request)
    params = {"page": page, **{k: v for k, v in request.query_params.items() if k != "page"}}
    query = urllib.parse.urlencode(params)
    provider = await asyncio.to_thread(_drama_provider)
    if provider is not None and site in (SINGLE_SITE["id"], str(provider[0].get("id") or "")):
        sort = str(params.get("sort") or "")
        function = _provider_function(provider[2], sort=sort)
        if function:
            extra = {"page": page}
            if sort:
                extra["sort"] = sort
            try:
                page_data = await asyncio.to_thread(_plugin_page, provider, function, extra)
            except plugin_runtime.PluginRuntimeError as exc:
                raise HTTPException(status_code=502, detail=str(exc)) from exc
            return DramaPage(**page_data)
    if await asyncio.to_thread(_is_single_site):
        payload = await _fetch_json(f"/v1/catalog?{query}")
        return DramaPage(**_page(SINGLE_SITE["id"], SINGLE_SITE["name"], payload))
    names = await asyncio.to_thread(_site_names)
    payload = await _fetch_json(f"/v1/sites/{urllib.parse.quote(site)}/catalog?{query}")
    return DramaPage(**_page(site, names.get(site, site), payload))


@router.get("/{site}/search", response_model=DramaPage)
async def search_site(
    request: Request,
    site: str,
    q: str = Query(min_length=1, max_length=100),
    page: int = Query(default=1, ge=1),
) -> DramaPage:
    require_session(request)
    provider = await asyncio.to_thread(_drama_provider)
    if provider is not None and site in (SINGLE_SITE["id"], str(provider[0].get("id") or "")):
        function = _provider_function(provider[2], keyword=q)
        if function:
            try:
                page_data = await asyncio.to_thread(
                    _plugin_page, provider, function, {"page": page, "keyword": q}
                )
            except plugin_runtime.PluginRuntimeError as exc:
                raise HTTPException(status_code=502, detail=str(exc)) from exc
            return DramaPage(**page_data)
    query = urllib.parse.urlencode({"q": q, "page": page})
    if await asyncio.to_thread(_is_single_site):
        payload = await _fetch_json(f"/v1/search?{query}")
        return DramaPage(**_page(SINGLE_SITE["id"], SINGLE_SITE["name"], payload))
    names = await asyncio.to_thread(_site_names)
    payload = await _fetch_json(f"/v1/sites/{urllib.parse.quote(site)}/search?{query}")
    return DramaPage(**_page(site, names.get(site, site), payload))


@router.get("/{site}/series/{series_id}", response_model=SeriesDetail)
async def series(
    site: str,
    series_id: str,
    request: Request,
) -> SeriesDetail:
    require_session(request)
    provider = await asyncio.to_thread(_drama_provider)
    provider_match = provider is not None and site in (
        SINGLE_SITE["id"],
        str(provider[0].get("id") or ""),
    )
    if provider_match:
        content = plugin_runtime.build_params(provider[0], provider[2], {})
        content_base = str(content.get("apiBase") or "") or None
        payload = await _fetch_json(
            f"/v1/series/{urllib.parse.quote(series_id)}", content_base
        )
        site, name = SINGLE_SITE["id"], SINGLE_SITE["name"]
    elif await asyncio.to_thread(_is_single_site):
        payload = await _fetch_json(f"/v1/series/{urllib.parse.quote(series_id)}")
        site, name = SINGLE_SITE["id"], SINGLE_SITE["name"]
    else:
        names = await asyncio.to_thread(_site_names)
        payload = await _fetch_json(
            f"/v1/sites/{urllib.parse.quote(site)}/series/{urllib.parse.quote(series_id)}"
        )
        name = names.get(site, site)
    card = _card(site, name, payload)
    episodes = [
        Episode(
            id=str(item.get("id") or ""),
            title=str(item.get("title") or ""),
            episode=int(item.get("episode") or index + 1),
            duration=int(item.get("duration") or 0),
            disabled=bool(item.get("disabled")),
        )
        for index, item in enumerate(payload.get("episodes") or [])
    ]
    seasons = [
        DramaCard(**_card(site, name, item)) for item in payload.get("seasons") or [card]
    ]
    return SeriesDetail(
        site=site,
        siteName=name,
        id=card["id"] or series_id,
        title=card["title"],
        cover=card["cover"],
        description=card["description"],
        season=card["season"],
        episodeCount=card["episodeCount"] or len(episodes),
        albumId="",
        complete=bool(payload.get("complete", True)),
        episodes=episodes,
        seasons=seasons,
    )


@router.get("/{site}/episodes/{episode_id}/stream")
async def stream(
    site: str,
    episode_id: str,
    request: Request,
    token: str | None = Query(default=None),
) -> StreamingResponse:
    """播放流：把 Range/Content-Range 原样透传，支持拖动与边下边播。"""
    require_session(request, token)
    provider = await asyncio.to_thread(_drama_provider)
    provider_match = provider is not None and site in (
        SINGLE_SITE["id"],
        str(provider[0].get("id") or ""),
    )
    function = _provider_function(provider[2], stream=True) if provider_match else ""
    if provider_match and function:
        try:
            value = await asyncio.to_thread(
                _plugin_run, provider, function, {"id": episode_id}, False
            )
        except plugin_runtime.PluginRuntimeError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        streams = plugin_runtime.to_streams(value)
        url = streams[0]["url"] if streams else ""
        if not url:
            raise HTTPException(status_code=502, detail="插件未返回播放地址")
    elif await asyncio.to_thread(_is_single_site):
        url = f"{_base_url()}/v1/episodes/{urllib.parse.quote(episode_id)}/stream"
    else:
        url = (
            f"{_base_url()}/v1/sites/{urllib.parse.quote(site)}"
            f"/episodes/{urllib.parse.quote(episode_id)}/stream"
        )
    headers = {}
    range_header = request.headers.get("range")
    if range_header:
        headers["Range"] = range_header

    def open_upstream():
        req = urllib.request.Request(url, headers=headers, method="GET")
        return network_store.open_url(req, 20, "shortdrama")

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
