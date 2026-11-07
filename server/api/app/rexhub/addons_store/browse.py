"""单个 addon 的内容浏览：目录清单 → 目录条目 → 该 addon 自己的片源。

与 ``streams.py`` 的区别：那边是「按 IMDb ID 聚合全部已启用插件」，
这里只针对某一个 addon，用于插件详情页直接浏览与播放。
"""

from typing import Any
from urllib.parse import quote, urljoin

from .fetch import UpstreamError, proxy_get
from .streams import _direct_rank, _normalize, _resource_names, _text

MAX_ITEMS = 100
# 目录额外参数：只透传 Stremio 协议里约定的几种，避免把任意 query 拼进上游
EXTRA_KEYS = ("genre", "year", "search", "skip")


def _int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _genre_options(entry: dict[str, Any]) -> list[str]:
    """目录题材：兼容 catalog.genres 与 extra[{name:'genre', options}] 两种写法。"""
    out: list[str] = []
    for raw in entry.get("genres") or []:
        name = _text(raw, 60)
        if name and name not in out:
            out.append(name)
    for raw in entry.get("extra") or []:
        if not isinstance(raw, dict) or _text(raw.get("name"), 40) != "genre":
            continue
        for option in raw.get("options") or []:
            name = _text(option.get("name") if isinstance(option, dict) else option, 60)
            if name and name not in out:
                out.append(name)
    return out


def _addon_name(row: dict[str, Any]) -> str:
    manifest = row.get("manifest") or {}
    return (
        _text(manifest.get("name"), 80)
        or _text(row.get("slug"), 80)
    )


def _extra_of(entry: dict[str, Any]) -> tuple[list[str], list[str]]:
    """解析 catalog 支持的 extra：兼容 `extra: [{name}]` 与 `extraSupported` 两种写法。"""
    supported: list[str] = []
    required: list[str] = []
    for raw in entry.get("extra") or []:
        if isinstance(raw, dict):
            name = _text(raw.get("name"), 40)
            if not name:
                continue
            supported.append(name)
            if raw.get("isRequired"):
                required.append(name)
        elif isinstance(raw, str):
            supported.append(_text(raw, 40))
    for raw in entry.get("extraSupported") or []:
        name = _text(raw, 40)
        if name and name not in supported:
            supported.append(name)
    for raw in entry.get("extraRequired") or []:
        name = _text(raw, 40)
        if name and name not in required:
            required.append(name)
    return supported, required


def _catalog_entry(row: dict[str, Any], media_type: str, catalog_id: str) -> dict[str, Any]:
    manifest = row.get("manifest") or {}
    for entry in manifest.get("catalogs") or []:
        if not isinstance(entry, dict):
            continue
        if str(entry.get("type") or "") != media_type:
            continue
        if str(entry.get("id") or "") != catalog_id:
            continue
        return entry
    return {}


def catalogs(row: dict[str, Any]) -> dict[str, Any]:
    manifest = row.get("manifest") or {}
    out: list[dict[str, Any]] = []
    for entry in manifest.get("catalogs") or []:
        if not isinstance(entry, dict):
            continue
        media_type = _text(entry.get("type"), 20)
        catalog_id = _text(entry.get("id"), 120)
        if not media_type or not catalog_id:
            continue
        supported, required = _extra_of(entry)
        genres = _genre_options(entry)
        out.append(
            {
                "key": f"{media_type}:{catalog_id}",
                "type": media_type,
                "id": catalog_id,
                "name": _text(entry.get("name") or catalog_id, 80),
                "extraSupported": supported,
                "extraRequired": required,
                "hasSearch": "search" in supported,
                "hasGenre": "genre" in supported or bool(genres),
                "hasSkip": "skip" in supported,
                "genres": genres,
            }
        )
    resources = sorted(_resource_names(manifest))
    return {
        "slug": _text(row.get("slug"), 120),
        "name": _addon_name(row),
        "hasStream": "stream" in resources,
        "hasMeta": "meta" in resources,
        "hasSubtitles": "subtitles" in resources,
        "resources": resources,
        "catalogs": out,
    }


