"""片商页：AVDB 榜单/搜索/影片/磁力代理。

- ``/makers/rank``        AVDB 榜单（类别 × 日/周/月）
- ``/makers/search``      AVDB 片商搜索
- ``/makers/movies``      片商影片（先解析 maker id，取完整片库；失败退回番号搜索）
- ``/makers/movie/{id}``  影片详情 + 磁力列表
"""

from __future__ import annotations

import re
import time
from functools import lru_cache
from typing import Any

from fastapi import APIRouter, HTTPException, Query, Response

from app.search.avdb_client import (
    TORRENTS_PATH,
    AvdbError,
    request_bytes,
    request_json,
)

router = APIRouter(prefix="/makers", tags=["makers"])

CATEGORIES: dict[str, str] = {
    "0": "有码",
    "1": "无码",
    "2": "欧美",
    "3": "FC2",
    "4": "动漫",
}

# AVDB 榜单（rankings / movies/top）只对 0-3 有独立数据：
# rankings 的 type=4 会原样返回 type=0 的榜单，movies/top 的 type=4 为空。
RANK_CATEGORIES = {"0", "1", "2", "3"}

# 「分类浏览」各标签组对应的 AVDB 查询参数（其余组走 tag_id）。
TAG_GROUP_PARAM: dict[str, str] = {
    "main": "main_filter",
    "year": "year",
    "month": "month",
    "duration": "duration",
}

PERIODS: dict[str, str] = {
    "daily": "日榜",
    "weekly": "周榜",
    "monthly": "月榜",
}

MOVIE_LIMIT_MAX = 48

# 可播放榜（rankings/playback）筛选：all 热播榜 / high_score 高分重排（官方「热门」tab）
PLAYBACK_FILTERS: dict[str, str] = {
    "all": "热播",
    "high_score": "热门",
}

# 最新（movies/latest）筛选：all 全部 / magnets 含磁链 / subtitle 含字幕
LATEST_FILTERS: dict[str, str] = {
    "all": "全部",
    "magnets": "含磁链",
    "subtitle": "含字幕",
}

# 影片搜索（search?type=movie）的 movie_filter_by 取值（cnsub 会被上游忽略，字幕用 subtitle）
MOVIE_SEARCH_FILTERS = {"all", "subtitle", "magnets", "playable"}

# TOP250 年份下拉的起始年（对齐官方 UI 的常量 Bd=2008，该年之前无榜单数据）
TOP_YEAR_MIN = 2008

_LIST_TTL = 5 * 60
_list_cache: dict[str, tuple[float, Any]] = {}


def _cached_list(key: str, fetch: Any) -> Any:
    """榜单/列表类接口共享 5 分钟缓存；接口抖动时兜底旧数据。"""
    cached = _list_cache.get(key)
    now = time.time()
    if cached and now - cached[0] < _LIST_TTL:
        return cached[1]
    try:
        value = fetch()
    except AvdbError:
        if cached:
            return cached[1]
        raise
    _list_cache[key] = (now, value)
    return value


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
        "hasCnsub": bool(raw.get("has_cnsub") or raw.get("hasCnsub")),
    }


def _movie_rows(data: Any) -> list[dict[str, Any]]:
    rows = data.get("movies") if isinstance(data, dict) else data
    return [
        _normalize_movie(r)
        for r in (rows or [])
        if isinstance(r, dict) and _s(r, "id")
    ]


@router.get("/rank")
def makers_rank(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
    period: str = Query("daily", description="daily / weekly / monthly"),
) -> dict[str, Any]:
    """AVDB 排行榜（榜单接口直连，带 5 分钟缓存）。"""
    cat = category if category in CATEGORIES else "0"
    per = period if period in PERIODS else "daily"
    if cat not in RANK_CATEGORIES:
        # 动漫（4）在 AVDB 无独立榜单，返回空并标记不支持
        return {
            "category": cat,
            "categoryLabel": CATEGORIES[cat],
            "period": per,
            "periodLabel": PERIODS[per],
            "supported": False,
            "items": [],
        }
    items = _cached_list(
        f"rank-{cat}-{per}",
        lambda: _movie_rows(
            request_json("/api/v1/javdb/rankings", {"type": cat, "period": per})
        ),
    )
    return {
        "category": cat,
        "categoryLabel": CATEGORIES[cat],
        "period": per,
        "periodLabel": PERIODS[per],
        "supported": True,
        "items": items,
    }


@router.get("/playback")
def makers_playback(
    period: str = Query("daily", description="daily / weekly / monthly"),
    filter_by: str = Query("all", description="all 热播 / high_score 热门"),
) -> dict[str, Any]:
    """可播放榜（``rankings/playback``，该接口不区分内容类别）。

    ``filter_by=all`` 为官方「热播」榜，``filter_by=high_score`` 为官方「热门」榜
    （同一接口的高分重排版，交集约 2/3，排序不同）。
    """
    per = period if period in PERIODS else "daily"
    flt = filter_by if filter_by in PLAYBACK_FILTERS else "all"
    items = _cached_list(
        f"playback-{per}-{flt}",
        lambda: _movie_rows(
            request_json(
                "/api/v1/javdb/rankings/playback",
                {"period": per, "filter_by": flt},
            )
        ),
    )
    return {
        "period": per,
        "periodLabel": PERIODS[per],
        "filterBy": flt,
        "filterLabel": PLAYBACK_FILTERS[flt],
        "items": items,
    }


