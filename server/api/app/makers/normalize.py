"""片商域：纯归一化 / 格式化函数（无 IO、无路由依赖）。"""

from __future__ import annotations

import re
from typing import Any

_WORD_RE = re.compile(r"[0-9a-z\u3040-\u30ff\u4e00-\u9fff]+")
_SHARE_URL_RE = re.compile(r"https?://\S+")


def _s(row: dict[str, Any], *keys: str, default: str = "") -> str:
    for key in keys:
        val = row.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    return default


def _int(val: Any, default: int = 0) -> int:
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


def _num(val: Any, default: float = 0.0) -> float:
    """评分等字段上游给的是数字字符串（如 ``"4.61"``），``int`` 会归零。"""
    try:
        return float(val)
    except (TypeError, ValueError):
        return default


def _bool(val: Any) -> bool:
    """上游偶尔返回 "0"/"false"/"1" 之类的字符串，避免被当成真值。"""
    if isinstance(val, str):
        return val.strip().lower() in {"1", "true", "yes", "y"}
    return bool(val)


def _normalize_movie(raw: dict[str, Any]) -> dict[str, Any]:
    cover = _s(raw, "cover_url", "coverUrl", "cover")
    preview = ""
    previews_raw = raw.get("preview_images")
    if isinstance(previews_raw, list) and previews_raw:
        first = previews_raw[0]
        if isinstance(first, dict):
            preview = _s(first, "thumb_url", "thumbUrl", "large_url")
    return {
        "id": _s(raw, "id", "movie_id", "movieId", "code_id"),
        "number": _s(raw, "number", "code", "movie_number"),
        "title": _s(raw, "title", "name"),
        "coverUrl": cover or None,
        "thumbUrl": _s(raw, "thumb_url", "thumbUrl") or None,
        "previewUrl": preview or None,
        "releaseDate": _s(raw, "release_date", "releaseDate") or None,
        "duration": _int(raw.get("duration")),
        "magnetsCount": _int(raw.get("magnets_count", raw.get("magnetsCount"))),
        "hasCnsub": _bool(raw.get("has_cnsub") or raw.get("hasCnsub")),
    }


def _movie_rows(data: Any) -> list[dict[str, Any]]:
    rows = data.get("movies") if isinstance(data, dict) else data
    movies = [
        _normalize_movie(r) for r in (rows or []) if isinstance(r, dict)
    ]
    # 以归一化后的 id 为准（上游字段名有 id / movie_id / code_id 三种）
    return [m for m in movies if m["id"]]