def _poster(base: str, value: Any) -> str:
    raw = _text(value, 1400)
    if not raw:
        return ""
    if raw.startswith("//"):
        return f"https:{raw}"
    if raw.startswith(("http://", "https://", "data:")):
        return raw
    try:
        return urljoin(base, raw)
    except ValueError:
        return ""


def _meta(base: str, raw: dict[str, Any], media_type: str = "") -> dict[str, Any]:
    return {
        "id": _text(raw.get("id"), 200),
        "type": _text(raw.get("type"), 20) or media_type,
        "name": _text(raw.get("name") or raw.get("title"), 200),
        "poster": _poster(base, raw.get("poster")),
        "background": _poster(base, raw.get("background")),
        "releaseInfo": _text(raw.get("releaseInfo") or raw.get("year"), 40),
        "rating": _text(raw.get("imdbRating"), 10),
        "description": _text(raw.get("description"), 600),
    }


def catalog(
    row: dict[str, Any],
    media_type: str,
    catalog_id: str,
    extra: dict[str, str] | None = None,
) -> dict[str, Any]:
    media_type = _text(media_type, 20)
    catalog_id = _text(catalog_id, 120)
    if not media_type or not catalog_id:
        raise UpstreamError("缺少目录类型或目录 ID")
    entry = _catalog_entry(row, media_type, catalog_id)
    supported, required = _extra_of(entry)
    values = dict(extra or {})
    if "skip" in required and not values.get("skip"):
        values["skip"] = "0"
    if "genre" in required and not values.get("genre"):
        options = _genre_options(entry)
        if options:
            values["genre"] = options[0]
    # 只透传该目录声明支持的参数
    pairs = [
        (key, values[key]) for key in EXTRA_KEYS if key in supported and values.get(key)
    ]
    base_path = f"catalog/{quote(media_type, safe='')}/{quote(catalog_id, safe='')}"
    # 插件对 extra 段编码风格不一致：多数接受 `a=b&c=d`，少数（如 youtubio）只认
    # 整段 encodeURIComponent 后的 `a%3Db%26c%3Dd`，因此两种都试，命中即停。
    paths = [base_path + ".json"]
    if pairs:
        raw_segment = "&".join(f"{key}={quote(value, safe='')}" for key, value in pairs)
        paths = [
            f"{base_path}/{raw_segment}.json",
            f"{base_path}/{quote(raw_segment, safe='')}.json",
        ]
    status = 0
    payload: Any = None
    failure: UpstreamError | None = None
    for path in paths:
        try:
            status, payload = proxy_get(row, path)
        except UpstreamError as exc:
            failure = exc
            status, payload = 0, None
            continue
        if status < 400 and isinstance(payload, dict) and payload.get("metas"):
            break
    if status >= 400:
        raise UpstreamError(f"目录返回 HTTP {status}")
    if not isinstance(payload, dict):
        raise failure or UpstreamError("目录返回格式不正确")
    metas = payload.get("metas")
    metas = metas if isinstance(metas, list) else []
    base = str(row.get("transport") or "").rstrip("/") + "/"
    items = [_meta(base, raw, media_type) for raw in metas if isinstance(raw, dict)]
    items = [item for item in items if item["id"]]
    raw_more = payload.get("hasMore")
    has_more = bool(raw_more) if raw_more is not None else len(metas) >= MAX_ITEMS
    return {
        "items": items[:MAX_ITEMS],
        "total": len(items),
        "hasMore": has_more,
        "name": _text(entry.get("name") or catalog_id, 80),
        "type": media_type,
        "id": catalog_id,
    }