@router.get("/latest")
def makers_latest(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=MOVIE_LIMIT_MAX),
    sort_by: str = Query("update", description="update 更新 / release 发行"),
    filter_by: str = Query("all", description="all 全部 / magnets 含磁链 / subtitle 含字幕"),
) -> dict[str, Any]:
    """最新影片（``movies/latest``）。"""
    cat = category if category in CATEGORIES else "0"
    sort = "release" if sort_by == "release" else "update"
    flt = filter_by if filter_by in LATEST_FILTERS else "all"
    items = _cached_list(
        f"latest-{cat}-{page}-{limit}-{sort}-{flt}",
        lambda: _movie_rows(
            request_json(
                "/api/v1/javdb/movies/latest",
                {
                    "type": cat,
                    "page": page,
                    "limit": limit,
                    "sort_by": sort,
                    "filter_by": flt,
                },
            )
        ),
    )
    return {
        "category": cat,
        "categoryLabel": CATEGORIES[cat],
        "page": page,
        "sortBy": sort,
        "filterBy": flt,
        "filterLabel": LATEST_FILTERS[flt],
        "items": items,
        "hasMore": len(items) >= limit,
    }


@router.get("/top")
def makers_top(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2"),
    page: int = Query(1, ge=1, le=10),
    limit: int = Query(50, ge=1, le=50),
    year: str = Query("", max_length=4, description="按年份筛选（2008+），留空为按类别榜"),
) -> dict[str, Any]:
    """热门 Top 排行（``movies/top``，站内评分 Top250，可翻页）。

    ``year`` 非空时走 AVDB 的年份榜：``type="year"`` + ``type_value=YYYY``，
    此时类别维度被年份覆盖，且必须用 ``page`` 翻页（``start_rank`` 超过 250 会回绕）。
    """
    cat = category if category in CATEGORIES else "0"
    yr = year.strip()
    if yr.isdigit() and len(yr) == 4 and int(yr) >= TOP_YEAR_MIN:
        items = _cached_list(
            f"top-year-{yr}-{page}-{limit}",
            lambda: _movie_rows(
                request_json(
                    "/api/v1/javdb/movies/top",
                    {"type": "year", "type_value": yr, "page": page, "limit": limit},
                )
            ),
        )
        has_more = False
        if len(items) >= limit:
            nxt = _cached_list(
                f"top-year-{yr}-{page + 1}-{limit}",
                lambda: _movie_rows(
                    request_json(
                        "/api/v1/javdb/movies/top",
                        {"type": "year", "type_value": yr, "page": page + 1, "limit": limit},
                    )
                ),
            )
            has_more = bool(nxt)
        return {
            "category": cat,
            "categoryLabel": CATEGORIES[cat],
            "page": page,
            "year": yr,
            "startRank": (page - 1) * limit + 1,
            "supported": True,
            "items": items,
            "hasMore": has_more,
        }
    if cat not in RANK_CATEGORIES:
        return {
            "category": cat,
            "categoryLabel": CATEGORIES[cat],
            "page": page,
            "year": "",
            "startRank": 0,
            "supported": False,
            "items": [],
            "hasMore": False,
        }
    start_rank = (page - 1) * limit + 1
    items = _cached_list(
        f"top-{cat}-{start_rank}-{limit}",
        lambda: _movie_rows(
            request_json(
                "/api/v1/javdb/movies/top",
                {"type": cat, "start_rank": start_rank, "page": 1, "limit": limit},
            )
        ),
    )
    return {
        "category": cat,
        "categoryLabel": CATEGORIES[cat],
        "page": page,
        "year": "",
        "startRank": start_rank,
        "supported": True,
        "items": items,
        "hasMore": start_rank + len(items) <= 250,
    }


@router.get("/years")
def makers_years() -> dict[str, Any]:
    """TOP250 年份下拉选项（取自 ``javdb/tags`` 的年份分组，仅保留有榜单数据的年份）。"""
    data = _cached_list(
        "years",
        lambda: request_json("/api/v1/javdb/tags", {"type": "0", "include_main": "true"}),
    )
    cats_raw = data.get("categories") if isinstance(data, dict) else None
    years: list[int] = []
    for c in cats_raw or []:
        if not isinstance(c, dict) or _s(c, "id") != "year":
            continue
        for t in c.get("tags") or []:
            if not isinstance(t, dict):
                continue
            val = _s(t, "name") or _s(t, "id")
            if val.isdigit() and int(val) >= TOP_YEAR_MIN:
                years.append(int(val))
    years = sorted(set(years), reverse=True)
    return {"years": [str(y) for y in years]}


@router.get("/recommend")
def makers_recommend() -> dict[str, Any]:
    """编辑推荐（``movies/recommend``）。"""
    items = _cached_list(
        "recommend",
        lambda: _movie_rows(request_json("/api/v1/javdb/movies/recommend")),
    )
    return {"items": items}


