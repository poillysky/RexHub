"""字幕聚合：并发查询已启用 addon 的 subtitles 资源，供网页播放器挂 <track>。

Stremio 的 subttiles 响应形如 ``{"subtitles": [{"id", "url", "lang"}]}``，
url 多为 SRT，浏览器 <track> 只认 WebVTT，因此播放端统一走
``/api/media/subtitle-proxy`` 做转发与 SRT→VTT 转换。
"""

import asyncio
import re
from typing import Any
from urllib.parse import urljoin

import httpx

from .storage import _read
from .streams import _UA, _proxy_url, _resource_names, _text

QUERY_TIMEOUT = 6.0
TOTAL_TIMEOUT = 7.0
CONCURRENCY = 60
PER_ADDON_ROWS = 40
MAX_ROWS = 80


def _candidate(row: dict[str, Any], media_type: str, imdb_id: str) -> bool:
    manifest = row.get("manifest")
    if not isinstance(manifest, dict) or "subtitles" not in _resource_names(manifest):
        return False
    types = [str(item) for item in manifest.get("types") or []]
    if types and media_type not in types:
        return False
    prefixes = manifest.get("idPrefixes")
    if isinstance(prefixes, list) and prefixes:
        if not any(imdb_id.startswith(str(prefix)) for prefix in prefixes):
            return False
    return True


def _subtitle_id(imdb_id: str, season: int, episode: int) -> str:
    if season > 0 and episode > 0:
        return f"{imdb_id}:{season}:{episode}"
    return imdb_id


def _lang_rank(lang: str) -> int:
    lowered = lang.lower()
    if lowered.startswith("zh") or "chinese" in lowered or "中文" in lowered:
        return 0
    if lowered.startswith("en") or "english" in lowered:
        return 1
    return 2


async def _fetch(
    client: httpx.AsyncClient,
    row: dict[str, Any],
    media_type: str,
    subtitle_id: str,
    addon_name: str,
) -> list[dict[str, Any]]:
    transport = _text(row.get("transport"), 500).rstrip("/")
    if not transport:
        return []
    url = f"{transport}/subtitles/{media_type}/{subtitle_id}.json"
    try:
        response = await client.get(url, timeout=QUERY_TIMEOUT)
        if response.status_code != 200:
            return []
        payload = response.json()
    except (httpx.HTTPError, ValueError, OSError):
        return []
    if not isinstance(payload, dict):
        return []
    raw_items = payload.get("subtitles")
    if not isinstance(raw_items, list):
        return []
    base = f"{transport}/"
    rows: list[dict[str, Any]] = []
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        target = _text(raw.get("url"), 2000)
        if not target:
            continue
        if target.startswith("/"):
            target = urljoin(base, target)
        if not target.startswith(("http://", "https://")):
            continue
        # 未配置的插件会返回 sub-error.vtt 之类的占位字幕
        if "sub-error" in target:
            continue
        lang = _text(raw.get("lang"), 20)
        rows.append(
            {
                "addon": addon_name,
                "addonSlug": _text(row.get("slug"), 120),
                "id": _text(raw.get("id"), 200),
                "url": target,
                "lang": lang,
                "label": _text(raw.get("label") or lang, 60),
            }
        )
        if len(rows) >= PER_ADDON_ROWS:
            break
    return rows


async def collect(
    media_type: str,
    imdb_id: str,
    season: int = 0,
    episode: int = 0,
) -> dict[str, Any]:
    media_type = "series" if media_type == "series" else "movie"
    imdb_id = _text(imdb_id, 40)
    if not imdb_id.startswith("tt"):
        return {"subtitles": [], "total": 0, "reason": "缺少 IMDb ID"}

    data = _read()
    rows = [
        row
        for row in data["addons"]
        if row.get("enabled", True) and _candidate(row, media_type, imdb_id)
    ]
    if not rows:
        return {"subtitles": [], "total": 0, "reason": "没有可用的字幕插件"}

    names = {
        row.get("slug"): (
            _text((row.get("manifest") or {}).get("name"), 80)
            or _text(row.get("slug"), 80)
        )
        for row in rows
    }
    subtitle_id = _subtitle_id(imdb_id, season, episode)
    client_kwargs: dict[str, Any] = {
        "headers": {"User-Agent": _UA, "Accept": "application/json, */*"},
        "follow_redirects": True,
        "limits": httpx.Limits(max_connections=CONCURRENCY),
    }
    proxy = _proxy_url()
    if proxy:
        client_kwargs["proxy"] = proxy

    async with httpx.AsyncClient(**client_kwargs) as client:
        tasks = [
            asyncio.create_task(
                _fetch(client, row, media_type, subtitle_id, names[row.get("slug")])
            )
            for row in rows
        ]
        done, pending = await asyncio.wait(tasks, timeout=TOTAL_TIMEOUT)
        for task in pending:
            task.cancel()
        gathered: list[dict[str, Any]] = []
        for task in done:
            if task.cancelled():
                continue
            try:
                gathered.extend(task.result())
            except (httpx.HTTPError, ValueError, OSError):
                continue

    seen: set[str] = set()
    items: list[dict[str, Any]] = []
    for item in gathered:
        if item["url"] in seen:
            continue
        seen.add(item["url"])
        items.append(item)
    items.sort(key=lambda item: (_lang_rank(item["lang"]), item["addon"]))
    return {
        "subtitles": items[:MAX_ROWS],
        "total": len(items),
        "reason": "" if items else "已启用的字幕插件没有返回字幕",
    }


def srt_to_vtt(text: str) -> str:
    """把 SRT 粗略转成 WebVTT；已是 VTT 的原样返回。"""
    cleaned = text.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")
    if cleaned.lstrip().upper().startswith("WEBVTT"):
        return cleaned
    out = ["WEBVTT", ""]
    for block in re.split(r"\n{2,}", cleaned.strip()):
        lines = [line for line in block.split("\n") if line.strip()]
        if lines and re.fullmatch(r"\d+", lines[0].strip()):
            lines = lines[1:]
        if not lines:
            continue
        lines[0] = lines[0].replace(",", ".")
        out.append("\n".join(lines))
        out.append("")
    return "\n".join(out)