def _sniff_image(raw: bytes) -> str:
    """按魔数判断图片类型（AVDB img-proxy 可能返回 jpeg / webp / png / gif）。"""
    if raw[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "image/webp"
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if raw[:3] == b"GIF":
        return "image/gif"
    if raw[:2] == b"BM":
        return "image/bmp"
    return "image/jpeg"


def _words(text: str) -> list[str]:
    return _WORD_RE.findall(str(text).lower())


def _share_url(raw: dict[str, Any]) -> str:
    """从 ``share_info`` 中提取第一个链接（无则返回空串）。"""
    m = _SHARE_URL_RE.search(_s(raw, "share_info", "shareInfo"))
    return m.group(0) if m else ""


def _norm_person(raw: Any) -> dict[str, Any] | None:
    if isinstance(raw, str):
        name = raw.strip()
        return {"id": "", "name": name, "avatarUrl": None} if name else None
    if not isinstance(raw, dict):
        return None
    name = _s(raw, "name", "actor_name")
    if not name:
        return None
    return {
        "id": _s(raw, "id", "actor_id"),
        "name": name,
        "avatarUrl": _s(raw, "avatar_url", "avatarUrl", "image") or None,
    }


def _norm_tag(raw: Any) -> str:
    if isinstance(raw, str):
        return raw.strip()
    if isinstance(raw, dict):
        return _s(raw, "name", "tag")
    return ""


def _norm_magnet(raw: dict[str, Any]) -> dict[str, Any]:
    size = _s(raw, "size")
    size_bytes = _int(raw.get("size_bytes", raw.get("sizeBytes")))
    if not size and size_bytes > 0:
        size = f"{size_bytes / 1024**3:.1f} GB"
    elif size.isdigit():
        size = f"{size} MB"
    return {
        "name": _s(raw, "name", "title"),
        "url": _s(raw, "magnet_url", "magnetUrl", "url", "link"),
        "size": size or None,
        "sizeBytes": size_bytes,
        "createdAt": _s(raw, "created_at", "createdAt") or None,
        "filesCount": _int(raw.get("files_count", raw.get("filesCount"))),
        "hasCnsub": _bool(raw.get("cnsub")),
        "hd": _bool(raw.get("hd")),
    }


def _norm_torrent(raw: dict[str, Any]) -> dict[str, Any]:
    size_bytes = _int(raw.get("size_bytes"))
    size_mb = raw.get("size_mb")
    try:
        size_mb_val = float(size_mb) if size_mb is not None else 0.0
    except (TypeError, ValueError):
        size_mb_val = 0.0
    tags_raw = raw.get("tags")
    tags = [
        str(t).strip()
        for t in (tags_raw if isinstance(tags_raw, list) else [])
        if isinstance(t, (str, int, float)) and str(t).strip()
    ]
    return {
        "id": str(raw.get("id") or ""),
        "emby": _int(raw.get("emby")),
        "number": _s(raw, "number"),
        "site": _s(raw, "site") or None,
        "website": _s(raw, "website") or None,
        "section": _s(raw, "section") or None,
        "category": _s(raw, "category") or None,
        "title": _s(raw, "title"),
        "sizeMb": size_mb_val,
        "sizeBytes": size_bytes,
        "postTime": _s(raw, "post_time") or None,
        "seeders": _int(raw.get("seeders")),
        "downloadUrl": _s(raw, "download_url"),
        "previewImage": _s(raw, "preview_image") or None,
        "free": _bool(raw.get("free")),
        "tags": tags,
        "chinese": _bool(raw.get("chinese")),
        "uncensored": _bool(raw.get("uncensored")),
        "uc": _bool(raw.get("uc")),
        "hd": _bool(raw.get("hd")),
        "uhd": _bool(raw.get("uhd")),
        "mosaic": _bool(raw.get("mosaic")),
    }


def _torrent_numbers(number: str) -> list[str]:
    """``IPZZ-991,IPZZ-00991`` → 两个番号。"""
    return [p.strip().upper() for p in number.split(",") if p.strip()]


def _dedupe_torrents(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """上游存在同资源重复行（仅 id 不同），按番号+站点+大小+链接去重。"""
    seen: set[tuple[str, str, int, str]] = set()
    out: list[dict[str, Any]] = []
    for t in items:
        key = (t["number"], t["website"] or "", t["sizeBytes"], t["downloadUrl"])
        if key in seen:
            continue
        seen.add(key)
        out.append(t)
    return out


def _norm_entity(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    name = _s(raw, "name")
    if not name:
        return None
    return {
        "id": _s(raw, "id"),
        "type": _int(raw.get("type"), -1),
        "name": name,
        "videosCount": _int(raw.get("videos_count")),
    }


def _norm_list(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    name = _s(raw, "name")
    lid = _s(raw, "id")
    if not name or not lid:
        return None
    share_info = _s(raw, "share_info", "shareInfo")
    m = _SHARE_URL_RE.search(share_info)
    return {
        "id": lid,
        "name": name,
        "description": _s(raw, "description") or None,
        "moviesCount": _int(raw.get("movies_count")),
        "viewsCount": _int(raw.get("views_count")),
        "collectionsCount": _int(raw.get("collections_count")),
        "isDefault": _bool(raw.get("is_default")),
        "shareUrl": (m.group(0) if m else None),
        "createdAt": _s(raw, "created_at") or None,
    }
