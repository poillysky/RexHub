"""MoviePilot 媒体自动化服务：设置与连通性探测。

鉴权方式：MoviePilot 开放 API 用 ``?apikey=<令牌>`` 查询参数，
例如 ``GET {base}/api/v1/user/?apikey=<令牌>``。
"""


import hashlib
import re
import time
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

import app.core.settings_store as settings_store
from app.search.pansou_client import _normalize_base

router = APIRouter(tags=["moviepilot"])

MOVIEPILOT_KEY = "moviepilot"
DEFAULT_BASE_URL = ""
DEFAULT_TIMEOUT_S = 15.0
# 需要鉴权的轻量接口：能返回用户列表即代表地址与令牌都有效
_PROBE_PATH = "/api/v1/user/"


class MoviePilotConfigBody(BaseModel):
    enabled: bool = True
    baseUrl: str = Field(default=DEFAULT_BASE_URL, max_length=300)
    apiKey: str = Field(default="", max_length=200)
    timeoutSec: float = Field(default=DEFAULT_TIMEOUT_S, ge=5, le=120)
    note: str = Field(default="", max_length=200)


def get_config(*, include_secrets: bool = False) -> dict[str, Any]:
    raw = settings_store.get_setting(MOVIEPILOT_KEY) or {}
    if not isinstance(raw, dict):
        raw = {}
    base = _normalize_base(str(raw.get("baseUrl") or ""))
    api_key = str(raw.get("apiKey") or "").strip()
    enabled = raw.get("enabled")
    if enabled is None:
        enabled = True
    timeout = float(raw.get("timeoutSec") or DEFAULT_TIMEOUT_S)
    out: dict[str, Any] = {
        "enabled": bool(enabled),
        "baseUrl": base,
        "timeoutSec": max(5.0, min(timeout, 120.0)),
        "hasApiKey": bool(api_key),
        "note": str(raw.get("note") or ""),
    }
    if include_secrets:
        out["apiKey"] = api_key
    return out


def _probe(base: str, api_key: str, timeout: float) -> dict[str, Any]:
    try:
        with httpx.Client(
            timeout=timeout, trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(f"{base}{_PROBE_PATH}", params={"apikey": api_key})
    except Exception as e:
        return {"ok": False, "message": f"连接失败: {e}"}
    if resp.status_code == 401:
        return {"ok": False, "message": "令牌无效（401）"}
    if resp.status_code >= 400:
        return {"ok": False, "message": f"HTTP {resp.status_code}"}
    try:
        payload = resp.json()
    except ValueError:
        return {"ok": False, "message": "响应不是 JSON"}
    if payload.get("success") is False:
        return {"ok": False, "message": str(payload.get("message") or "接口返回异常")}
    users = payload.get("data")
    return {
        "ok": True,
        "message": "连接成功",
        "userCount": len(users) if isinstance(users, list) else 0,
    }


def _wrap(data: Any, message: str = "ok", status: int = 200) -> dict[str, Any]:
    return {"data": data, "message": message, "status": status}


@router.get("/moviepilot/health")
def moviepilot_health() -> dict[str, Any]:
    cfg = get_config(include_secrets=True)
    base = str(cfg["baseUrl"])
    if not cfg["enabled"]:
        return _wrap({"ok": False, "configured": False, "baseUrl": base, "message": "未启用"})
    if not base:
        return _wrap({"ok": False, "configured": False, "baseUrl": "", "message": "未配置服务地址"})
    result = _probe(base, str(cfg.get("apiKey") or ""), float(cfg["timeoutSec"]))
    return _wrap({"configured": True, "baseUrl": base, **result})


@router.get("/settings/moviepilot")
def get_moviepilot_settings() -> dict[str, Any]:
    return _wrap(get_config(include_secrets=False))


# ---------------------------------------------------------------------------
# 推荐 / 探索内容代理
#
# MoviePilot 的推荐与探索是同一类「媒体列表」接口：
#   /api/v1/recommend/{module}、/api/v1/anilist/{module}、/api/v1/discover/{module}
# 这里统一代理并把条目规范成前端 MediaItem 结构（source/id/mediaType/...）。
# ---------------------------------------------------------------------------

_ALLOWED_PREFIXES = ("recommend/", "discover/", "anilist/")
_ALLOWED_PARAMS = {
    "page",
    "count",
    "sort",
    "tags",
    "sort_by",
    "with_genres",
    "with_original_language",
    "with_keywords",
    "with_watch_providers",
    "vote_average",
    "vote_count",
    "release_date",
    "type",
    "cat",
    "year",
    "genre",
    "format",
    "season",
    "season_year",
    "status",
    "country",
}
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
_CACHE_TTL_S = 300.0
_cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}


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


