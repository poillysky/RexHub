"""MoviePilot 响应归一化：列表条目、详情、影人、种子资源。

这里只做纯数据转换，不发起网络请求、不读写缓存。
"""

import re
from typing import Any

_SOURCE_MAP = {
    "themoviedb": "tmdb",
    "tmdb": "tmdb",
    "douban": "douban",
    "bangumi": "bangumi",
    "anilist": "anilist",
}
_ID_FIELDS = {
    "tmdb": "tmdb_id",
    "douban": "douban_id",
    "bangumi": "bangumi_id",
    "anilist": "anilist_id",
}
_TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p/"
_GENDER_LABELS = {1: "女", 2: "男"}
_DEPARTMENT_LABELS = {
    "acting": "演员",
    "directing": "导演",
    "writing": "编剧",
    "production": "制片",
    "camera": "摄影",
    "sound": "音效",
    "art": "美术",
    "editing": "剪辑",
    "costume & make-up": "服装",
}


def _media_kind(raw: dict[str, Any]) -> str:
    kind = str(raw.get("type") or "")
    if "剧" in kind or kind.lower() in ("tv", "series"):
        return "tv"
    return "movie"


def _normalize_item(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    source = _SOURCE_MAP.get(str(raw.get("media_source") or "").strip().lower())
    if not source:
        return None
    mid = raw.get(_ID_FIELDS[source])
    if mid is None or str(mid).strip() == "":
        return None
    title = str(raw.get("title") or "").strip()
    if not title:
        return None
    aka: list[str] = []
    for key in ("en_title", "hk_title", "tw_title", "sg_title"):
        value = str(raw.get(key) or "").strip()
        if value and value != title and value not in aka:
            aka.append(value)
    rating: float | None
    try:
        rating = float(raw.get("vote_average"))
    except (TypeError, ValueError):
        rating = None
    if rating is not None and rating <= 0:
        rating = None
    year = str(raw.get("year") or "").strip()
    if not year:
        m = re.match(
            r"^(\d{4})",
            str(raw.get("release_date") or raw.get("first_air_date") or ""),
        )
        year = m.group(1) if m else ""
    poster = str(raw.get("poster_path") or "").strip()
    return {
        "source": source,
        "id": str(mid).strip(),
        "mediaType": _media_kind(raw),
        "title": title,
        "originalTitle": str(raw.get("original_title") or "").strip() or None,
        "aka": aka,
        "posterUrl": poster or None,
        "year": year or None,
        "rating": rating,
        "overview": str(raw.get("overview") or "").strip() or None,
    }


def _text(value: Any) -> str:
    return str(value or "").strip()


def _avatar_url(person: dict[str, Any]) -> str | None:
    profile = _text(person.get("profile_path"))
    if profile:
        if profile.startswith(("http://", "https://")):
            return profile
        return f"{_TMDB_IMAGE_BASE}w185{profile}"
    for key in ("images", "avatar"):
        value = person.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, dict):
            for size in ("large", "medium", "normal", "small", "grid"):
                url = _text(value.get(size))
                if url:
                    return url
    return None


def _cast_rows(raw: Any) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for person in raw if isinstance(raw, list) else []:
        if not isinstance(person, dict):
            continue
        name = _text(person.get("name"))
        if not name:
            continue
        pid = person.get("id")
        rows.append(
            {
                "id": _text(pid) or None,
                "name": name,
                "avatarUrl": _avatar_url(person),
            }
        )
    return rows


def _normalize_detail(
    raw: Any, source: str, media_id: str, media_type: str
) -> dict[str, Any]:
    row = raw if isinstance(raw, dict) else {}
    title = _text(row.get("title")) or _text(row.get("name"))
    original = _text(row.get("original_title")) or _text(row.get("original_name"))
    aka: list[str] = []
    for value in [original, row.get("en_title"), *(row.get("names") or [])]:
        text = _text(value)
        if text and text != title and text not in aka:
            aka.append(text)
        if len(aka) >= 8:
            break

    genres: list[str] = []
    for genre in row.get("genres") or []:
        text = _text(genre.get("name") if isinstance(genre, dict) else genre)
        if text and text not in genres:
            genres.append(text)

    countries: list[str] = []
    for country in row.get("production_countries") or []:
        text = _text(country.get("name") if isinstance(country, dict) else country)
        if text and text not in countries:
            countries.append(text)

    runtime = row.get("runtime")
    if not runtime:
        run_times = row.get("episode_run_time")
        if isinstance(run_times, list) and run_times:
            runtime = run_times[0]
    try:
        runtime_min = int(float(runtime)) if runtime else None
    except (TypeError, ValueError):
        runtime_min = None

    try:
        rating = float(row.get("vote_average"))
    except (TypeError, ValueError):
        rating = None
    if rating is not None and rating <= 0:
        rating = None

    year = _text(row.get("year"))
    if not year:
        match = re.match(
            r"^(\d{4})",
            _text(row.get("release_date") or row.get("first_air_date")),
        )
        year = match.group(1) if match else ""

    poster = _text(row.get("poster_path"))
    return {
        "source": source,
        "id": _text(media_id),
        "mediaType": media_type,
        "title": title,
        "originalTitle": original or None,
        "aka": aka,
        "posterUrl": poster or None,
        "year": year or None,
        "rating": rating,
        "overview": _text(row.get("overview")) or None,
        "cast": _cast_rows(row.get("actors")),
        "genres": genres,
        "runtime": runtime_min,
        "countries": countries,
        "imdbId": _text(row.get("imdb_id")) or None,
    }