@router.get("/hot-reviews")
def makers_hot_reviews(
    period: str = Query("weekly", description="daily / weekly / monthly"),
) -> dict[str, Any]:
    """热评（``reviews/hotly``），带影片快照。"""
    per = period if period in PERIODS else "weekly"
    data = _cached_list(
        f"hot-reviews-{per}",
        lambda: request_json("/api/v1/javdb/reviews/hotly", {"period": per}),
    )
    rows = data.get("reviews") if isinstance(data, dict) else None
    items: list[dict[str, Any]] = []
    for r in rows or []:
        if not isinstance(r, dict):
            continue
        movie = r.get("movie")
        if not isinstance(movie, dict) or not _s(movie, "id"):
            continue
        items.append(
            {
                "id": _s(r, "id") or str(r.get("id") or ""),
                "username": _s(r, "username"),
                "content": _s(r, "content"),
                "score": _int(r.get("score")),
                "likesCount": _int(r.get("likes_count")),
                "createdAt": _s(r, "created_at") or None,
                "movie": {
                    "id": _s(movie, "id"),
                    "number": _s(movie, "number"),
                    "title": _s(movie, "title"),
                    "score": movie.get("score"),
                    "thumbUrl": _s(movie, "thumb_url", "thumbUrl") or None,
                    "releaseDate": _s(movie, "release_date") or None,
                },
            }
        )
    return {"period": per, "periodLabel": PERIODS[per], "items": items}


@router.get("/reviews")
def makers_reviews(
    movie_id: str = Query(..., min_length=1),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(20, ge=1, le=100),
) -> dict[str, Any]:
    """某影片的评论（``movies/{id}/reviews``）。"""
    mid = movie_id.strip()
    try:
        data = request_json(
            f"/api/v1/javdb/movies/{mid}/reviews", {"page": page, "limit": limit}
        )
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    rows = data.get("reviews") if isinstance(data, dict) else None
    items = [
        {
            "id": _s(r, "id") or str(r.get("id") or ""),
            "username": _s(r, "username"),
            "content": _s(r, "content"),
            "score": _int(r.get("score")),
            "likesCount": _int(r.get("likes_count")),
            "createdAt": _s(r, "created_at") or None,
            "statusTitle": _s(r, "status_title") or None,
        }
        for r in (rows or [])
        if isinstance(r, dict)
    ]
    return {"movieId": mid, "page": page, "items": items, "hasMore": len(items) >= limit}


@router.get("/actors")
def makers_actors(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美"),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=100),
) -> dict[str, Any]:
    """演员列表（``javdb/actors``；type=1/2 有各自演员，type=3/4 与 0 相同）。"""
    cat = category if category in CATEGORIES else "0"
    data = _cached_list(
        f"actors-{cat}-{page}-{limit}",
        lambda: request_json(
            "/api/v1/javdb/actors", {"type": cat, "page": page, "limit": limit}
        ),
    )
    rows = data.get("actors") if isinstance(data, dict) else None
    items = [
        {
            "id": _s(a, "id"),
            "name": _s(a, "name"),
            "avatarUrl": _s(a, "avatar_url", "avatarUrl") or None,
            "videosCount": _int(a.get("videos_count")),
        }
        for a in (rows or [])
        if isinstance(a, dict) and _s(a, "id") and _s(a, "name")
    ]
    return {
        "category": cat,
        "page": page,
        "items": items,
        "hasMore": len(items) >= limit,
    }


@router.get("/tags")
def makers_tags(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
) -> dict[str, Any]:
    """分类标签（``javdb/tags``，按类别分组；含「基本」组）。"""
    cat = category if category in CATEGORIES else "0"
    data = _cached_list(
        f"tags-{cat}",
        lambda: request_json("/api/v1/javdb/tags", {"type": cat, "include_main": "true"}),
    )
    cats_raw = data.get("categories") if isinstance(data, dict) else None
    categories = [
        {
            "id": _s(c, "id"),
            "name": _s(c, "name"),
            "tags": [
                {"id": _s(t, "id"), "name": _s(t, "name")}
                for t in (c.get("tags") or [])
                if isinstance(t, dict) and _s(t, "id") and _s(t, "name")
            ],
        }
        for c in (cats_raw or [])
        if isinstance(c, dict) and _s(c, "type") == cat and _s(c, "id") and _s(c, "name")
    ]
    return {"category": cat, "categoryLabel": CATEGORIES[cat], "categories": categories}