def _fetch_list(path: str, params: dict[str, str]) -> list[dict[str, Any]]:
    key = path + "?" + "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    now = time.time()
    hit = _cache.get(key)
    if hit and now - hit[0] < _CACHE_TTL_S:
        return hit[1]

    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise HTTPException(status_code=400, detail="MoviePilot 未启用")
    base = str(cfg["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="MoviePilot 未配置服务地址")
    api_key = str(cfg.get("apiKey") or "")
    try:
        with httpx.Client(
            timeout=float(cfg["timeoutSec"]), trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(
                f"{base}/api/v1/{path}", params={**params, "apikey": api_key}
            )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"MoviePilot 请求失败: {e}") from e
    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502, detail=f"MoviePilot 返回 HTTP {resp.status_code}"
        )
    try:
        payload = resp.json()
    except ValueError as e:
        raise HTTPException(status_code=502, detail="MoviePilot 响应不是 JSON") from e
    if payload.get("success") is False:
        raise HTTPException(
            status_code=502,
            detail=str(payload.get("message") or "MoviePilot 接口返回异常"),
        )
    raw_items = payload.get("data")
    if not isinstance(raw_items, list):
        raw_items = []
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in raw_items:
        item = _normalize_item(raw)
        if not item:
            continue
        uniq = f"{item['source']}:{item['id']}"
        if uniq in seen:
            continue
        seen.add(uniq)
        items.append(item)
    _cache[key] = (now, items)
    if len(_cache) > 256:
        _cache.clear()
    return items


@router.get("/moviepilot/list")
def moviepilot_list(path: str, request: Request) -> dict[str, Any]:
    clean = path.strip().strip("/")
    if not clean.startswith(_ALLOWED_PREFIXES):
        raise HTTPException(status_code=400, detail="不支持的 MoviePilot 列表路径")
    params = {
        k: v
        for k, v in request.query_params.items()
        if k in _ALLOWED_PARAMS and str(v).strip() != ""
    }
    items = _fetch_list(clean, params)
    return _wrap({"path": clean, "items": items, "total": len(items)})


# ---------------------------------------------------------------------------
# 详情 / 相关推荐代理
#
# MoviePilot 详情页自身使用：
#   /api/v1/media/{id}?media_source=&type_name=  → MediaInfo（演员/时长/类型/地区）
#   /api/v1/{source}/credits/...                 → 演职人员
#   /api/v1/tmdb/recommend|similar/{id}/{type}   → 相似推荐
# 这里代理并归一成前端 MediaItem / MediaCastPerson 结构。
# ---------------------------------------------------------------------------

_DETAIL_SOURCES = {
    "tmdb": "themoviedb",
    "douban": "douban",
    "bangumi": "bangumi",
    "anilist": "anilist",
}
_TYPE_NAMES = {"movie": "电影", "tv": "电视剧"}
_TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p/"
_detail_cache: dict[str, tuple[float, Any]] = {}


def _text(value: Any) -> str:
    return str(value or "").strip()


def _mp_get(
    path: str, params: dict[str, str] | None = None, *, timeout_s: float | None = None
) -> Any:
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise HTTPException(status_code=400, detail="MoviePilot 未启用")
    base = str(cfg["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="MoviePilot 未配置服务地址")
    try:
        with httpx.Client(
            timeout=float(timeout_s or cfg["timeoutSec"]),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            resp = client.get(
                f"{base}/api/v1/{path}",
                params={**(params or {}), "apikey": str(cfg.get("apiKey") or "")},
            )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"MoviePilot 请求失败: {e}") from e
    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502, detail=f"MoviePilot 返回 HTTP {resp.status_code}"
        )
    try:
        payload = resp.json()
    except ValueError as e:
        raise HTTPException(status_code=502, detail="MoviePilot 响应不是 JSON") from e
    if isinstance(payload, dict) and payload.get("success") is False:
        raise HTTPException(
            status_code=502,
            detail=str(payload.get("message") or "MoviePilot 接口返回异常"),
        )
    return payload.get("data") if isinstance(payload, dict) else payload


def _mp_post(
    path: str, body: dict[str, Any], *, timeout_s: float | None = None
) -> dict[str, Any]:
    """POST 到 MoviePilot，返回原始响应体（success=false 交由调用方判定）。"""
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise HTTPException(status_code=400, detail="MoviePilot 未启用")
    base = str(cfg["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="MoviePilot 未配置服务地址")
    try:
        with httpx.Client(
            timeout=float(timeout_s or cfg["timeoutSec"]),
            trust_env=False,
            follow_redirects=True,
        ) as client:
            resp = client.post(
                f"{base}/api/v1/{path}",
                params={"apikey": str(cfg.get("apiKey") or "")},
                json=body,
            )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"MoviePilot 请求失败: {e}") from e
    if resp.status_code == 401:
        raise HTTPException(status_code=502, detail="MoviePilot 令牌无效（401）")
    try:
        payload = resp.json()
    except ValueError as e:
        raise HTTPException(
            status_code=502, detail=f"MoviePilot 返回 HTTP {resp.status_code}"
        ) from e
    if not isinstance(payload, dict):
        raise HTTPException(status_code=502, detail="MoviePilot 响应格式异常")
    return payload


def _mp_get_rows(path: str) -> list[dict[str, Any]]:
    try:
        rows = _mp_get(path)
    except HTTPException:
        return []
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


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


@router.get("/moviepilot/detail")
def moviepilot_detail(
    source: str, id: str, mediaType: str = "movie"
) -> dict[str, Any]:
    key_source = source.strip().lower()
    if key_source not in _DETAIL_SOURCES:
        raise HTTPException(status_code=400, detail="不支持的数据源")
    media_type = mediaType if mediaType in _TYPE_NAMES else "movie"
    media_id = id.strip()
    if not media_id:
        raise HTTPException(status_code=400, detail="缺少条目 ID")

    cache_key = f"detail:{key_source}:{media_id}:{media_type}"
    now = time.time()
    hit = _detail_cache.get(cache_key)
    if hit and now - hit[0] < _CACHE_TTL_S:
        return _wrap(hit[1])

    raw = _mp_get(
        f"media/{media_id}",
        {
            "media_source": _DETAIL_SOURCES[key_source],
            "type_name": _TYPE_NAMES[media_type],
        },
    )
    item = _normalize_detail(raw, key_source, media_id, media_type)
    _detail_cache[cache_key] = (now, item)
    if len(_detail_cache) > 256:
        _detail_cache.clear()
    return _wrap(item)


@router.get("/moviepilot/related")
def moviepilot_related(
    source: str, id: str, mediaType: str = "movie"
) -> dict[str, Any]:
    key_source = source.strip().lower()
    if key_source not in _DETAIL_SOURCES:
        raise HTTPException(status_code=400, detail="不支持的数据源")
    media_type = mediaType if mediaType in _TYPE_NAMES else "movie"
    media_id = id.strip()
    if not media_id:
        raise HTTPException(status_code=400, detail="缺少条目 ID")

    cache_key = f"related:{key_source}:{media_id}:{media_type}"
    now = time.time()
    hit = _detail_cache.get(cache_key)
    if hit and now - hit[0] < _CACHE_TTL_S:
        return _wrap(hit[1])

    kind = "tv" if media_type == "tv" else "movie"
    similar: list[dict[str, Any]] = []
    recommendations: list[dict[str, Any]] = []
    if key_source == "tmdb":
        recommendations = _normalize_related(
            _mp_get_rows(f"tmdb/recommend/{media_id}/{kind}")
        )
        similar = _normalize_related(
            _mp_get_rows(f"tmdb/similar/{media_id}/{kind}")
        )
    elif key_source == "douban":
        recommendations = _normalize_related(
            _mp_get_rows(f"douban/recommend/{media_id}/{kind}")
        )
    elif key_source == "bangumi":
        recommendations = _normalize_related(
            _mp_get_rows(f"bangumi/recommend/{media_id}")
        )
    else:
        recommendations = _normalize_related(
            _mp_get_rows(f"anilist/recommend/{media_id}")
        )

    data = {"similar": similar, "recommendations": recommendations}
    _detail_cache[cache_key] = (now, data)
    if len(_detail_cache) > 256:
        _detail_cache.clear()
    return _wrap(data)


# ---------------------------------------------------------------------------
# 影人：详情 + 作品（MoviePilot 原生 /{source}/person/... 接口）
#
# 取代旧插件桥 /media/person/works，影人页完全走 MoviePilot。
# 作品接口每页固定 24 条，无 total，用「本页满 24 条」判断还有下一页。
# ---------------------------------------------------------------------------

_PERSON_SOURCES = {
    # 影人接口的 TMDB 前缀是 tmdb（详情/列表用的是 themoviedb），别混用
    "tmdb": "tmdb",
    "themoviedb": "tmdb",
    "douban": "douban",
    "bangumi": "bangumi",
    "anilist": "anilist",
}
_PERSON_PAGE_SIZE = 24
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
_person_cache: dict[str, tuple[float, Any]] = {}

# 豆瓣详情里的演员是旧版 celebrity id，MoviePilot 只认新版 personage id：
# 用旧 id 请求 MP 只会拿到空壳（name 为 null）。这里借豆瓣 rexxar 接口取
# personage id（payload.id）做一次换算并缓存。
_DOUBAN_REXXAR_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
)
_DOUBAN_MAP_TTL_S = 86400.0
_douban_personage_cache: dict[str, tuple[float, str | None]] = {}


def _douban_personage_id(celebrity_id: str) -> str | None:
    key = celebrity_id.strip()
    if not key:
        return None
    now = time.time()
    hit = _douban_personage_cache.get(key)
    if hit and now - hit[0] < _DOUBAN_MAP_TTL_S:
        return hit[1]
    resolved: str | None = None
    try:
        with httpx.Client(
            timeout=8.0, trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(
                f"https://m.douban.com/rexxar/api/v2/celebrity/{key}",
                headers={
                    "User-Agent": _DOUBAN_REXXAR_UA,
                    "Referer": f"https://m.douban.com/movie/celebrity/{key}/",
                },
            )
        if resp.status_code < 400:
            payload = resp.json()
            if str(payload.get("subtype") or "") == "person":
                pid = str(payload.get("id") or "").strip()
                if pid and pid != key:
                    resolved = pid
    except Exception:
        resolved = None
    if len(_douban_personage_cache) > 512:
        _douban_personage_cache.clear()
    _douban_personage_cache[key] = (now, resolved)
    return resolved


def _person_source(source: str) -> tuple[str, str]:
    """返回 (MoviePilot 数据源, 前端 MediaSourceId)。"""
    key = source.strip().lower()
    mapped = _PERSON_SOURCES.get(key)
    if not mapped:
        raise HTTPException(status_code=400, detail="不支持的影人数据源")
    return mapped, ("tmdb" if mapped == "themoviedb" else mapped)


def _resolve_person_id(src: str, person_id: str) -> str:
    """豆瓣旧 celebrity id → MP 可用 personage id；其他源原样返回。"""
    if src != "douban":
        return person_id
    return _douban_personage_id(person_id) or person_id


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


@router.get("/moviepilot/person")
def moviepilot_person(source: str, id: str) -> dict[str, Any]:
    src, key_source = _person_source(source)
    pid = id.strip()
    if not pid:
        raise HTTPException(status_code=400, detail="缺少影人 ID")

    cache_key = f"person:{src}:{pid}"
    now = time.time()
    hit = _person_cache.get(cache_key)
    if hit and now - hit[0] < _CACHE_TTL_S:
        return _wrap(hit[1])

    person = _normalize_person(_mp_get(f"{src}/person/{pid}"), key_source, pid)
    if not person["name"] and key_source == "douban":
        mapped = _douban_personage_id(pid)
        if mapped:
            pid = mapped
            person = _normalize_person(
                _mp_get(f"{src}/person/{pid}"), key_source, pid
            )
    if not person["name"]:
        raise HTTPException(status_code=404, detail="MoviePilot 未找到该影人")
    _person_cache[cache_key] = (now, person)
    if len(_person_cache) > 128:
        _person_cache.clear()
    return _wrap(person)


@router.get("/moviepilot/person/credits")
def moviepilot_person_credits(
    source: str, id: str, page: int = 1
) -> dict[str, Any]:
    src, _ = _person_source(source)
    pid = id.strip()
    if not pid:
        raise HTTPException(status_code=400, detail="缺少影人 ID")
    page_no = max(1, min(int(page or 1), 50))

    cache_key = f"person-credits:{src}:{pid}:{page_no}"
    now = time.time()
    hit = _person_cache.get(cache_key)
    if hit and now - hit[0] < _CACHE_TTL_S:
        return _wrap(hit[1])

    rows = _mp_get(
        f"{src}/person/credits/{_resolve_person_id(src, pid)}",
        {"page": str(page_no)},
    )
    raw_rows = rows if isinstance(rows, list) else []
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in raw_rows:
        item = _normalize_item(raw)
        if not item:
            continue
        uniq = f"{item['source']}:{item['id']}"
        if uniq in seen:
            continue
        seen.add(uniq)
        items.append(item)

    data = {
        "personId": pid,
        "page": page_no,
        "items": items,
        "hasMore": len(raw_rows) >= _PERSON_PAGE_SIZE,
    }
    _person_cache[cache_key] = (now, data)
    if len(_person_cache) > 128:
        _person_cache.clear()
    return _wrap(data)


# ---------------------------------------------------------------------------
# 影视搜索（片名 / 关键词）
#
# 走 MoviePilot 原生 /api/v1/media/search?title=&page=&count=&media_source=，
# 取代插件桥 /media/search。该接口不返回总条数，用「本页是否满 count」判断下一页。
# ---------------------------------------------------------------------------

_MEDIA_SEARCH_SOURCES = {
    "tmdb": "themoviedb",
    "themoviedb": "themoviedb",
    "douban": "douban",
    "bangumi": "bangumi",
    "anilist": "anilist",
}
_MEDIA_SEARCH_PAGE_SIZE = 20


@router.get("/moviepilot/media-search")
def moviepilot_media_search(
    source: str, keyword: str, page: int = 1
) -> dict[str, Any]:
    key = source.strip().lower()
    mp_source = _MEDIA_SEARCH_SOURCES.get(key)
    if not mp_source:
        raise HTTPException(status_code=400, detail="不支持的搜索数据源")
    kw = keyword.strip()
    if not kw:
        raise HTTPException(status_code=400, detail="请输入搜索关键词")
    page_no = max(1, min(int(page or 1), 50))

    cache_key = f"media-search:{mp_source}:{kw}:{page_no}"
    now = time.time()
    hit = _search_cache.get(cache_key)
    if hit and now - hit[0] < _SEARCH_CACHE_TTL_S:
        return _wrap(hit[1])

    rows = _mp_get(
        "media/search",
        {
            "title": kw,
            "page": str(page_no),
            "count": str(_MEDIA_SEARCH_PAGE_SIZE),
            "media_source": mp_source,
        },
    )
    raw_rows = rows if isinstance(rows, list) else []
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in raw_rows:
        item = _normalize_item(raw)
        if not item:
            continue
        uniq = f"{item['source']}:{item['id']}"
        if uniq in seen:
            continue
        seen.add(uniq)
        items.append(item)

    data = {
        "source": "tmdb" if mp_source == "themoviedb" else mp_source,
        "keyword": kw,
        "page": page_no,
        "items": items,
        # MoviePilot 的媒体搜索单次最多返回 20 条且不提供总数（第 2 页恒为空），
        # 因此不做翻页，一次性给满 20 条。
        "hasMore": False,
    }
    _search_cache[cache_key] = (now, data)
    if len(_search_cache) > 128:
        _search_cache.clear()
    return _wrap(data)


# ---------------------------------------------------------------------------
# PT 站点搜索
#
# MoviePilot 自身「资源搜索」走 /api/v1/search/title?keyword=&page=，
# 会并发搜索所有已配置 PT 站点并聚合结果。返回里含站点 Cookie / UA 等
# 敏感字段，这里只挑前端需要的字段透出。
# ---------------------------------------------------------------------------

_SEARCH_CACHE_TTL_S = 120.0
_search_cache: dict[str, tuple[float, Any]] = {}

# 提交下载时要把搜索结果里的 torrent_info（含站点 Cookie / UA）原样回传给 MP，
# 这些字段不适合透出到前端，按资源生成 downloadKey 在服务端短时缓存。
_DOWNLOAD_CACHE_TTL_S = 1800.0
_download_cache: dict[
    str, tuple[float, list[tuple[dict[str, Any], dict[str, Any]]]]
] = {}


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


@router.get("/moviepilot/search")
def moviepilot_search(
    keyword: str = "",
    source: str = "",
    id: str = "",
    mediaType: str = "",
    area: str = "title",
) -> dict[str, Any]:
    """PT 站点搜索，两种方式对齐 MoviePilot 自身的资源搜索：

    - 标题（默认）：/search/title?keyword=，并发搜索全部已启用站点
    - IMDb：/search/media/{id}?media_source=&mtype=&area=imdbid，
      由 MoviePilot 取媒体信息后按 IMDb 编号精确匹配
    """
    media_id = id.strip()
    mp_source = _DETAIL_SOURCES.get(source.strip().lower())
    mp_type = "tv" if mediaType.strip().lower() == "tv" else "movie"
    by_imdb = area.strip().lower() == "imdbid" and bool(media_id and mp_source)

    if by_imdb:
        path = f"search/media/{media_id}"
        params = {
            "media_source": mp_source,
            "mtype": mp_type,
            "area": "imdbid",
        }
        cache_key = f"ptsearch:id:{mp_source}:{media_id}:{mp_type}"
        label = media_id
    else:
        kw = keyword.strip()
        if not kw:
            raise HTTPException(status_code=400, detail="请输入搜索关键词")
        path = "search/title"
        params = {"keyword": kw}
        cache_key = f"ptsearch:{kw}"
        label = kw

    now = time.time()
    hit = _search_cache.get(cache_key)
    if hit and now - hit[0] < _SEARCH_CACHE_TTL_S:
        return _wrap(hit[1])

    # 多站点并发搜索较慢，单独放宽超时
    cfg = get_config(include_secrets=True)
    timeout_s = max(float(cfg["timeoutSec"]), 60.0)
    # MP 按页返回结果，这里逐页拉全量后一次下发，前端不再翻页
    rows: list[Any] = []
    seen_titles: set[str] = set()
    for page_no in range(1, 11):
        try:
            chunk = _mp_get(
                path, {**params, "page": str(page_no)}, timeout_s=timeout_s
            )
        except HTTPException:
            # 超出末页时 MP 返回 success=false「未搜索到任何资源」，视为已到末页
            if page_no == 1:
                raise
            break
        if not isinstance(chunk, list) or not chunk:
            break
        # 超出末页时部分版本会重复返回最后一页，按资源标题判断是否还有新数据
        titles = {
            str((raw.get("torrent_info") or {}).get("title") or "")
            for raw in chunk
            if isinstance(raw, dict)
        }
        fresh = titles - seen_titles
        if page_no > 1 and not fresh:
            break
        seen_titles |= fresh
        rows.extend(chunk)

    items: list[dict[str, Any]] = []
    # 跨站点合并：同名同体积视为同一资源，站点并列，做种/下载取最大，促销取最优
    merged: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    raw_candidates: dict[str, list[tuple[dict[str, Any], dict[str, Any]]]] = {}
    for raw in rows if isinstance(rows, list) else []:
        item = _normalize_torrent(raw)
        if not item:
            continue
        uniq = f"{item['title'].lower()}|{item['size'] or 0}"
        raw_torrent = raw.get("torrent_info")
        if isinstance(raw_torrent, dict):
            raw_media = raw.get("media_info")
            raw_candidates.setdefault(uniq, []).append(
                (raw_torrent, raw_media if isinstance(raw_media, dict) else {})
            )
        site = item.get("site") or ""
        cur = merged.get(uniq)
        if cur is None:
            item["sites"] = [site] if site else []
            merged[uniq] = item
            order.append(uniq)
            continue
        if site and site not in cur["sites"]:
            cur["sites"].append(site)
        if _promo_rank(item.get("volumeFactor")) > _promo_rank(cur.get("volumeFactor")):
            cur["volumeFactor"] = item.get("volumeFactor")
            cur["downloadVolumeFactor"] = item.get("downloadVolumeFactor")
        cur["seeders"] = max(cur["seeders"], item["seeders"])
        cur["peers"] = max(cur["peers"], item["peers"])
        cur["grabs"] = max(cur["grabs"], item["grabs"])
        cur["hitAndRun"] = bool(cur["hitAndRun"] or item["hitAndRun"])
        cur["labels"] = list(dict.fromkeys([*cur.get("labels", []), *item.get("labels", [])]))
        for key in (
            "pageUrl",
            "downloadUrl",
            "dateElapsed",
            "pubdate",
            "category",
            "seasonEpisode",
            "releaseGroup",
            "webSource",
            "edition",
            "resolution",
            "videoCode",
        ):
            if not cur.get(key) and item.get(key):
                cur[key] = item[key]
    items = [merged[key] for key in order]

    # 为每条资源分配下载令牌，原始 torrent_info 只留在服务端缓存里
    for key in order:
        token = hashlib.sha1(key.encode("utf-8")).hexdigest()[:24]
        merged[key]["downloadKey"] = token
        _download_cache[token] = (now, raw_candidates.get(key, []))
    if len(_download_cache) > 1024:
        for token, (saved_at, _) in list(_download_cache.items()):
            if now - saved_at > _DOWNLOAD_CACHE_TTL_S:
                _download_cache.pop(token, None)
        if len(_download_cache) > 1024:
            _download_cache.clear()

    data = {
        "keyword": label,
        "mode": "imdbid" if by_imdb else "title",
        "page": 1,
        "items": items,
        "total": len(items),
    }
    _search_cache[cache_key] = (now, data)
    if len(_search_cache) > 128:
        _search_cache.clear()
    return _wrap(data)


# ---------------------------------------------------------------------------
# 提交下载
#
# MP 的 POST /api/v1/download/ 需要 media_in + torrent_in，成功返回
# data.download_id（下载器任务 hash）；再轮询 GET /api/v1/download/
# 确认任务已进入下载器。
# ---------------------------------------------------------------------------


class MoviePilotDownloadBody(BaseModel):
    key: str = Field(min_length=1, max_length=64)
    source: str = Field(default="", max_length=40)
    mediaId: str = Field(default="", max_length=40)
    mediaType: str = Field(default="", max_length=20)
    title: str = Field(default="", max_length=300)
    originalTitle: str = Field(default="", max_length=300)
    year: str = Field(default="", max_length=10)
    posterUrl: str = Field(default="", max_length=600)
    downloader: str = Field(default="", max_length=80)
    savePath: str = Field(default="", max_length=300)


def _media_in_from_body(body: MoviePilotDownloadBody) -> dict[str, Any]:
    """把前端媒体条目转成 MP MediaInfo（字段全可选，只填已知项）。"""
    mp_source = _DETAIL_SOURCES.get(body.source.strip().lower())
    mid = body.mediaId.strip()
    media: dict[str, Any] = {
        "type": "电视剧" if body.mediaType.strip().lower() == "tv" else "电影"
    }
    if body.title.strip():
        media["title"] = body.title.strip()
    if body.originalTitle.strip():
        media["en_title"] = body.originalTitle.strip()
    if body.year.strip():
        media["year"] = body.year.strip()
    if body.posterUrl.strip():
        media["poster_path"] = body.posterUrl.strip()
    if mp_source and mid:
        media["media_source"] = mp_source
        media["media_id"] = mid
        if mp_source == "themoviedb" and mid.isdigit():
            media["tmdb_id"] = int(mid)
        elif mp_source == "douban":
            media["douban_id"] = mid
        elif mp_source == "bangumi" and mid.isdigit():
            media["bangumi_id"] = int(mid)
        elif mp_source == "anilist" and mid.isdigit():
            media["anilist_id"] = int(mid)
    return media


def _pick_download_candidate(
    candidates: list[tuple[dict[str, Any], dict[str, Any]]],
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """同一资源命中多个站点时，优先免费、再做种多的那个站点。"""

    def score(cand: tuple[dict[str, Any], dict[str, Any]]) -> tuple[int, int]:
        torrent = cand[0]
        return (
            _promo_rank(torrent.get("volume_factor")),
            int(_num(torrent.get("seeders")) or 0),
        )

    return max(candidates, key=score) if candidates else None


@router.post("/moviepilot/download")
def moviepilot_download(body: MoviePilotDownloadBody) -> dict[str, Any]:
    """提交下载任务到 MoviePilot，返回任务 hash 供前端轮询。"""
    key = body.key.strip()
    hit = _download_cache.get(key)
    if not hit or time.time() - hit[0] > _DOWNLOAD_CACHE_TTL_S:
        _download_cache.pop(key, None)
        raise HTTPException(status_code=404, detail="资源信息已过期，请重新搜索")
    picked = _pick_download_candidate(hit[1])
    if not picked:
        raise HTTPException(status_code=404, detail="资源信息不完整，请重新搜索")
    torrent_in = picked[0]
    payload: dict[str, Any] = {
        "media_in": _media_in_from_body(body),
        "torrent_in": torrent_in,
    }
    if body.downloader.strip():
        payload["downloader"] = body.downloader.strip()
    if body.savePath.strip():
        payload["save_path"] = body.savePath.strip()
    resp = _mp_post("download/", payload, timeout_s=60.0)
    if resp.get("success") is False:
        raise HTTPException(
            status_code=400,
            detail=str(resp.get("message") or "MoviePilot 添加下载失败"),
        )
    data = resp.get("data") if isinstance(resp.get("data"), dict) else {}
    return _wrap(
        {
            "downloadId": _text(data.get("download_id")),
            "title": _text(torrent_in.get("title")),
            "site": _text(torrent_in.get("site_name")),
        }
    )


@router.get("/moviepilot/download/status")
def moviepilot_download_status(
    downloadId: str = "", title: str = ""
) -> dict[str, Any]:
    """轮询下载器任务：优先按 hash 匹配，其次按标题匹配。"""
    rows = _mp_get_rows("download/")
    hash_key = downloadId.strip().lower()
    title_key = title.strip().lower()
    match: dict[str, Any] | None = None
    for row in rows:
        if hash_key and _text(row.get("hash")).lower() == hash_key:
            match = row
            break
    if match is None and title_key:
        for row in rows:
            for field in ("title", "name"):
                name = _text(row.get(field)).lower()
                if name and (name.startswith(title_key) or title_key in name):
                    match = row
                    break
            if match is not None:
                break
    if match is None:
        return _wrap({"found": False, "total": len(rows)})
    return _wrap(
        {
            "found": True,
            "hash": _text(match.get("hash")) or None,
            "title": _text(match.get("title")) or _text(match.get("name")) or None,
            "state": _text(match.get("state")) or None,
            "progress": _num(match.get("progress")) or 0.0,
            "size": _num(match.get("size")),
            "downloader": _text(match.get("downloader")) or None,
            "dlspeed": _text(match.get("dlspeed")) or None,
            "leftTime": _text(match.get("left_time")) or None,
        }
    )


@router.put("/settings/moviepilot")
def put_moviepilot_settings(body: MoviePilotConfigBody) -> dict[str, Any]:
    base = _normalize_base(body.baseUrl)
    if not base:
        raise HTTPException(status_code=400, detail="baseUrl 不能为空")
    prev = settings_store.get_setting(MOVIEPILOT_KEY) or {}
    if not isinstance(prev, dict):
        prev = {}
    api_key = body.apiKey.strip()
    if not api_key:
        api_key = str(prev.get("apiKey") or "")
    settings_store.put_setting(
        MOVIEPILOT_KEY,
        {
            "enabled": body.enabled,
            "baseUrl": base,
            "apiKey": api_key,
            "timeoutSec": body.timeoutSec,
            "note": body.note.strip(),
        },
    )
    return _wrap(get_config(include_secrets=False), "saved")
