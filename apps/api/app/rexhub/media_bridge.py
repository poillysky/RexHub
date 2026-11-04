"""影视页数据层：直接调用服务端的 ForwardWidget 影视插件。

Stremio 桥接为了协议兼容只保留 id / name / poster / description，且把类型固定成
series；影视海报墙还需要背景图、年份、评分、演员与分集，所以这里单独调用插件
并归一化成 App 用的字段。

图片统一返回 TMDB 的路径（如 `/abc.jpg`），由 App 拼接服务端的 `/api/media/image`
代理地址：国区网络直连 image.tmdb.org 不可用，图片必须经服务端代理。
"""


import json
import re
import threading
import time
from typing import Any
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

from app.rexhub import stremio_bridge

PLUGIN_ID = "rexhub.tmdb"
# source → 插件：bangumi / bgm / anilist 共用同一个 rexhub.bangumi 插件。
PLUGIN_IDS = {
    "tmdb": "rexhub.tmdb",
    "douban": "rexhub.douban",
    "bangumi": "rexhub.bangumi",
    "bgm": "rexhub.bangumi",
    "anilist": "rexhub.bangumi",
}
LIST_TTL = 300
EXTRAS_TTL = 900
IMAGE_TTL = 86400
IMAGE_CACHE_LIMIT = 256
EXTRAS_CACHE_LIMIT = 512
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024
PAGE_SIZE = 20

TMDB_API_BASE = "https://api.themoviedb.org/3"
TMDB_IMAGE_PREFIX = "https://image.tmdb.org/t/p/"
IMAGE_SIZES = {
    "w92",
    "w154",
    "w185",
    "w300",
    "w342",
    "w500",
    "w780",
    "w1280",
    "original",
}
_IMAGE_PATH_RE = re.compile(r"^/[A-Za-z0-9._-]+\.(?:jpg|jpeg|png|webp)$", re.IGNORECASE)
_IMAGE_URL_RE = re.compile(
    r"^https?://image\.tmdb\.org/t/p/(?:w\d+|original)(/[A-Za-z0-9._-]+\.(?:jpg|jpeg|png|webp))$",
    re.IGNORECASE,
)

_LIST_CACHE: dict[tuple[str, int], tuple[float, list[dict[str, Any]]]] = {}
_IMAGE_CACHE: dict[tuple[str, str], tuple[float, bytes, str]] = {}
_EXTRAS_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
_LOCK = threading.Lock()


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _rating(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return round(number, 1) if number > 0 else None


def _names(value: Any) -> list[str]:
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, (list, tuple)):
        return []
    return [_text(item) for item in value if _text(item)]


def _image_path(value: Any) -> str:
    """把 TMDB 图片地址归一化成路径；已经是路径时原样返回。"""

    text = _text(value)
    if not text:
        return ""
    match = _IMAGE_URL_RE.match(text)
    if match:
        return match.group(1)
    return text if _IMAGE_PATH_RE.match(text) else ""


def _normalize_source(source: str) -> str:
    key = _text(source).lower() or "tmdb"
    return "bangumi" if key == "bgm" else key


def _plugin(source: str = "tmdb") -> dict[str, Any]:
    key = _normalize_source(source)
    plugin_id = PLUGIN_IDS.get(key)
    if plugin_id is None:
        raise ValueError(f"未知数据源: {source}")
    plugin = stremio_bridge._find_plugin(plugin_id)
    if plugin is None:
        raise ValueError(f"{plugin_id} 插件未安装或未启用")
    return plugin


def _parse_media_id(media_id: str) -> tuple[str, str]:
    """拆 `source:native` 前缀；无前缀默认 tmdb（兼容旧 id 写法）。"""

    target = _text(media_id)
    prefix, _, rest = target.partition(":")
    if rest and _normalize_source(prefix) in PLUGIN_IDS:
        return _normalize_source(prefix), rest.strip()
    return "tmdb", target


def _catalog_target(catalog_id: str) -> tuple[str, str]:
    """按栏目 id 前缀定位插件；tmdb 栏目在 catalogs() 里带 `tmdb:` 前缀。"""

    cid = _text(catalog_id)
    if cid.startswith("tmdb:"):
        return "tmdb", cid[len("tmdb:") :]
    if cid.startswith("douban-"):
        return "douban", cid
    if cid.startswith(("bgm-", "anilist-")):
        return "bangumi", cid
    return "tmdb", cid


def _modules(plugin: dict[str, Any]) -> list[dict[str, Any]]:
    analysis = plugin.get("analysis") or {}
    return [item for item in analysis.get("modules") or [] if isinstance(item, dict)]


