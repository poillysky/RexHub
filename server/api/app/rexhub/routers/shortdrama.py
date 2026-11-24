"""短剧接口：外部服务源聚合。

服务管理里登记的每个 ``source_kind=shortdrama`` 服务都能作为内容站点使用，
能力按下列顺序解析：

- 先找 ``shortdrama.*`` 同名能力；
- 再找 ``video.*`` / ``studio.*`` 等同名后缀能力；
- 最后按能力名后缀回退（如 ``resource.search`` 可承接搜索）。

榜单分组（``shortdrama.ranks``）缺失时合成“热门/最新”，
目录（``shortdrama.catalog``）缺失时榜单页回退到目录接口。
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
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from app.rexhub import network_store, services_store
from app.rexhub.auth_guard import require_session, session_token

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
# 各逻辑能力可以回退到的服务能力名，影视 / 片商源不必使用 shortdrama.* 命名。
CAPABILITY_ALIASES = {
    "shortdrama.ranks": ("video.ranks", "studio.ranks", "ranks"),
    "shortdrama.catalog": ("video.catalog", "studio.catalog", "resource.list", "catalog"),
    "shortdrama.categories": ("video.categories", "studio.categories", "categories"),
    "shortdrama.search": ("video.search", "studio.search", "resource.search", "search"),
    "shortdrama.detail": ("video.detail", "studio.detail", "detail"),
    "shortdrama.stream": ("video.stream", "studio.stream", "playback.stream", "stream"),
}
# 旧的短剧路径使用 hongguo，保留别名映射到服务 ID。
SITE_ALIASES = {"hongguo": "rexhub.hongguo.video"}
# 服务源自带的分类维度接口：未声明 shortdrama.categories 时按约定路径探测。
CATEGORY_PATH = "/v1/categories"
SOURCE_KIND = "shortdrama"
# 服务未声明 endpoints 时按这套约定路径访问，录入时只填服务地址即可。
DEFAULT_ENDPOINTS = {
    "shortdrama.ranks": {"path": "/v1/rankings", "method": "GET"},
    "shortdrama.catalog": {"path": "/v1/catalog", "method": "GET"},
    "shortdrama.search": {"path": "/v1/search", "method": "GET"},
    "shortdrama.detail": {"path": "/v1/series/{id}", "method": "GET"},
    "shortdrama.stream": {"path": "/v1/episodes/{id}/stream", "method": "GET"},
}
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


class CatalogDimensionItem(BaseModel):
    id: str
    title: str


class CatalogDimension(BaseModel):
    key: str
    title: str
    items: list[CatalogDimensionItem]


class CatalogDimensions(BaseModel):
    dimensions: list[CatalogDimension]


class PlayInfo(BaseModel):
    """播放解析结果：返回服务端透传地址，播放流量由服务端通用 pipe 转发。"""

    url: str
    headers: dict[str, str] = Field(default_factory=dict)
    kind: str = "mp4"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """上游 302 由我们手动处理：插件直连本地，CDN 再按网络代理配置抓取。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def _opener_direct():
    return urllib.request.build_opener(_NoRedirect)


def _hls_with_vod_type(first: bytes, content_length: str | None) -> bytes | None:
    """给缺 ``#EXT-X-PLAYLIST-TYPE`` 的静态 HLS 清单补上 ``VOD``。

    AVPlayer 对缺这个标记的清单会按 event 处理，可 seek 范围被压到已缓冲区间，
    拖到未缓冲处就 seek 不进去、也不起播。带 ``#EXT-X-ENDLIST`` 的清单按 RFC 8216
    就是静态点播，补标记不改变语义，属通用归一化。

    只处理能完整读到的清单（首块已含全文），分块未读完时原样返回 ``None``。
    """
    try:
        expected = int(content_length) if content_length else -1
    except ValueError:
        expected = -1
    if expected > len(first):
        return None
    text = first.decode("utf-8", "ignore")
    if "#EXTM3U" not in text or "#EXT-X-ENDLIST" not in text:
        return None
    if "#EXT-X-PLAYLIST-TYPE" in text:
        return None
    # RFC 8216：标记必须出现在第一个 Media Segment 之前，且 EXTINF 必须紧跟分片
    # 地址，所以插在首个 EXTINF 之前（没有 EXTINF 时插在首个分片地址之前）。
    lines = text.splitlines(keepends=True)
    insert_at = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#EXTINF") or not stripped.startswith("#"):
            insert_at = index
            break
    if insert_at is None:
        return None
    lines.insert(insert_at, "#EXT-X-PLAYLIST-TYPE:VOD\n")
    return "".join(lines).encode("utf-8")