@router.get("/browse")
def makers_browse(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
    group: str = Query("", max_length=40, description="标签组 id（main/year/month/duration/...）"),
    tag_id: str = Query("", max_length=120),
    tag_ids: str = Query("", max_length=400, description="逗号分隔多选标签"),
    actor_id: str = Query("", max_length=64),
    year: str = Query("", max_length=4),
    maker_id: str = Query("", max_length=64, description="片商 id"),
    director_id: str = Query("", max_length=64, description="导演 id"),
    list_id: str = Query("", max_length=64, description="片单 id"),
    publisher_id: str = Query("", max_length=64, description="发行商 id"),
    series_id: str = Query("", max_length=64, description="系列 id（需配合 series_type）"),
    series_type: str = Query("", max_length=8, description="系列类型（0 系列 / 1 系列作品等）"),
    sort_by: str = Query("", max_length=16, description="release 发行日期"),
    order_by: str = Query("", max_length=8, description="asc / desc"),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=MOVIE_LIMIT_MAX),
) -> dict[str, Any]:
    """按标签/年份/月份/时长/演员/片商/导演/片单/系列浏览影片（``movies/tags``）。

    ``group`` 决定标签走哪个 AVDB 参数：main→main_filter、year→year、
    month→month、duration→duration，其余内容标签组走 tag_id。
    """
    cat = category if category in CATEGORIES else "0"
    params: dict[str, Any] = {"type": cat, "page": page, "limit": limit}
    gid = group.strip()
    param = TAG_GROUP_PARAM.get(gid, "tag_id")
    multi = [t.strip() for t in tag_ids.split(",") if t.strip()]
    if multi and param == "tag_id":
        params["tag_ids"] = ",".join(multi)
    elif tag_id.strip():
        params[param] = tag_id.strip()
    if year.strip():
        params["year"] = year.strip()
    if actor_id.strip():
        params["actor_id"] = actor_id.strip()
    # 维度筛选：片商 / 导演 / 片单 / 发行商 / 系列
    for key, val in (
        ("maker_id", maker_id),
        ("director_id", director_id),
        ("list_id", list_id),
        ("publisher_id", publisher_id),
    ):
        if val.strip():
            params[key] = val.strip()
    if series_id.strip():
        params["series_id"] = series_id.strip()
        if series_type.strip():
            params["series_type"] = series_type.strip()
    if sort_by.strip() == "release":
        params["sort_by"] = "release"
    if order_by.strip() in ("asc", "desc"):
        params["order_by"] = order_by.strip()
    items = _cached_list(
        "-".join(
            [
                "browse",
                cat,
                gid,
                tag_id.strip(),
                tag_ids.strip(),
                actor_id.strip(),
                year.strip(),
                maker_id.strip(),
                director_id.strip(),
                list_id.strip(),
                publisher_id.strip(),
                series_id.strip(),
                series_type.strip(),
                sort_by.strip(),
                order_by.strip(),
                str(page),
                str(limit),
            ]
        ),
        lambda: _movie_rows(
            request_json("/api/v1/javdb/movies/tags", params)
        ),
    )
    return {
        "category": cat,
        "group": gid,
        "tagId": tag_id.strip(),
        "page": page,
        "items": items,
        "hasMore": len(items) >= limit,
    }


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


@router.get("/image")
def makers_image(
    url: str = Query(..., min_length=8, max_length=1600),
    w: int = Query(0, ge=0, le=2000),
) -> Response:
    """AVDB 图片代理：封面 CDN 是加扰字节流，须经 AVDB ``img-proxy`` 解码。"""
    raw = request_bytes("/api/v1/img-proxy/", {"url": url, "w": w or None})
    if not raw:
        raise HTTPException(status_code=502, detail="图片拉取失败")
    media_type = _sniff_image(raw)
    return Response(
        content=raw,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )


# 站内搜索类型 → AVDB 返回体里的字段名
SEARCH_TYPES: dict[str, str] = {
    "maker": "makers",
    "actor": "actors",
    "list": "lists",
    "series": "series",
    "director": "directors",
    "code": "codes",
}


@router.get("/search")
def makers_search(
    q: str = Query(..., min_length=1),
    search_type: str = Query("maker", alias="type"),
) -> dict[str, Any]:
    """AVDB 站内搜索：片商 / 演员 / 片单 / 系列 / 导演 / 番号前缀。"""
    kind = search_type.strip().lower()
    if kind not in SEARCH_TYPES:
        kind = "maker"
    try:
        data = request_json("/api/v1/javdb/search", {"q": q.strip(), "type": kind})
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    rows = data.get(SEARCH_TYPES[kind]) if isinstance(data, dict) else None
    items: list[dict[str, Any]] = []
    for r in rows or []:
        if not isinstance(r, dict):
            continue
        rid = _s(r, "id")
        name = _s(r, "name")
        if not rid or not name:
            continue
        count = _int(r.get("videos_count"))
        if not count:
            count = _int(r.get("movies_count"))
        item: dict[str, Any] = {"id": rid, "name": name, "kind": kind, "count": count}
        if kind == "actor":
            item["avatarUrl"] = _s(r, "avatar_url")
        items.append(item)
    return {"query": q.strip(), "type": kind, "items": items}


@router.get("/movie-search")
def makers_movie_search(
    q: str = Query(..., min_length=1),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=MOVIE_LIMIT_MAX),
    cnsub: bool = Query(False, description="只看有中文字幕（等价 filter_by=subtitle）"),
    filter_by: str = Query(
        "all", max_length=16, description="all 全部 / subtitle 中文字幕 / magnets 有磁力 / playable 可播放"
    ),
    movie_type: str = Query("", max_length=8, description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
    sort_by: str = Query("", max_length=16, description="release / update / relevance"),
) -> dict[str, Any]:
    """影片/番号搜索（``search?type=movie``）。"""
    params: dict[str, Any] = {
        "q": q.strip(),
        "type": "movie",
        "page": page,
        "limit": limit,
    }
    flt = filter_by.strip()
    if flt not in MOVIE_SEARCH_FILTERS:
        flt = "subtitle" if cnsub else "all"
    if flt != "all":
        params["movie_filter_by"] = flt
    if movie_type.strip() in CATEGORIES:
        params["movie_type"] = movie_type.strip()
    if sort_by.strip() in ("release", "update", "relevance"):
        params["movie_sort_by"] = sort_by.strip()
    try:
        data = request_json("/api/v1/javdb/search", params)
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    rows = data.get("movies") if isinstance(data, dict) else None
    raw = [r for r in (rows or []) if isinstance(r, dict)]
    return {
        "query": q.strip(),
        "page": page,
        "items": [_normalize_movie(r) for r in raw],
        "hasMore": len(raw) >= limit,
    }