def _module(plugin: dict[str, Any], catalog_id: str) -> dict[str, Any]:
    target = _text(catalog_id)
    for module in _modules(plugin):
        if _text(module.get("id")) == target or _text(module.get("function")) == target:
            return module
    raise ValueError("影视栏目不存在")


_CATALOG_SKIP_FUNCTIONS = {
    "loadDetail",
    "loadResource",
    "search",
    "loadDiscover",
    "loadPersonWorks",
    "loadGenres",
}


def catalogs() -> list[dict[str, Any]]:
    """聚合 tmdb + douban + bangumi 三插件声明的前台栏目，每个目录带 source。

    anilist 目录由 rexhub.bangumi 插件透出（id 带 `anilist-` 前缀），
    source 单独标成 anilist，方便前台按数据源分组。
    缺某个插件时跳过该源，不影响其他源。
    """

    items: list[dict[str, Any]] = []
    for source in ("tmdb", "douban", "bangumi"):
        try:
            plugin = _plugin(source)
        except ValueError:
            continue
        for module in _modules(plugin):
            function = _text(module.get("function"))
            if not function or function in _CATALOG_SKIP_FUNCTIONS:
                continue
            module_id = _text(module.get("id")) or function
            catalog_source = (
                "anilist"
                if source == "bangumi" and module_id.startswith("anilist-")
                else source
            )
            media_type = "movie" if _text(module.get("mediaType")).lower() == "movie" else "series"
            items.append(
                {
                    "id": f"tmdb:{module_id}" if source == "tmdb" else module_id,
                    "title": _text(module.get("title")) or function,
                    "mediaType": media_type,
                    "source": catalog_source,
                }
            )
    return items


def _list_item(raw: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": _text(raw.get("id")),
        "mediaType": "movie" if _text(raw.get("mediaType")).lower() == "movie" else "series",
        "title": _text(raw.get("title") or raw.get("name")),
        "poster": _image_path(raw.get("coverUrl") or raw.get("poster") or raw.get("cover")),
        "backdrop": _image_path(raw.get("background") or raw.get("backdrop")),
        "overview": _text(raw.get("description") or raw.get("overview")),
        "year": _text(raw.get("releaseInfo")),
        "rating": _rating(raw.get("imdbRating")),
    }


def _cached_list(catalog_id: str, page: int) -> list[dict[str, Any]] | None:
    now = time.monotonic()
    with _LOCK:
        entry = _LIST_CACHE.get((catalog_id, page))
        if entry and entry[0] > now:
            return entry[1]
    return None


async def list_catalog(
    catalog_id: str, page: int
) -> tuple[list[dict[str, Any]], bool]:
    """取一页栏目数据，返回 (条目, 是否还有下一页)。"""

    page = max(1, min(int(page or 1), 500))
    cached = _cached_list(catalog_id, page)
    if cached is not None:
        return cached, len(cached) >= PAGE_SIZE

    source, module_ref = _catalog_target(catalog_id)
    plugin = _plugin(source)
    module = _module(plugin, module_ref)
    function = _text(module.get("function"))
    if not function:
        raise ValueError("栏目没有可用的插件函数")

    params = stremio_bridge._merge_params(plugin, {"page": page})
    raw = await stremio_bridge._call_plugin(plugin, function, params)
    items = [
        _list_item(item)
        for item in (raw if isinstance(raw, list) else [])
        if isinstance(item, dict) and _text(item.get("id"))
    ]
    with _LOCK:
        _LIST_CACHE[(catalog_id, page)] = (time.monotonic() + LIST_TTL, items)
    return items, len(items) >= PAGE_SIZE


def _raw_items(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, list):
        return []
    return [
        _list_item(item)
        for item in raw
        if isinstance(item, dict) and _text(item.get("id"))
    ]


def _search_function(plugin: dict[str, Any]) -> str:
    """插件声明的搜索函数：analysis.search.function（兼容 metadata.search）。"""

    analysis = plugin.get("analysis") or {}
    metadata = analysis.get("metadata") or {}
    for holder in (analysis, metadata):
        search = holder.get("search") if isinstance(holder, dict) else None
        if isinstance(search, dict):
            name = _text(search.get("function") or search.get("functionName"))
            if name:
                return name
    raise ValueError("插件不支持搜索")