_HLS_TARGET_SUFFIXES = (".m3u8", ".m3u")
# 清单本身很小，但分块读到的首块未必含全文，归一化前要读完整。
_PLAYLIST_MAX = 4 * 1024 * 1024


def _is_hls_target(target: str) -> bool:
    path = urllib.parse.urlparse(target or "").path.lower()
    return path.endswith(_HLS_TARGET_SUFFIXES)


def _probe_stream_kind(base: str, path: str) -> str:
    """探测插件播放端点的出流形态，只为让客户端跳过 HLS 的二次解码探测。

    插件普遍支持 ``?json=1`` 只返回直链，命中时按直链后缀判断，不必拉清单；
    未支持时看 302 的 Location 或响应 content-type，读到首块即关闭。
    探测失败或超时一律按 mp4 处理，与改造前行为一致，不拖慢起播链路。
    """
    url = f"{base}{path}"
    probe = url + ("&" if "?" in url else "?") + "json=1"
    request = urllib.request.Request(
        probe, headers={"Accept": "application/json, */*"}, method="GET"
    )
    try:
        with _opener_direct().open(request, timeout=8) as response:
            content_type = (
                str(response.headers.get("content-type") or "")
                .split(";")[0]
                .strip()
                .lower()
            )
            if content_type == "application/json":
                payload = json.loads(response.read(64 * 1024).decode("utf-8", "ignore"))
                target = payload.get("url") if isinstance(payload, dict) else ""
                return "hls" if _is_hls_target(str(target or "")) else "mp4"
            if content_type == "application/vnd.apple.mpegurl":
                return "hls"
            if content_type.startswith(("video/", "audio/")):
                return "mp4"
            head = response.read(4096).lstrip()[:16]
            return "hls" if head.startswith(b"#EXTM3U") else "mp4"
    except urllib.error.HTTPError as error:
        target = error.headers.get("Location") or ""
        error.close()
        return "hls" if _is_hls_target(target) else "mp4"
    except (urllib.error.URLError, OSError, ValueError):
        return "mp4"


def _read_playlist(upstream, first: bytes) -> "tuple[bytes, bool]":
    """读完整份清单。超过上限时返回已读部分并标记未读完，剩余仍按流透传。"""
    buffer = bytearray(first)
    while len(buffer) < _PLAYLIST_MAX:
        chunk = upstream.read(64 * 1024)
        if not chunk:
            return bytes(buffer), True
        buffer.extend(chunk)
    return bytes(buffer), False


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
    site_id = SITE_ALIASES.get(site, site)
    row = services_store.get_service(site_id)
    if not row or str(row.get("source_kind") or "") != SOURCE_KIND:
        raise HTTPException(status_code=404, detail="短剧站点不存在")
    if not bool(row.get("enabled", True)):
        raise HTTPException(
            status_code=503,
            detail=f"{row.get('name') or site_id} 已停用，请到 设置 → 服务管理 启用",
        )
    return row


def _visible_rows() -> list[dict]:
    rows: list[dict] = []
    for row in services_store.list_sources(SOURCE_KIND):
        if not _endpoint(row, "shortdrama.catalog"):
            continue
        rows.append(row)
    return rows


def _raw_endpoint(row: dict, capability: str) -> dict:
    endpoints = row.get("endpoints") if isinstance(row.get("endpoints"), dict) else {}
    spec = endpoints.get(capability)
    if isinstance(spec, dict):
        path = str(spec.get("path") or "").strip()
        method = str(spec.get("method") or "GET").upper()
    elif isinstance(spec, str):
        path = spec.strip()
        method = "GET"
    else:
        return {}
    if not path:
        return {}
    return {"path": path, "method": method}