def meta(row: dict[str, Any], media_type: str, video_id: str) -> dict[str, Any]:
    """读取单个条目的元数据与分集列表（剧集/番剧选集用）。"""
    media_type = _text(media_type, 20)
    video_id = _text(video_id, 200)
    if not media_type or not video_id:
        raise UpstreamError("缺少条目类型或 ID")
    manifest = row.get("manifest") or {}
    addon_name = _addon_name(row)
    if "meta" not in _resource_names(manifest):
        return {
            "meta": None,
            "videos": [],
            "addon": addon_name,
            "reason": "该插件没有提供元数据资源",
        }
    path = f"meta/{quote(media_type, safe='')}/{quote(video_id, safe=':')}.json"
    status, payload = proxy_get(row, path)
    if status >= 400:
        raise UpstreamError(f"元数据接口返回 HTTP {status}")
    if not isinstance(payload, dict):
        raise UpstreamError("元数据返回格式不正确")
    raw = payload.get("meta")
    if not isinstance(raw, dict):
        return {
            "meta": None,
            "videos": [],
            "addon": addon_name,
            "reason": "该条目没有返回元数据",
        }
    base = str(row.get("transport") or "").rstrip("/") + "/"
    videos: list[dict[str, Any]] = []
    for item in raw.get("videos") or []:
        if not isinstance(item, dict):
            continue
        vid = _text(item.get("id"), 200)
        if not vid:
            continue
        videos.append(
            {
                "id": vid,
                "season": _int(item.get("season")),
                "episode": _int(item.get("episode")),
                "name": _text(item.get("name") or item.get("title"), 200),
                "overview": _text(item.get("overview"), 400),
                "thumbnail": _poster(base, item.get("thumbnail")),
                "released": _text(item.get("released"), 40),
            }
        )
    videos.sort(key=lambda video: (video["season"], video["episode"], video["name"]))
    return {
        "meta": _meta(base, raw, media_type),
        "videos": videos,
        "addon": addon_name,
        "reason": "" if videos else "该条目没有返回分集列表",
    }


def _fetch_streams(
    row: dict[str, Any], media_type: str, video_id: str, addon_name: str
) -> list[dict[str, Any]]:
    path = f"stream/{quote(media_type, safe='')}/{quote(video_id, safe=':')}.json"
    status, payload = proxy_get(row, path)
    if status >= 400:
        raise UpstreamError(f"片源接口返回 HTTP {status}")
    if not isinstance(payload, dict):
        raise UpstreamError("片源返回格式不正确")
    streams = payload.get("streams")
    streams = streams if isinstance(streams, list) else []
    items = []
    for raw in streams:
        item = _normalize(row, addon_name, raw)
        if item:
            items.append(item)
    return items


def streams(
    row: dict[str, Any],
    media_type: str,
    video_id: str,
    season: int = 0,
    episode: int = 0,
) -> dict[str, Any]:
    """单插件片源：类型原样透传（movie/series/anime/channel/tv/music…）。

    不同插件对流 ID 的约定不一致：有的直接用 meta 里的分集 ID
    （``hmm-xxx-episode-1``），有的要求 ``tt123:1:1``，番剧多用 ``kitsu:x:1``。
    因此按「原样 → 季集后缀 → 默认集」依次尝试，命中即停。
    """
    media_type = _text(media_type, 20) or "movie"
    video_id = _text(video_id, 200)
    if not video_id:
        raise UpstreamError("缺少条目 ID")
    addon_name = _addon_name(row)
    if "stream" not in _resource_names(row.get("manifest") or {}):
        return {
            "streams": [],
            "total": 0,
            "addon": addon_name,
            "type": media_type,
            "id": video_id,
            "season": season,
            "episode": episode,
            "reason": "该插件没有提供片源资源",
        }
    candidates = [video_id]
    if season > 0 and episode > 0 and video_id.count(":") < 2:
        candidates.append(f"{video_id}:{season}:{episode}")
    if ":" not in video_id:
        if media_type == "series":
            candidates.append(f"{video_id}:1:1")
        elif media_type == "anime":
            candidates.append(f"{video_id}:1")
    items: list[dict[str, Any]] = []
    last_error: UpstreamError | None = None
    answered = False
    for target in dict.fromkeys(candidates):
        try:
            items = _fetch_streams(row, media_type, target, addon_name)
            answered = True
        except UpstreamError as exc:
            last_error = exc
            items = []
        if items:
            break
    if not items and not answered and last_error is not None:
        raise last_error
    items.sort(key=lambda item: (_direct_rank(item["url"]), item["name"]))
    if items:
        reason = ""
    elif "stream" not in _resource_names(row.get("manifest") or {}):
        reason = "该插件没有提供片源资源"
    else:
        reason = "该插件没有返回可播放片源"
    return {
        "streams": items,
        "total": len(items),
        "addon": addon_name,
        "type": media_type,
        "id": video_id,
        "season": season,
        "episode": episode,
        "reason": reason,
    }