async def search_media(
    source: str, keyword: str, page: int
) -> tuple[list[dict[str, Any]], bool]:
    """按数据源搜索：module.metadata.search.function({keyword, page})。"""

    page = max(1, min(int(page or 1), 500))
    keyword = _text(keyword)
    if not keyword:
        raise ValueError("请输入关键词")
    plugin = _plugin(source)
    function = _search_function(plugin)
    raw = await stremio_bridge._call_plugin(
        plugin,
        function,
        stremio_bridge._merge_params(plugin, {"keyword": keyword, "page": page}),
    )
    items = _raw_items(raw)
    return items, len(items) >= PAGE_SIZE


async def discover(params: dict[str, Any]) -> tuple[list[dict[str, Any]], bool]:
    """TMDB 发现页：tmdb 插件 module "discover" 的 loadDiscover。"""

    media_type = _text(params.get("mediaType")).lower()
    if media_type not in {"movie", "tv"}:
        raise ValueError("mediaType 须为 movie 或 tv")
    page = max(1, min(int(params.get("page") or 1), 500))
    plugin = _plugin("tmdb")
    if not stremio_bridge._has_function(plugin, "loadDiscover"):
        raise ValueError("影视插件不支持发现")
    raw = await stremio_bridge._call_plugin(
        plugin,
        "loadDiscover",
        stremio_bridge._merge_params(
            plugin,
            {
                "mediaType": media_type,
                "genre": _text(params.get("genre")),
                "year": _text(params.get("year")),
                "sortBy": _text(params.get("sortBy")) or "popularity.desc",
                "page": page,
            },
        ),
    )
    items = _raw_items(raw)
    return items, len(items) >= PAGE_SIZE


async def person_works(person_id: str) -> dict[str, Any]:
    """影人作品：loadPersonWorks({id})，id 形如 tmdb:person/456。"""

    target = _text(person_id)
    if not target:
        raise ValueError("缺少影人 ID")
    source, _native = _parse_media_id(target)
    plugin = _plugin(source)
    if not stremio_bridge._has_function(plugin, "loadPersonWorks"):
        raise ValueError("插件不支持影人作品")
    raw = await stremio_bridge._call_plugin(
        plugin,
        "loadPersonWorks",
        stremio_bridge._merge_params(plugin, {"id": target}),
    )
    name = ""
    rows: Any = raw
    if isinstance(raw, dict):
        name = _text(raw.get("name"))
        rows = raw.get("items")
    return {
        "source": source,
        "personId": target,
        "name": name or target,
        "items": _raw_items(rows),
    }


def _genre_rows(raw: Any) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, dict):
            continue
        try:
            genre_id = int(item.get("id"))
        except (TypeError, ValueError):
            continue
        name = _text(item.get("name"))
        if name:
            rows.append({"id": genre_id, "name": name})
    return rows


async def genres() -> dict[str, list[dict[str, Any]]]:
    """TMDB 题材：loadGenres() → {movie:[{id,name}], series:[…]}。"""

    plugin = _plugin("tmdb")
    if not stremio_bridge._has_function(plugin, "loadGenres"):
        raise ValueError("影视插件不支持题材列表")
    raw = await stremio_bridge._call_plugin(
        plugin, "loadGenres", stremio_bridge._global_params(plugin)
    )
    data = raw if isinstance(raw, dict) else {}
    return {"movie": _genre_rows(data.get("movie")), "series": _genre_rows(data.get("series"))}


def _detail_videos(raw: dict[str, Any]) -> list[dict[str, Any]]:
    videos: list[dict[str, Any]] = []
    for entry in raw.get("videos") or raw.get("episodes") or []:
        if not isinstance(entry, dict):
            continue
        try:
            season = int(entry.get("season") or 1)
            episode = int(entry.get("episode") or 0)
        except (TypeError, ValueError):
            continue
        if episode < 1:
            continue
        videos.append(
            {
                "season": season,
                "episode": episode,
                "title": _text(entry.get("title") or entry.get("name")),
                "overview": _text(entry.get("overview") or entry.get("description")),
                "still": _image_path(entry.get("thumbnail") or entry.get("still")),
                "rating": _rating(entry.get("rating")),
                "released": _text(entry.get("released") or entry.get("airDate")),
            }
        )
    return videos


def _detail_trailers(raw: dict[str, Any]) -> list[dict[str, Any]]:
    trailers: list[dict[str, Any]] = []
    for entry in raw.get("trailers") or []:
        if isinstance(entry, str):
            trailers.append({"name": "", "url": _text(entry)})
        elif isinstance(entry, dict):
            url = _text(entry.get("url") or entry.get("link") or entry.get("source"))
            if url:
                trailers.append({"name": _text(entry.get("name") or entry.get("title")), "url": url})
    return trailers