_WORD_RE = re.compile(r"[0-9a-z\u3040-\u30ff\u4e00-\u9fff]+")


def _words(text: str) -> list[str]:
    return _WORD_RE.findall(str(text).lower())


@lru_cache(maxsize=256)
def _resolve_maker_id(name: str) -> str:
    """把片商名解析成 AVDB maker id（失败返回空串）。"""
    candidates = [name.strip()]
    for sep in ("/", "&", "（", "(", "·"):
        if sep in name:
            head = name.split(sep)[0].strip()
            if head and head not in candidates:
                candidates.append(head)
    best_id = ""
    best_score = 0
    for cand in candidates:
        words = set(_words(cand))
        if not words:
            continue
        try:
            data = request_json(
                "/api/v1/javdb/search", {"q": cand, "type": "maker"}
            )
        except AvdbError:
            continue
        rows = data.get("makers") if isinstance(data, dict) else None
        for row in rows or []:
            if not isinstance(row, dict):
                continue
            maker_name = _s(row, "name")
            maker_id = _s(row, "id")
            if not maker_id or not maker_name:
                continue
            row_words = set(_words(maker_name))
            if words == row_words:
                score = 3
            elif words <= row_words:
                score = 2
            else:
                continue
            # 同分取影片数量更多的条目
            score = score * 10_000_000 + min(
                _int(row.get("videos_count")), 9_999_999
            )
            if score > best_score:
                best_score = score
                best_id = maker_id
    return best_id


@router.get("/movies")
def makers_movies(
    name: str = Query(..., min_length=1),
    page: int = Query(1, ge=1, le=500),
    limit: int = Query(24, ge=1, le=MOVIE_LIMIT_MAX),
) -> dict[str, Any]:
    """某片商的影片列表。

    解析到 maker id 时走 ``movies/tags?maker_id=``（完整片库，按发布时间倒序）；
    解析不到时退回 ``search?type=movie``（片商名）。
    """
    maker_id = _resolve_maker_id(name)
    try:
        if maker_id:
            data = request_json(
                "/api/v1/javdb/movies/tags",
                {
                    "maker_id": maker_id,
                    "sort_by": "release",
                    "order_by": "desc",
                    "page": page,
                    "limit": limit,
                },
            )
        else:
            data = request_json(
                "/api/v1/javdb/search",
                {"q": name.strip(), "type": "movie", "page": page, "limit": limit},
            )
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    rows = (
        data.get("movies") or data.get("items")
        if isinstance(data, dict)
        else data
    )
    raw = [r for r in (rows or []) if isinstance(r, dict)]
    items = [_normalize_movie(r) for r in raw]
    return {
        "maker": name.strip(),
        "makerId": maker_id or None,
        "page": page,
        "items": items,
        "hasMore": len(raw) >= limit,
    }


_SHARE_URL_RE = re.compile(r"https?://\S+")


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
        "hasCnsub": bool(raw.get("cnsub")),
        "hd": bool(raw.get("hd")),
    }


# --------------------------------------------------------------------------
# AVDB 自有种子库（``articles/torrents``）
#
# 上游只支持 keyword 一个参数（limit / page 实测无效），返回的是前缀匹配
# 命中的全量记录，因此分页与番号精确匹配都在本地做。
# --------------------------------------------------------------------------

TORRENT_LIMIT_MAX = 48
_TORRENT_RAW_MAX = 2000


def _norm_torrent(raw: dict[str, Any]) -> dict[str, Any]:
    size_bytes = _int(raw.get("size_bytes"))
    size_mb = raw.get("size_mb")
    return {
        "id": str(raw.get("id") or ""),
        "emby": _int(raw.get("emby")),
        "number": _s(raw, "number"),
        "site": _s(raw, "site") or None,
        "website": _s(raw, "website") or None,
        "section": _s(raw, "section") or None,
        "category": _s(raw, "category") or None,
        "title": _s(raw, "title"),
        "sizeMb": float(size_mb) if isinstance(size_mb, (int, float)) else 0.0,
        "sizeBytes": size_bytes,
        "postTime": _s(raw, "post_time") or None,
        "seeders": _int(raw.get("seeders")),
        "downloadUrl": _s(raw, "download_url"),
        "previewImage": _s(raw, "preview_image") or None,
        "free": bool(raw.get("free")),
        "tags": [str(t) for t in (raw.get("tags") or []) if t],
        "chinese": bool(raw.get("chinese")),
        "uncensored": bool(raw.get("uncensored")),
        "uc": bool(raw.get("uc")),
        "hd": bool(raw.get("hd")),
        "uhd": bool(raw.get("uhd")),
        "mosaic": bool(raw.get("mosaic")),
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


def _fetch_torrents(keyword: str) -> list[dict[str, Any]]:
    data = request_json(TORRENTS_PATH, {"keyword": keyword})
    rows = data if isinstance(data, list) else []
    return [r for r in rows if isinstance(r, dict)][:_TORRENT_RAW_MAX]


@router.get("/torrents")
def makers_torrents(
    keyword: str = Query(..., min_length=1, max_length=120),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=TORRENT_LIMIT_MAX),
    exact: bool = Query(False, description="仅保留番号完全一致的记录"),
) -> dict[str, Any]:
    """AVDB 自有种子库检索（番号 / 片商名 / 标题关键词）。"""
    kw = keyword.strip()
    if not kw:
        raise HTTPException(status_code=400, detail="缺少关键词")
    try:
        raw = _cached_list(f"torrents-{kw.lower()}", lambda: _fetch_torrents(kw))
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e

    items = _dedupe_torrents([_norm_torrent(r) for r in raw])
    if exact:
        target = kw.upper()
        items = [t for t in items if target in _torrent_numbers(t["number"])]
    items.sort(key=lambda t: (t["postTime"] or "", t["seeders"]), reverse=True)

    total = len(items)
    start = (page - 1) * limit
    return {
        "keyword": kw,
        "exact": exact,
        "page": page,
        "total": total,
        "items": items[start : start + limit],
        "hasMore": start + limit < total,
    }