def _endpoint(row: dict, capability: str) -> dict:
    spec = _raw_endpoint(row, capability)
    if spec:
        return spec
    # 影视 / 片商插件未必使用 shortdrama.* 命名，按别名与能力名后缀回退。
    endpoints = row.get("endpoints") if isinstance(row.get("endpoints"), dict) else {}
    suffix = capability.rsplit(".", 1)[-1]
    candidates = list(CAPABILITY_ALIASES.get(capability, ()))
    candidates += [name for name in endpoints if name.endswith(f".{suffix}")]
    for name in candidates:
        spec = _raw_endpoint(row, name)
        if spec:
            return spec
    # 未声明任何接口时按约定路径回退，避免只填服务地址的场景无法使用。
    if not endpoints:
        return dict(DEFAULT_ENDPOINTS.get(capability) or {})
    return {}


def _base(row: dict) -> str:
    base = str(row.get("api_base") or row.get("url") or "").strip().rstrip("/")
    if not base:
        name = row.get("name") or row.get("id") or "短剧"
        raise HTTPException(status_code=503, detail=f"{name} 未配置服务地址")
    return base


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
        raise HTTPException(status_code=404, detail=f"服务未声明 {capability} 接口")
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
            f"/api/services/{urllib.parse.quote(site)}/media"
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


def _page(
    payload: dict, page: int, site: str, site_name: str, limit: int = 0
) -> dict:
    raw_items = payload.get("items") if isinstance(payload.get("items"), list) else []
    items = [
        _card(site, site_name, item)
        for item in raw_items
        if isinstance(item, dict) and item.get("id")
    ]
    if limit > 0:
        # 插件接口不支持 limit，按需在本层裁剪，避免把 limit 透传到上游
        items = items[:limit]
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


def _dimensions(payload: dict) -> list[dict]:
    """插件分类维度：只保留有 key 且有候选项的维度，文案全部取插件原文。"""
    raw = payload.get("dimensions") if isinstance(payload.get("dimensions"), list) else []
    result: list[dict] = []
    for group in raw:
        if not isinstance(group, dict):
            continue
        key = str(group.get("key") or "").strip()
        raw_items = group.get("items") if isinstance(group.get("items"), list) else []
        items = [
            {"id": str(item.get("id") or ""), "title": str(item.get("title") or "")}
            for item in raw_items
            if isinstance(item, dict) and item.get("id") and item.get("title")
        ]
        if not key or not items:
            continue
        result.append(
            {"key": key, "title": str(group.get("title") or key), "items": items}
        )
    return result