def _tmdb_credentials(plugin: dict[str, Any]) -> tuple[str, str, str]:
    """取接口地址 / Key / 语言，默认值与插件 `settings()` 保持一致。"""

    params = stremio_bridge._global_params(plugin)
    base = _text(plugin.get("api_url")) or _text(params.get("apiBase")) or TMDB_API_BASE
    key = _text(plugin.get("api_key")) or _text(params.get("apiKey"))
    language = _text(params.get("language")) or "zh-CN"
    return base.rstrip("/"), key, language


def _tmdb_json(
    plugin: dict[str, Any], path: str, params: dict[str, Any]
) -> dict[str, Any]:
    """直连 TMDB 补充插件没有透出的字段（演员头像、相关推荐）。"""

    base, key, language = _tmdb_credentials(plugin)
    query: dict[str, str] = {"language": language}
    for name, value in params.items():
        if value not in (None, ""):
            query[name] = str(value)

    headers = {"Accept": "application/json", "User-Agent": "RexHub-Media/1.0"}
    if key.startswith("eyJ"):
        headers["Authorization"] = f"Bearer {key}"
    elif key:
        query["api_key"] = key
    else:
        raise ValueError("影视插件未配置 TMDB API Key")

    url = f"{base}{path}?{urlencode(query)}"
    proxy = stremio_bridge.plugin_proxy(plugin)
    opener = (
        build_opener(ProxyHandler({"http": proxy, "https": proxy}))
        if proxy
        else build_opener()
    )
    with opener.open(Request(url, headers=headers), timeout=15) as response:
        payload = response.read(MAX_JSON_BYTES + 1)
    if len(payload) > MAX_JSON_BYTES:
        raise ValueError("TMDB 数据过大")
    try:
        data = json.loads(payload)
    except ValueError as exc:
        raise ValueError("TMDB 返回内容不是 JSON") from exc
    if not isinstance(data, dict):
        raise ValueError("TMDB 返回格式异常")
    return data


def _tmdb_target(media_id: str) -> tuple[str, str] | None:
    match = re.match(r"^tmdb:(movie|tv)[/:](\d+)", media_id)
    if not match:
        return None
    return match.group(1), match.group(2)


def _cast_people(credits: dict[str, Any]) -> list[dict[str, Any]]:
    """演员列表：姓名 + 角色 + 头像路径（TMDB `profile_path`）。"""

    people: list[dict[str, Any]] = []
    for person in credits.get("cast") or []:
        if not isinstance(person, dict):
            continue
        name = _text(person.get("name"))
        if not name:
            continue
        character = _text(person.get("character"))
        if not character:
            roles = person.get("roles")
            if isinstance(roles, list) and roles and isinstance(roles[0], dict):
                character = _text(roles[0].get("character"))
        person_id = str(person.get("id") or "").strip()
        people.append(
            {
                "id": f"tmdb:person/{person_id}" if person_id.isdigit() else "",
                "name": name,
                "character": character,
                "profile": _image_path(person.get("profile_path")),
            }
        )
        if len(people) >= 12:
            break
    return people


def _recommended(data: dict[str, Any], media_type: str) -> list[dict[str, Any]]:
    block = data.get("recommendations") or data.get("similar") or {}
    results = block.get("results") if isinstance(block, dict) else None
    items: list[dict[str, Any]] = []
    for raw in results or []:
        if not isinstance(raw, dict):
            continue
        poster = _image_path(raw.get("poster_path"))
        tmdb_id = raw.get("id")
        if not poster or not tmdb_id:
            continue
        released = _text(raw.get("release_date") or raw.get("first_air_date"))
        items.append(
            {
                "id": f"tmdb:{'tv' if media_type == 'series' else 'movie'}/{tmdb_id}",
                "mediaType": media_type,
                "title": _text(raw.get("title") or raw.get("name")),
                "poster": poster,
                "backdrop": _image_path(raw.get("backdrop_path")),
                "overview": _text(raw.get("overview")),
                "year": released[:4] if released else "",
                "rating": _rating(raw.get("vote_average")),
            }
        )
        if len(items) >= 12:
            break
    return items