@router.get("/movie/{movie_id}")
def makers_movie(movie_id: str) -> dict[str, Any]:
    """影片详情 + 磁力列表 + 评论资源 + 相关影片。"""
    mid = movie_id.strip()
    if not mid:
        raise HTTPException(status_code=400, detail="缺少影片 ID")
    try:
        detail = request_json(f"/api/v1/javdb/movies/{mid}")
        magnets_data = request_json(f"/api/v1/javdb/movies/{mid}/magnets")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e

    # 评论区共享资源（ed2k 等）：失败不影响主流程
    try:
        res_data = request_json(f"/api/v1/javdb/movies/{mid}/comment-resources")
    except AvdbError:
        res_data = None
    res_raw = (
        res_data.get("resources")
        if isinstance(res_data, dict)
        else (res_data or [])
    )
    resources = [
        {
            "id": str(r.get("id") or ""),
            "type": _s(r, "resource_type", "type") or "ed2k",
            "url": _s(r, "resource_url", "url"),
            "name": _s(r, "name"),
            "sizeBytes": _int(r.get("size_bytes")),
            "hash": _s(r, "hash") or None,
            "sourceLabel": _s(r, "source_label") or None,
            "hd": bool(r.get("hd")),
            "createdAt": _s(r, "comment_date") or None,
        }
        for r in (res_raw or [])
        if isinstance(r, dict) and _s(r, "resource_url", "url")
    ]

    data = detail if isinstance(detail, dict) else {}
    movie = data.get("movie") if isinstance(data.get("movie"), dict) else data
    base = _normalize_movie(movie if isinstance(movie, dict) else {})

    share_info = _s(data, "share_info", "shareInfo")
    share_url = ""
    if share_info:
        m = _SHARE_URL_RE.search(share_info)
        share_url = m.group(0) if m else ""

    makers = data.get("makers") or data.get("maker")
    if isinstance(makers, dict):
        makers = [makers]
    maker_list = [
        {"id": _s(m, "id"), "name": _s(m, "name")}
        for m in (makers or [])
        if isinstance(m, dict) and _s(m, "name")
    ]
    maker_name = _s(data, "maker_name", "makerName") or _s(movie, "maker_name")
    if not maker_list and maker_name:
        maker_list = [{"id": "", "name": maker_name}]

    actors = [p for p in (_norm_person(a) for a in (data.get("actors") or movie.get("actors") or [])) if p]
    tags = [t for t in (_norm_tag(t) for t in (data.get("tags") or movie.get("tags") or [])) if t]

    if isinstance(magnets_data, dict):
        magnets_raw = magnets_data.get("magnets") or magnets_data.get("items") or []
    else:
        magnets_raw = magnets_data or []
    magnets = [
        _norm_magnet(m)
        for m in magnets_raw
        if isinstance(m, dict) and _s(m, "magnet_url", "magnetUrl", "url", "link")
    ]

    previews_raw = (
        movie.get("preview_images")
        if isinstance(movie, dict)
        else None
    ) or data.get("preview_images")
    previews = [
        {
            "thumb": _s(p, "thumb_url", "thumbUrl"),
            "large": _s(p, "large_url", "largeUrl") or _s(p, "thumb_url", "thumbUrl"),
        }
        for p in (previews_raw or [])
        if isinstance(p, dict) and (_s(p, "thumb_url") or _s(p, "large_url"))
    ]

    relative_raw = (
        movie.get("relative_movies")
        if isinstance(movie, dict)
        else None
    ) or data.get("relative_movies") or []
    relative = [
        _normalize_movie(r)
        for r in (relative_raw or [])
        if isinstance(r, dict) and _s(r, "id")
    ]

    # 演员在该片中的其它参演作品（``actor_movies``）
    actor_movies = [
        {
            "id": _s(a, "id"),
            "number": _s(a, "number"),
            "title": _s(a, "title"),
            "thumbUrl": _s(a, "thumb_url", "thumbUrl") or None,
            "coverUrl": _s(a, "cover_url", "coverUrl") or None,
        }
        for a in (data.get("actor_movies") or movie.get("actor_movies") or [])
        if isinstance(a, dict) and _s(a, "id")
    ]

    # 该片的榜单排名（``top_rankings``）
    top_rankings = [
        {
            "type": _s(t, "type"),
            "period": _s(t, "period"),
            "rank": _int(t.get("rank")),
            "category": _s(t, "category") or None,
        }
        for t in (data.get("top_rankings") or movie.get("top_rankings") or [])
        if isinstance(t, dict)
    ]

    play_sources = data.get("play_sources") or movie.get("play_sources") or []

    # AVDB 自有种子库：按影片番号精确匹配（失败不影响主流程）
    avdb_torrents: list[dict[str, Any]] = []
    number = base["number"]
    if number:
        try:
            raw_torrents = _cached_list(
                f"torrents-{number.lower()}",
                lambda: _fetch_torrents(number),
            )
            target = number.upper()
            for row in raw_torrents:
                item = _norm_torrent(row)
                if target in _torrent_numbers(item["number"]):
                    avdb_torrents.append(item)
            avdb_torrents = _dedupe_torrents(avdb_torrents)
            avdb_torrents.sort(
                key=lambda t: (t["postTime"] or "", t["seeders"]), reverse=True
            )
        except AvdbError:
            avdb_torrents = []

    return {
        "id": base["id"] or mid,
        "number": base["number"],
        "title": base["title"],
        "summary": _s(movie, "summary", "description", "plot") or None,
        "coverUrl": base["coverUrl"],
        "thumbUrl": base["thumbUrl"],
        "previewUrl": base["previewUrl"],
        "releaseDate": base["releaseDate"],
        "duration": base["duration"],
        "score": movie.get("score") if isinstance(movie, dict) else None,
        "reviewsCount": _int(movie.get("reviews_count")) if isinstance(movie, dict) else 0,
        "commentsCount": _int(movie.get("comments_count")) if isinstance(movie, dict) else 0,
        "wantWatchCount": _int(movie.get("want_watch_count")) if isinstance(movie, dict) else 0,
        "watchedCount": _int(movie.get("watched_count")) if isinstance(movie, dict) else 0,
        "magnetsCount": base["magnetsCount"] or len(magnets),
        "hasCnsub": base["hasCnsub"],
        "makers": maker_list,
        "makerId": _s(data, "maker_id", "makerId") or _s(movie, "maker_id") or None,
        "publisher": _s(movie, "publisher_name", "publisher") or None,
        "publisherId": _s(data, "publisher_id", "publisherId") or _s(movie, "publisher_id") or None,
        "director": _s(movie, "director_name", "director") or None,
        "directorId": _s(data, "director_id", "directorId") or _s(movie, "director_id") or None,
        "series": _s(movie, "series_name", "series") or None,
        "seriesId": _s(data, "series_id", "seriesId") or _s(movie, "series_id") or None,
        "seriesType": _s(data, "series_type", "seriesType") or _s(movie, "series_type") or None,
        "actors": actors,
        "tags": tags,
        "shareUrl": share_url or None,
        "magnets": magnets,
        "resources": resources,
        "previews": previews,
        "relativeMovies": relative,
        "actorMovies": actor_movies,
        "topRankings": top_rankings,
        "hasPreviewVideo": bool(data.get("has_preview_video") or movie.get("has_preview_video")),
        "previewVideoUrl": (
            _s(data, "preview_video_url", "previewVideoUrl")
            or _s(movie, "preview_video_url")
            or None
        ),
        "canPlay": bool(data.get("can_play") or movie.get("can_play")),
        "playSources": play_sources if isinstance(play_sources, list) else [],
        "hasLocalSubtitle": bool(
            data.get("has_local_subtitle") or movie.get("has_local_subtitle")
        ),
        "avdbTorrents": avdb_torrents,
    }


