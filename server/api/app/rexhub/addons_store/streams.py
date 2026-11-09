"""片源聚合：并发查询已启用 addon 的 stream 资源，供网页播放器使用。

Stremio 的 stream 响应里 `url` 是可直接播放的直链，`externalUrl` 要跳到外部
播放器，`infoHash` 只是种子信息（网页端无法直接播）。这里统一归一化并按
「可直链播放 → 外部打开 → 种子」排序，前端据此决定渲染方式。
"""

import re
import time
from typing import Any

import httpx

from .collect import addon_names, candidate, gather, text as _text
from .storage import _read

# 单次查询参数
QUERY_TIMEOUT = 6.0
TOTAL_TIMEOUT = 10.0
CONCURRENCY = 80
MAX_CANDIDATES = 260
MAX_STREAMS = 150
CACHE_TTL = 90

_CACHE: dict[str, tuple[float, list[dict[str, Any]]]] = {}


def _stream_id(imdb_id: str, season: int, episode: int) -> str:
    if season > 0 and episode > 0:
        return f"{imdb_id}:{season}:{episode}"
    return imdb_id


def _normalize(row: dict[str, Any], addon_name: str, raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    url = _text(raw.get("url"), 1200)
    external = _text(raw.get("externalUrl"), 1200)
    info_hash = _text(raw.get("infoHash"), 100)
    yt_id = _text(raw.get("ytId"), 40)
    # ytId 是「去 YouTube 看」的外链，不是可直接塞进 <video> 的直链
    if not url and not external and yt_id:
        external = f"https://www.youtube.com/watch?v={yt_id}"
    if url and _is_youtube_watch(url):
        external = external or url
        url = ""
    if not external and url and not _is_playable(url):
        external = url
        url = ""
    if not url and not external and not info_hash:
        return None
    hints = raw.get("behaviorHints")
    hints = hints if isinstance(hints, dict) else {}
    file_idx = raw.get("fileIdx")
    try:
        file_idx = int(file_idx) if file_idx is not None else None
    except (TypeError, ValueError):
        file_idx = None
    size = hints.get("videoSize")
    try:
        size = int(size) if size is not None else None
    except (TypeError, ValueError):
        size = None
    playable = _is_playable(url)
    if playable:
        kind = "direct"
    elif external:
        kind = "external"
    else:
        kind = "torrent"
    return {
        "addon": addon_name,
        "addonSlug": _text(row.get("slug"), 120),
        "name": _text(raw.get("name"), 160),
        "title": _text(raw.get("title") or raw.get("description"), 300),
        "url": url,
        "externalUrl": external,
        "infoHash": info_hash,
        "fileIdx": file_idx,
        "filename": _text(hints.get("filename"), 240),
        "size": size,
        "kind": kind,
        "playable": playable,
    }


# <video> 直接喂不进去的容器：MKV/AVI/TS 等即使编码是 H.264 也无法内播，
# 这类链接只作为「外链」交给外部播放器，不再显示播放按钮。
_NON_BROWSER_EXT = re.compile(
    r"\.(mkv|avi|ts|m2ts|flv|wmv|rmvb|rm|iso|vob|divx)(?:[?#&]|$)", re.I
)


def _is_playable(url: str) -> bool:
    if not (url.startswith("http://") or url.startswith("https://")):
        return False
    return not _NON_BROWSER_EXT.search(url)


def _is_youtube_watch(url: str) -> bool:
    """网页观看地址不能直接进 <video>，按外链处理。"""
    lowered = url.lower()
    return "youtube.com/watch" in lowered or "youtu.be/" in lowered


def _direct_rank(url: str) -> int:
    """浏览器可直接解码的格式排前面：mp4/m3u8 → 未知 → mkv 等容器。"""
    match = re.search(r"\.(mp4|m4v|webm|m3u8?|mpd|mkv|avi|ts)(?:\?|$)", url, re.I)
    if not match:
        return 1
    return 0 if match.group(1).lower() in {"mp4", "m4v", "webm", "m3u", "m3u8", "mpd"} else 2


async def _fetch_streams(
    client: httpx.AsyncClient,
    row: dict[str, Any],
    media_type: str,
    stream_id: str,
    addon_name: str,
) -> list[dict[str, Any]]:
    transport = _text(row.get("transport"), 500).rstrip("/")
    if not transport:
        return []
    url = f"{transport}/stream/{media_type}/{stream_id}.json"
    try:
        response = await client.get(url, timeout=QUERY_TIMEOUT)
        if response.status_code != 200:
            return []
        payload = response.json()
    except (httpx.HTTPError, ValueError, OSError):
        return []
    if not isinstance(payload, dict):
        return []
    streams = payload.get("streams")
    if not isinstance(streams, list):
        return []
    rows: list[dict[str, Any]] = []
    for raw in streams:
        item = _normalize(row, addon_name, raw)
        if item:
            rows.append(item)
    return rows


def _dedupe(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    result: list[dict[str, Any]] = []
    for item in items:
        key = item["url"] or f"{item['infoHash']}:{item['fileIdx']}"
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(item)
    return result


async def collect(
    media_type: str,
    imdb_id: str,
    season: int = 0,
    episode: int = 0,
    any_id: bool = False,
) -> dict[str, Any]:
    """汇总所有已启用 addon 的片源；按可播放性排序后返回。

    ``any_id`` 为真时放宽 ``tt`` 前缀校验，允许用番号（如 ``SSIS-001``）
    直接查询支持关键词检索的 addon。
    """

    media_type = "series" if media_type == "series" else "movie"
    imdb_id = _text(imdb_id, 40)
    if not imdb_id or (not any_id and not imdb_id.startswith("tt")):
        return {"streams": [], "total": 0, "addons": 0, "reason": "缺少 IMDb ID"}
    key = f"{media_type}:{imdb_id}:{season}:{episode}:{int(any_id)}"
    now = time.monotonic()
    cached = _CACHE.get(key)
    if cached and cached[0] > now:
        streams = cached[1]
        return {"streams": streams[:MAX_STREAMS], "total": len(streams), "addons": 0}

    data = _read()
    rows = [
        row
        for row in data["addons"]
        if row.get("enabled", True) and candidate(row, media_type, imdb_id, "stream")
    ][:MAX_CANDIDATES]
    if not rows:
        return {"streams": [], "total": 0, "addons": 0, "reason": "没有可用的片源插件"}

    stream_id = _stream_id(imdb_id, season, episode)
    names = addon_names(rows)
    gathered = await gather(
        rows,
        names,
        lambda client, row, name: _fetch_streams(
            client, row, media_type, stream_id, name
        ),
        timeout=TOTAL_TIMEOUT,
        concurrency=CONCURRENCY,
    )

    order = {"direct": 0, "external": 1, "torrent": 2}
    streams = _dedupe(gathered)
    streams.sort(
        key=lambda item: (
            order.get(item["kind"], 3),
            _direct_rank(item["url"]),
            item["addon"],
        )
    )
    _CACHE[key] = (now + CACHE_TTL, streams)
    if len(_CACHE) > 64:
        _CACHE.clear()
        _CACHE[key] = (now + CACHE_TTL, streams)
    return {"streams": streams[:MAX_STREAMS], "total": len(streams), "addons": len(rows)}