def _extras(plugin: dict[str, Any], target: tuple[str, str]) -> dict[str, Any]:
    kind, tmdb_id = target
    cache_key = f"{kind}:{tmdb_id}"
    now = time.monotonic()
    with _LOCK:
        entry = _EXTRAS_CACHE.get(cache_key)
        if entry and entry[0] > now:
            return entry[1]

    media_type = "series" if kind == "tv" else "movie"
    data = _tmdb_json(
        plugin,
        f"/{kind}/{tmdb_id}",
        {
            "append_to_response": (
                "aggregate_credits,recommendations" if kind == "tv" else "credits,recommendations"
            )
        },
    )
    credits = data.get("aggregate_credits")
    if not isinstance(credits, dict):
        credits = data.get("credits") if isinstance(data.get("credits"), dict) else {}
    result = {
        "castPeople": _cast_people(credits),
        "recommendations": _recommended(data, media_type),
    }
    with _LOCK:
        if len(_EXTRAS_CACHE) >= EXTRAS_CACHE_LIMIT:
            _EXTRAS_CACHE.clear()
        _EXTRAS_CACHE[cache_key] = (now + EXTRAS_TTL, result)
    return result


async def detail(media_id: str) -> dict[str, Any]:
    """影视详情：简介、演职员、预告片与分集。按 `source:native` 前缀选插件。"""

    target = _text(media_id)
    if not target:
        raise ValueError("缺少影视 ID")
    source, _native = _parse_media_id(target)
    plugin = _plugin(source)
    if not stremio_bridge._has_function(plugin, "loadDetail"):
        raise ValueError("影视插件不支持详情")
    raw = await stremio_bridge._call_plugin(
        plugin, "loadDetail", stremio_bridge._merge_params(plugin, {"id": target})
    )
    if not isinstance(raw, dict):
        raise ValueError("影视详情返回为空")

    result = {
        "id": _text(raw.get("id")) or target,
        "mediaType": "movie" if _text(raw.get("mediaType")).lower() == "movie" else "series",
        "title": _text(raw.get("title") or raw.get("name")),
        "poster": _image_path(raw.get("poster")),
        "backdrop": _image_path(raw.get("background")),
        "logo": _image_path(raw.get("logo")),
        "overview": _text(raw.get("description") or raw.get("overview")),
        "tagline": _text(raw.get("tagline")),
        "year": _text(raw.get("releaseInfo")),
        "released": _text(raw.get("released")),
        "rating": _rating(raw.get("imdbRating")),
        "runtime": _text(raw.get("runtime")),
        "genres": _names(raw.get("genres")),
        "countries": [
            part.strip() for part in _text(raw.get("country")).split("/") if part.strip()
        ],
        "cast": _names(raw.get("cast")),
        "director": _names(raw.get("director")),
        "writer": _names(raw.get("writer")),
        "trailers": _detail_trailers(raw),
        "videos": _detail_videos(raw),
        "castPeople": [],
        "recommendations": [],
    }

    # 演员头像与相关推荐是增强信息：插件没有透出，直连 TMDB 补齐，失败也不影响详情主体。
    target_info = _tmdb_target(target)
    if target_info:
        try:
            result.update(_extras(plugin, target_info))
        except (OSError, ValueError):
            pass

    return result


def _cached_image(path: str, size: str) -> tuple[bytes, str] | None:
    now = time.monotonic()
    with _LOCK:
        entry = _IMAGE_CACHE.get((path, size))
        if entry and entry[0] > now:
            return entry[1], entry[2]
    return None


def fetch_image(path: str, size: str) -> tuple[bytes, str]:
    """经插件代理拉取 TMDB 图片，按路径做内存缓存。"""

    size = _text(size) or "w500"
    if size not in IMAGE_SIZES:
        raise ValueError("不支持的图片尺寸")
    path = _text(path)
    if not _IMAGE_PATH_RE.match(path):
        raise ValueError("不支持的图片路径")

    cached = _cached_image(path, size)
    if cached is not None:
        return cached

    plugin = _plugin()
    proxy = stremio_bridge.plugin_proxy(plugin)
    url = f"{TMDB_IMAGE_PREFIX}{size}{path}"
    request = Request(url, headers={"User-Agent": "RexHub-Media/1.0", "Accept": "image/*"})
    if proxy:
        opener = build_opener(ProxyHandler({"http": proxy, "https": proxy}))
    else:
        opener = build_opener()

    with opener.open(request, timeout=20) as response:
        content_type = str(response.headers.get("Content-Type") or "image/jpeg").split(";")[0]
        data = response.read(MAX_IMAGE_BYTES + 1)
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError("图片过大")
    if not data:
        raise ValueError("图片为空")

    now = time.monotonic()
    with _LOCK:
        if len(_IMAGE_CACHE) >= IMAGE_CACHE_LIMIT:
            _IMAGE_CACHE.clear()
        _IMAGE_CACHE[(path, size)] = (now + IMAGE_TTL, data, content_type)
    return data, content_type