# --------------------------------------------------------------------------
# 实体详情：片商 / 导演 / 系列（AVDB 三者共用 id 命名空间）
# --------------------------------------------------------------------------

ENTITY_KINDS: dict[str, str] = {
    "maker": "makers",
    "director": "directors",
    "series": "series",
}


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


@router.get("/entity")
def makers_entity(
    kind: str = Query("maker", description="maker / director / series"),
    id: str = Query(..., min_length=1, max_length=64),
) -> dict[str, Any]:
    """片商 / 导演 / 系列详情（``javdb/makers|directors|series/{id}``）。"""
    seg = ENTITY_KINDS.get(kind.strip())
    if not seg:
        raise HTTPException(status_code=400, detail="不支持的实体类型")
    eid = id.strip()
    try:
        data = request_json(f"/api/v1/javdb/{seg}/{eid}")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    if not isinstance(data, dict):
        raise HTTPException(status_code=404, detail="实体不存在")
    entity = _norm_entity(data.get(kind.strip()))
    if not entity:
        raise HTTPException(status_code=404, detail="实体不存在")
    share_info = _s(data, "share_info", "shareInfo")
    m = _SHARE_URL_RE.search(share_info)
    return {
        "kind": kind.strip(),
        "id": entity["id"] or eid,
        "type": entity["type"],
        "name": entity["name"],
        "videosCount": entity["videosCount"],
        "shareUrl": (m.group(0) if m else None),
        "hasCollected": bool(data.get("has_collected")),
    }


# --------------------------------------------------------------------------
# 演员详情 / 推荐演员
# --------------------------------------------------------------------------


