"""影视页数据层：直接调用服务端的 ForwardWidget 影视插件。

Stremio 桥接为了协议兼容只保留 id / name / poster / description，且把类型固定成
series；影视海报墙还需要背景图、年份、评分、演员与分集，所以这里单独调用插件
并归一化成 App 用的字段。

图片统一返回 TMDB 的路径（如 `/abc.jpg`），由 App 拼接服务端的 `/api/media/image`
代理地址：国区网络直连 image.tmdb.org 不可用，图片必须经服务端代理。
"""

from __future__ import annotations

import json
import re
import threading
import time
from typing import Any
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

from app.rexhub import stremio_bridge

PLUGIN_ID = "rexhub.tmdb"
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


def _plugin() -> dict[str, Any]:
    plugin = stremio_bridge._find_plugin(PLUGIN_ID)
    if plugin is None:
        raise ValueError("影视插件未安装或未启用")
    return plugin


def _modules(plugin: dict[str, Any]) -> list[dict[str, Any]]:
    analysis = plugin.get("analysis") or {}
    return [item for item in analysis.get("modules") or [] if isinstance(item, dict)]


def _module(plugin: dict[str, Any], catalog_id: str) -> dict[str, Any]:
    target = _text(catalog_id)
    for module in _modules(plugin):
        if _text(module.get("id")) == target or _text(module.get("function")) == target:
            return module
    raise ValueError("影视栏目不存在")


def catalogs() -> list[dict[str, Any]]:
    """插件声明的前台栏目，按插件里的顺序返回。"""

    plugin = _plugin()
    items: list[dict[str, Any]] = []
    for module in _modules(plugin):
        function = _text(module.get("function"))
        if not function or function in {"loadDetail", "loadResource", "search"}:
            continue
        media_type = "movie" if _text(module.get("mediaType")).lower() == "movie" else "series"
        items.append(
            {
                "id": _text(module.get("id")) or function,
                "title": _text(module.get("title")) or function,
                "mediaType": media_type,
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

    plugin = _plugin()
    module = _module(plugin, catalog_id)
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
    match = re.match(r"^tmdb:(movie|tv):(\d+)", media_id)
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
        people.append(
            {
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
                "id": f"tmdb:{'tv' if media_type == 'series' else 'movie'}:{tmdb_id}",
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
    """影视详情：简介、演职员、预告片与分集。"""

    target = _text(media_id)
    if not target:
        raise ValueError("缺少影视 ID")
    plugin = _plugin()
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