def _normalize_related(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in rows:
        item = _normalize_item(row)
        if not item:
            continue
        uniq = f"{item['source']}:{item['id']}"
        if uniq in seen:
            continue
        seen.add(uniq)
        items.append(item)
    return items


def _person_gender(value: Any) -> str | None:
    text = _text(value)
    if not text:
        return None
    if text.isdigit():
        return _GENDER_LABELS.get(int(text))
    low = text.lower()
    if low in ("male", "man"):
        return "男"
    if low in ("female", "woman"):
        return "女"
    return text


def _normalize_person(raw: Any, source: str, person_id: str) -> dict[str, Any]:
    row = raw if isinstance(raw, dict) else {}
    birthday = _text(row.get("birthday")) or None
    deathday = _text(row.get("deathday")) or None
    place = _text(row.get("place_of_birth")) or None
    gender = _person_gender(row.get("gender"))
    imdb_id = _text(row.get("imdb_id")) or None
    aliases: list[str] = []
    for value in row.get("also_known_as") or []:
        text = _text(value)
        if not text:
            continue
        # 豆瓣把「性别：男」「出生日期：…」这类字段塞进 also_known_as，
        # 这里拆回结构化字段，避免影人页把整句当别名展示。
        label, sep, val = text.partition("：")
        val = val.strip()
        if sep and val:
            if label == "性别" and not gender:
                gender = val
                continue
            if label == "出生日期" and not birthday:
                birthday = val
                continue
            if label == "出生地" and not place:
                place = val
                continue
            if label == "IMDb编号" and not imdb_id:
                imdb_id = val
                continue
            if label in ("更多中文名", "更多外文名"):
                for part in re.split(r"[/、]", val):
                    part = part.strip()
                    if part and part not in aliases:
                        aliases.append(part)
                continue
            # 其余「家庭成员：…」「职业：…」等只是豆瓣的元信息，不是别名
            continue
        if text not in aliases:
            aliases.append(text)
    department = _text(row.get("known_for_department"))
    return {
        "source": source,
        "id": person_id,
        "name": _text(row.get("name")) or _text(row.get("original_name")),
        "originalName": _text(row.get("original_name")) or None,
        "avatarUrl": _avatar_url(row),
        "birthday": birthday,
        "deathday": deathday,
        "placeOfBirth": place,
        "gender": gender,
        "department": _DEPARTMENT_LABELS.get(department.lower(), department)
        or None,
        "aliases": aliases[:8],
        "biography": _text(row.get("biography")) or None,
        "imdbId": imdb_id,
    }


def _num(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _promo_rank(value: Any) -> int:
    """促销标签优先级：免费 > 折扣 / 2X > 普通，用于跨站合并时取最优。"""
    text = _text(value).upper()
    if not text:
        return 0
    if "免费" in text:
        return 3
    if "2X" in text or "%" in text:
        return 2
    return 1


def _normalize_torrent(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    info = raw.get("torrent_info")
    if not isinstance(info, dict):
        return None
    title = _text(info.get("title"))
    if not title:
        return None
    labels = info.get("labels")
    meta = raw.get("meta_info")
    if not isinstance(meta, dict):
        meta = {}
    return {
        "site": _text(info.get("site_name")) or _text(info.get("site")),
        "title": title,
        "description": _text(info.get("description"))[:400] or None,
        "category": _text(info.get("category")) or None,
        "size": _num(info.get("size")),
        "seeders": int(_num(info.get("seeders")) or 0),
        "peers": int(_num(info.get("peers")) or 0),
        "grabs": int(_num(info.get("grabs")) or 0),
        "pubdate": _text(info.get("pubdate")) or None,
        "dateElapsed": _text(info.get("date_elapsed")) or None,
        "volumeFactor": _text(info.get("volume_factor")) or None,
        # 以下字段与 MoviePilot 资源筛选条一一对应（直接取 meta_info，不做标题推测）
        "seasonEpisode": _text(meta.get("season_episode")) or None,
        "releaseGroup": _text(meta.get("resource_team")) or None,
        "webSource": _text(meta.get("web_source")) or None,
        "edition": _text(meta.get("edition")) or None,
        "resolution": _text(meta.get("resource_pix")) or None,
        "videoCode": _text(meta.get("video_encode")) or None,
        "downloadVolumeFactor": _num(info.get("downloadvolumefactor")),
        "hitAndRun": bool(info.get("hit_and_run")),
        "labels": [str(x) for x in labels] if isinstance(labels, list) else [],
        "pageUrl": _text(info.get("page_url")) or None,
        "downloadUrl": _text(info.get("enclosure")) or None,
    }