@router.get("/actor-detail")
def makers_actor_detail(
    id: str = Query(..., min_length=1, max_length=64),
) -> dict[str, Any]:
    """演员详情（``javdb/actors/{id}``）：资料 + 标签组。"""
    aid = id.strip()
    try:
        data = request_json(f"/api/v1/javdb/actors/{aid}")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    if not isinstance(data, dict):
        raise HTTPException(status_code=404, detail="演员不存在")
    actor = data.get("actor")
    if not isinstance(actor, dict):
        raise HTTPException(status_code=404, detail="演员不存在")
    share_info = _s(data, "share_info", "shareInfo")
    m = _SHARE_URL_RE.search(share_info)
    return {
        "id": _s(actor, "id") or aid,
        "type": _int(actor.get("type"), -1),
        "name": _s(actor, "name"),
        "nameZht": _s(actor, "name_zht") or None,
        "otherName": _s(actor, "other_name") or None,
        "avatarUrl": _s(actor, "avatar_url") or None,
        "birthday": _s(actor, "birthday") or None,
        "age": _int(actor.get("age")),
        "constellation": _s(actor, "cons") or None,
        "bloodType": _s(actor, "blood_type") or None,
        "height": _int(actor.get("height")),
        "bust": _int(actor.get("bust")),
        "cup": _s(actor, "cup") or None,
        "waist": _int(actor.get("waist")),
        "hips": _int(actor.get("hips")),
        "birthplace": _s(actor, "birthplace") or None,
        "twitterId": _s(actor, "twitter_id") or None,
        "instagramId": _s(actor, "instagram_id") or None,
        "videosCount": _int(actor.get("videos_count")),
        "shareUrl": (m.group(0) if m else None),
        "tags": [
            {"id": _s(t, "id"), "name": _s(t, "name"), "videosCount": _int(t.get("videos_count"))}
            for t in (data.get("tags") or [])
            if isinstance(t, dict) and _s(t, "id") and _s(t, "name")
        ],
        "filterTags": [
            {"id": _s(t, "id"), "name": _s(t, "name")}
            for t in (data.get("filter_tags") or [])
            if isinstance(t, dict) and _s(t, "id") and _s(t, "name")
        ],
    }


@router.get("/actor-recommend")
def makers_actor_recommend() -> dict[str, Any]:
    """推荐演员（``javdb/actors/recommend``）：新晋 / 月榜 / 推荐三组。"""
    try:
        data = request_json("/api/v1/javdb/actors/recommend")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    groups = data if isinstance(data, dict) else {}

    def _norm(rows: Any) -> list[dict[str, Any]]:
        return [
            {
                "id": _s(a, "id"),
                "name": _s(a, "name"),
                "otherName": _s(a, "other_name") or None,
                "avatarUrl": _s(a, "avatar_url") or None,
                "videosCount": _int(a.get("videos_count")),
            }
            for a in (rows or [])
            if isinstance(a, dict) and _s(a, "id") and _s(a, "name")
        ]

    return {
        "newActors": _norm(groups.get("new_actors")),
        "monthlyActors": _norm(groups.get("monthly_actors")),
        "recommendActors": _norm(groups.get("recommend_actors")),
    }


# --------------------------------------------------------------------------
# 片单
# --------------------------------------------------------------------------


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
        "isDefault": bool(raw.get("is_default")),
        "shareUrl": (m.group(0) if m else None),
        "createdAt": _s(raw, "created_at") or None,
    }


@router.get("/lists/related")
def makers_related_lists(
    movie_id: str = Query(..., min_length=1),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(10, ge=1, le=50),
) -> dict[str, Any]:
    """某影片的相关片单（``javdb/lists/related``）。"""
    mid = movie_id.strip()
    try:
        data = request_json(
            f"/api/v1/javdb/lists/related",
            {"movie_id": mid, "page": page, "limit": limit},
        )
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    rows = data.get("lists") if isinstance(data, dict) else None
    items = [x for x in (_norm_list(r) for r in (rows or [])) if x]
    return {"movieId": mid, "page": page, "items": items, "hasMore": len(items) >= limit}


@router.get("/list-detail")
def makers_list_detail(
    id: str = Query(..., min_length=1, max_length=64),
) -> dict[str, Any]:
    """片单详情（``javdb/lists/{id}``）。"""
    lid = id.strip()
    try:
        data = request_json(f"/api/v1/javdb/lists/{lid}")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    if not isinstance(data, dict):
        raise HTTPException(status_code=404, detail="片单不存在")
    detail = _norm_list(data.get("list"))
    if not detail:
        raise HTTPException(status_code=404, detail="片单不存在")
    detail["isCreator"] = bool(data.get("is_creator"))
    detail["hasCollected"] = bool(data.get("has_collected"))
    return detail


# --------------------------------------------------------------------------
# 最近浏览 / 账号
# --------------------------------------------------------------------------


@router.get("/recent-viewed")
def makers_recent_viewed() -> dict[str, Any]:
    """最近浏览（``javdb/users/recent_viewed``）。"""
    try:
        data = request_json("/api/v1/javdb/users/recent_viewed")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    rows = data.get("movies") if isinstance(data, dict) else None
    items = [
        _normalize_movie(r)
        for r in (rows or [])
        if isinstance(r, dict) and _s(r, "id")
    ]
    return {"items": items}


@router.get("/account")
def makers_account() -> dict[str, Any]:
    """AVDB 账号状态（``javdb/account``）：是否已登录 / 是否 VIP。"""
    try:
        data = request_json("/api/v1/javdb/account")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    if not isinstance(data, dict):
        return {"loggedIn": False, "username": None, "isVip": False}
    return {
        "loggedIn": bool(data.get("logged_in")),
        "username": _s(data, "username") or None,
        "isVip": bool(data.get("is_vip")),
    }