def _site_ui(row: dict) -> dict:
    ui = row.get("ui") if isinstance(row.get("ui"), dict) else {}
    block = dict(ui.get("shortdrama") or {})
    logo = str(block.get("logo") or "")
    if logo.startswith("/") and not logo.startswith("//"):
        site_id, _name = _site_meta(row)
        block["logo"] = (
            f"/api/services/{urllib.parse.quote(site_id)}/media"
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
        try:
            payload = await _call(row, "shortdrama.search", params)
        except HTTPException as error:
            if error.status_code in (404, 502, 503):
                last_error = error
                continue
            raise
        return DramaPage(**_page(payload, page, site_id, name, limit))
    if last_error:
        raise last_error
    raise HTTPException(status_code=503, detail="暂无可用的短剧服务源")


@router.get("/{site}/categories", response_model=CatalogDimensions)
async def categories(request: Request, site: str) -> CatalogDimensions:
    """插件自带的分类维度；插件没有该接口时返回空列表。"""
    require_session(request)
    row = _row(site)
    spec = _endpoint(row, "shortdrama.categories")
    if spec:
        payload = await _call(row, "shortdrama.categories", {})
    else:
        base = await _base_async(row)
        try:
            payload = await _fetch_json(CATEGORY_PATH, base)
        except HTTPException as error:
            if error.status_code == 404:
                return CatalogDimensions(dimensions=[])
            raise
    return CatalogDimensions(dimensions=_dimensions(payload))


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
    params: dict[str, object] = {"page": page}
    # 分类维度（background/theme/sort…）由插件定义，这里原样透传
    for key, value in request.query_params.items():
        if key in {"page", "limit"}:
            continue
        text = str(value or "").strip()
        if text and text.lower() != "all":
            params[key] = text
    payload = await _call(row, "shortdrama.catalog", params)
    return DramaPage(**_page(payload, page, site_id, name, limit))


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
    payload = await _call(row, "shortdrama.search", params)
    return DramaPage(**_page(payload, page, site_id, name, limit))


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
    if _endpoint(row, "shortdrama.ranks"):
        payload = await _call(row, "shortdrama.ranks", params)
    else:
        payload = await _call(
            row,
            "shortdrama.catalog",
            {"category": rank or "hot", "page": page},
        )
    return DramaPage(**_page(payload, page, site_id, name, limit))


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


@router.get("/{site}/episodes/{episode_id}/play", response_model=PlayInfo)
async def play(
    site: str,
    episode_id: str,
    request: Request,
    token: str | None = Query(default=None),
):
    """播放解析：统一返回服务端透传地址，播放流量由服务端通用 pipe 转发。

    服务端不感知服务源的出流形态（CDN 直链 / 服务自解密 / 302），
    上游变化只改服务配置，服务端与客户端零改动。
    """
    require_session(request, token)
    row = _row(site)
    spec = _endpoint(row, "shortdrama.stream")
    if not spec:
        raise HTTPException(status_code=404, detail="服务未声明播放接口")

    url = (
        str(request.base_url).rstrip("/")
        + f"/api/shortdrama/{urllib.parse.quote(site, safe='')}"
        + f"/episodes/{urllib.parse.quote(episode_id, safe='')}/stream"
    )
    session = session_token(request, token)
    if session:
        url = f"{url}?{urllib.parse.urlencode({'token': session})}"
    # HLS 声明能让客户端跳过 AVURLAsset 的解码探测（要额外拉清单和首片）。
    base = await _base_async(row)
    kind = await asyncio.to_thread(
        _probe_stream_kind, base, _fill(spec["path"], {"id": episode_id})
    )
    return PlayInfo(url=url, headers={}, kind=kind)


@router.get("/{site}/episodes/{episode_id}/stream")
async def stream(
    site: str,
    episode_id: str,
    request: Request,
    token: str | None = Query(default=None),
):
    """播放：统一透传服务源流。

    服务端只做通用 pipe：请求服务播放端点，遇到 30x 就跟一次，随后原样分块转发。
    服务内部是 CDN 直链、自解密还是 302，服务端都不感知。
    """
    require_session(request, token)
    row = _row(site)
    spec = _endpoint(row, "shortdrama.stream")
    if not spec:
        raise HTTPException(status_code=404, detail="服务未声明播放接口")
    base = await _base_async(row)
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

    content_type = (
        str(upstream.headers.get("content-type") or "").split(";")[0].strip().lower()
    )

    # 插件解码失败时可能把错误页当视频返回；但部分插件把 HLS 清单按 text/plain
    # 返回，所以不能只看 content-type，要按首块内容嗅探。
    first = await asyncio.to_thread(upstream.read, 64 * 1024)
    if not first:
        upstream.close()
        raise HTTPException(status_code=502, detail="播放源返回空内容")
    if content_type in {"application/json", "text/html", "text/plain", ""}:
        head = first.lstrip()[:16]
        if head.startswith(b"#EXTM3U"):
            content_type = "application/vnd.apple.mpegurl"
            response_headers["content-type"] = content_type
        elif head.startswith((b"{", b"[", b"<")):
            upstream.close()
            raise HTTPException(status_code=502, detail="播放源返回异常内容，请切换剧集重试")

    # 部分上游清单只带 ENDLIST、不带 PLAYLIST-TYPE，AVPlayer 会按 event 处理，
    # 可 seek 窗口被限制成已缓冲范围，拖到未缓冲处就不起播。
    # 这里按 RFC 8216 做通用归一化：静态清单补上 VOD 标记。
    if content_type == "application/vnd.apple.mpegurl":
        first, complete = await asyncio.to_thread(_read_playlist, upstream, first)
        if complete:
            normalized = _hls_with_vod_type(
                first, upstream.headers.get("content-length")
            )
            if normalized is not None:
                first = normalized
                response_headers["content-length"] = str(len(first))
    if (
        content_type.startswith(("video/", "audio/"))
        and "accept-ranges" not in response_headers
    ):
        response_headers["accept-ranges"] = "bytes"

    def chunks():
        try:
            yield first
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
        media_type=content_type or "video/mp4",
    )
