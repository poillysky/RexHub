"""统一数据模型：把 Widget/Stremio/独立进程的结果归一为 RexHub DTO。

插件可以返回不同结构，但 iOS/Web 只消费这里定义的字段；来源独有信息
放进 ``extensions``，不强迫所有插件支持相同字段。
"""


from typing import Any

MEDIA_TYPES = ("movie", "tv")


def _text(value: object, limit: int = 500) -> str:
    return str(value or "").strip()[:limit]


def _first_image(raw: dict[str, Any], keys: tuple[str, ...]) -> str:
    for key in keys:
        value = raw.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, list):
            for item in value:
                if isinstance(item, str) and item.strip():
                    return item.strip()
    return ""


def _extensions(raw: dict[str, Any], known: set[str]) -> dict[str, Any]:
    return {key: value for key, value in raw.items() if key not in known}


def resource(plugin_id: str, raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raw = {}
    media_type = _text(
        raw.get("mediaType") or raw.get("media_type") or raw.get("type"), 20
    )
    if media_type == "series":
        media_type = "tv"
    rating = raw.get("rating")
    if isinstance(rating, str):
        try:
            rating = float(rating)
        except ValueError:
            rating = None
    known = {
        "id",
        "type",
        "mediaType",
        "media_type",
        "title",
        "name",
        "coverUrl",
        "posterPath",
        "posterUrl",
        "poster_url",
        "poster",
        "backdropPath",
        "backdropPaths",
        "backdropImageUrls",
        "background",
        "description",
        "releaseDate",
        "releaseInfo",
        "rating",
        "link",
        "episode",
        "duration",
        "durationText",
        "headers",
    }
    return {
        "id": _text(raw.get("id"), 200),
        "sourceId": plugin_id,
        "title": _text(raw.get("title") or raw.get("name")),
        "mediaType": media_type if media_type in MEDIA_TYPES else "movie",
        "poster": _first_image(
            raw,
            (
                "posterPath",
                "posterUrl",
                "poster_url",
                "poster",
                "coverUrl",
                "backdropPath",
                "background",
            ),
        ),
        "backdrop": _first_image(
            raw,
            (
                "backdropPath",
                "backdropImageUrls",
                "backdropPaths",
                "background",
                "poster",
                "coverUrl",
            ),
        ),
        "description": _text(raw.get("description"), 2000),
        "releaseDate": _text(raw.get("releaseDate") or raw.get("releaseInfo"), 40),
        "rating": rating if isinstance(rating, (int, float)) else None,
        "links": [],
        "extensions": _extensions(raw, known),
    }


def resources(plugin_id: str, raw: Any) -> list[dict[str, Any]]:
    if isinstance(raw, dict) and isinstance(raw.get("items"), list):
        raw = raw["items"]
    if not isinstance(raw, list):
        return []
    return [resource(plugin_id, item) for item in raw if isinstance(item, dict)]


def video_resource(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {}
    return {
        "name": _text(raw.get("name"), 120),
        "description": _text(raw.get("description"), 300),
        "url": _text(raw.get("url"), 2000),
        "headers": raw.get("customHeaders") or raw.get("headers") or {},
        "playerType": _text(raw.get("playerType"), 20) or "system",
        "extensions": _extensions(
            raw, {"name", "description", "url", "customHeaders", "headers", "playerType"}
        ),
    }


def video_resources(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, list):
        return []
    return [item for item in (video_resource(entry) for entry in raw) if item.get("url")]


def subtitle(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {}
    return {
        "id": _text(raw.get("id"), 120),
        "title": _text(raw.get("title"), 200),
        "lang": _text(raw.get("lang"), 20),
        "count": raw.get("count") if isinstance(raw.get("count"), int) else 0,
        "url": _text(raw.get("url"), 2000),
    }


def subtitles(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, list):
        return []
    return [item for item in (subtitle(entry) for entry in raw) if item.get("url")]


def detail(plugin_id: str, raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {}
    base = resource(plugin_id, raw)
    related = raw.get("relatedItems") if isinstance(raw.get("relatedItems"), list) else []
    episodes = raw.get("episodeItems") if isinstance(raw.get("episodeItems"), list) else []
    genres = raw.get("genreItems") if isinstance(raw.get("genreItems"), list) else []
    peoples = raw.get("peoples") if isinstance(raw.get("peoples"), list) else []
    trailers = raw.get("trailers") if isinstance(raw.get("trailers"), list) else []
    return {
        **base,
        "originalTitle": _text(raw.get("originalTitle")),
        "link": _text(raw.get("link"), 500),
        "runtime": raw.get("duration") if isinstance(raw.get("duration"), (int, float)) else None,
        "durationText": _text(raw.get("durationText"), 40),
        "genres": [
            {"id": _text(item.get("id"), 120), "title": _text(item.get("title"), 120)}
            for item in genres
            if isinstance(item, dict)
        ],
        "people": [
            {
                "id": _text(item.get("id"), 120),
                "name": _text(item.get("title") or item.get("name"), 120),
                "avatar": _text(item.get("avatar"), 500),
                "role": _text(item.get("role"), 80),
            }
            for item in peoples
            if isinstance(item, dict)
        ],
        "relatedItems": resources(plugin_id, related),
        "episodes": resources(plugin_id, episodes),
        "trailers": [
            {"cover": _text(item.get("coverUrl"), 500), "url": _text(item.get("url"), 2000)}
            for item in trailers
            if isinstance(item, dict) and item.get("url")
        ],
        "videoUrl": _text(raw.get("videoUrl"), 2000),
        "playerType": _text(raw.get("playerType"), 20) or "system",
    }


def danmu_search(raw: Any) -> dict[str, Any]:
    animes = raw.get("animes") if isinstance(raw, dict) else []
    return {
        "animes": [
            {
                "animeId": _text(item.get("animeId"), 120),
                "animeTitle": _text(item.get("animeTitle") or item.get("title"), 200),
                "type": _text(item.get("type"), 20),
            }
            for item in (animes or [])
            if isinstance(item, dict)
        ]
    }


def danmu_episodes(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, list):
        return []
    return [
        {
            "episodeId": _text(item.get("episodeId"), 120),
            "episodeTitle": _text(item.get("episodeTitle") or item.get("title"), 200),
        }
        for item in raw
        if isinstance(item, dict)
    ]


def danmu_comments(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {"count": 0, "comments": []}
    comments = raw.get("comments") if isinstance(raw.get("comments"), list) else []
    return {
        "count": raw.get("count") if isinstance(raw.get("count"), int) else len(comments),
        "comments": comments,
    }
