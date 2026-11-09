"""片商页：AVDB 查询、数据组装与缓存等非路由逻辑。

路由声明见 ``app.makers.router``。
"""

from __future__ import annotations

import asyncio
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any
from urllib.parse import urlsplit

from fastapi import HTTPException

from app.rexhub.addons_store import streams as addon_streams
from app.rexhub.plugin_framework import dispatcher

from app.makers.normalize import (
    _bool,
    _dedupe_torrents,
    _int,
    _movie_rows,
    _norm_entity,
    _norm_list,
    _norm_magnet,
    _norm_person,
    _norm_tag,
    _norm_torrent,
    _normalize_movie,
    _num,
    _s,
    _share_url,
    _sniff_image,
    _torrent_numbers,
    _words,
)
from app.search.avdb_client import (
    TORRENTS_PATH,
    AvdbError,
    request_bytes,
    request_json,
)

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

# 站内搜索类型 → AVDB 返回体里的字段名
SEARCH_TYPES: dict[str, str] = {
    "maker": "makers",
    "actor": "actors",
    "list": "lists",
    "series": "series",
    "director": "directors",
    "code": "codes",
}

# AVDB 自有种子库（``articles/torrents``）
#
# 上游只支持 keyword 一个参数（limit / page 实测无效），返回的是前缀匹配
# 命中的全量记录，因此分页与番号精确匹配都在本地做。
TORRENT_LIMIT_MAX = 48
_TORRENT_RAW_MAX = 2000

# 实体详情：片商 / 导演 / 系列（AVDB 三者共用 id 命名空间）
ENTITY_KINDS: dict[str, str] = {
    "maker": "makers",
    "director": "directors",
    "series": "series",
}

_LIST_TTL = 5 * 60
_list_cache: dict[str, tuple[float, Any]] = {}


def _cached_list(key: str, fetch: Any) -> Any:
    """榜单/列表类接口共享 5 分钟缓存；接口抖动时兜底旧数据。"""
    now = time.time()
    # 先取出本 key 的旧值再清理过期项，否则过期条目会在兜底前被删掉
    cached = _list_cache.get(key)
    for stale_key, (ts, _value) in list(_list_cache.items()):
        if stale_key != key and now - ts >= _LIST_TTL:
            _list_cache.pop(stale_key, None)
    if cached and now - cached[0] < _LIST_TTL:
        return cached[1]
    try:
        value = fetch()
    except AvdbError:
        if cached:
            return cached[1]
        raise
    if len(_list_cache) >= 256:
        oldest = min(_list_cache, key=lambda k: _list_cache[k][0])
        _list_cache.pop(oldest, None)
    _list_cache[key] = (now, value)
    return value


_maker_id_cache: dict[str, str] = {}
_MAKER_ID_CACHE_MAX = 256


def _resolve_maker_id(name: str) -> str:
    """把片商名解析成 AVDB maker id（只缓存命中结果，失败下次重试）。"""
    cache_key = name.strip()
    cached = _maker_id_cache.get(cache_key)
    if cached:
        return cached
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
        # "IdeaPocket" 与上游 "IDEA POCKET" 分词结果不同，用去空格后的紧凑串兜底匹配
        compact = "".join(_words(cand))
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
            if words == row_words or compact == "".join(_words(maker_name)):
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
    if best_id:
        if len(_maker_id_cache) >= _MAKER_ID_CACHE_MAX:
            _maker_id_cache.pop(next(iter(_maker_id_cache)))
        _maker_id_cache[cache_key] = best_id
    return best_id


def _fetch_torrents(keyword: str) -> list[dict[str, Any]]:
    data = request_json(TORRENTS_PATH, {"keyword": keyword})
    rows = data if isinstance(data, list) else []
    return [r for r in rows if isinstance(r, dict)][:_TORRENT_RAW_MAX]


def fetch_rank(category: str, period: str) -> dict[str, Any]:
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


def fetch_playback(period: str, filter_by: str) -> dict[str, Any]:
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


def fetch_latest(
    category: str,
    page: int,
    limit: int,
    sort_by: str,
    filter_by: str,
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


def fetch_top(category: str, page: int, limit: int, year: str) -> dict[str, Any]:
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
        # 年份榜固定 250 条，再往后 AVDB 会回绕；到底后不再多拉一页
        if len(items) >= limit and page * limit < 250:
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


def fetch_years() -> dict[str, Any]:
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


def fetch_recommend() -> dict[str, Any]:
    """编辑推荐（``movies/recommend``）。"""
    items = _cached_list(
        "recommend",
        lambda: _movie_rows(request_json("/api/v1/javdb/movies/recommend")),
    )
    return {"items": items}


def fetch_hot_reviews(period: str) -> dict[str, Any]:
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
                "score": _num(r.get("score")),
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


def fetch_reviews(movie_id: str, page: int, limit: int) -> dict[str, Any]:
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
            "score": _num(r.get("score")),
            "likesCount": _int(r.get("likes_count")),
            "createdAt": _s(r, "created_at") or None,
            "statusTitle": _s(r, "status_title") or None,
        }
        for r in (rows or [])
        if isinstance(r, dict)
    ]
    return {"movieId": mid, "page": page, "items": items, "hasMore": len(items) >= limit}


def fetch_actors(category: str, page: int, limit: int) -> dict[str, Any]:
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


def fetch_tags(category: str) -> dict[str, Any]:
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


def fetch_browse(
    category: str,
    group: str,
    tag_id: str,
    tag_ids: str,
    actor_id: str,
    year: str,
    maker_id: str,
    director_id: str,
    list_id: str,
    publisher_id: str,
    series_id: str,
    series_type: str,
    sort_by: str,
    order_by: str,
    page: int,
    limit: int,
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
        # 参数值本身可能含 "-"，字符串拼接会与其它组合撞 key，用排序后的键值对做键
        f"browse-{sorted(params.items())!r}",
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


def fetch_image(url: str, w: int) -> tuple[bytes, str]:
    """AVDB 图片代理：封面 CDN 是加扰字节流，须经 AVDB ``img-proxy`` 解码。"""
    target = str(url or "").strip()
    if urlsplit(target).scheme.lower() not in ("http", "https"):
        raise HTTPException(status_code=400, detail="图片地址无效")
    try:
        raw = request_bytes("/api/v1/img-proxy/", {"url": target, "w": w or None})
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    if not raw:
        raise HTTPException(status_code=502, detail="图片拉取失败")
    return raw, _sniff_image(raw)


def fetch_search(q: str, search_type: str) -> dict[str, Any]:
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


def fetch_movie_search(
    q: str,
    page: int,
    limit: int,
    cnsub: bool,
    filter_by: str,
    movie_type: str,
    sort_by: str,
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


def fetch_maker_movies(name: str, page: int, limit: int) -> dict[str, Any]:
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


def fetch_torrents(keyword: str, page: int, limit: int, exact: bool) -> dict[str, Any]:
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


def fetch_movie_detail(movie_id: str) -> dict[str, Any]:
    """影片详情 + 磁力列表 + 评论资源 + 相关影片。"""
    mid = movie_id.strip()
    if not mid:
        raise HTTPException(status_code=400, detail="缺少影片 ID")
    # 详情 / 磁力 / 评论资源互不依赖，并发拉取以缩短首屏耗时
    with ThreadPoolExecutor(max_workers=3) as pool:
        detail_future = pool.submit(request_json, f"/api/v1/javdb/movies/{mid}")
        magnets_future = pool.submit(request_json, f"/api/v1/javdb/movies/{mid}/magnets")
        resources_future = pool.submit(
            request_json, f"/api/v1/javdb/movies/{mid}/comment-resources"
        )
        try:
            detail = detail_future.result()
            magnets_data = magnets_future.result()
        except AvdbError as e:
            raise HTTPException(status_code=502, detail=str(e)) from e
        # 评论区共享资源（ed2k 等）：失败不影响主流程
        try:
            res_data = resources_future.result()
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
            "hd": _bool(r.get("hd")),
            "createdAt": _s(r, "comment_date") or None,
        }
        for r in (res_raw or [])
        if isinstance(r, dict) and _s(r, "resource_url", "url")
    ]

    data = detail if isinstance(detail, dict) else {}
    movie = data.get("movie") if isinstance(data.get("movie"), dict) else data
    base = _normalize_movie(movie if isinstance(movie, dict) else {})

    share_url = _share_url(data)

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
        if isinstance(p, dict)
        and (
            _s(p, "thumb_url", "thumbUrl")
            or _s(p, "large_url", "largeUrl")
        )
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
        "hasPreviewVideo": _bool(data.get("has_preview_video"))
        or _bool(movie.get("has_preview_video")),
        "previewVideoUrl": (
            _s(data, "preview_video_url", "previewVideoUrl")
            or _s(movie, "preview_video_url")
            or None
        ),
        "canPlay": _bool(data.get("can_play")) or _bool(movie.get("can_play")),
        "playSources": play_sources if isinstance(play_sources, list) else [],
        "hasLocalSubtitle": _bool(data.get("has_local_subtitle"))
        or _bool(movie.get("has_local_subtitle")),
        "avdbTorrents": avdb_torrents,
    }


def fetch_entity(kind: str, id: str) -> dict[str, Any]:
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
    return {
        "kind": kind.strip(),
        "id": entity["id"] or eid,
        "type": entity["type"],
        "name": entity["name"],
        "videosCount": entity["videosCount"],
        "shareUrl": _share_url(data) or None,
        "hasCollected": _bool(data.get("has_collected")),
    }


def fetch_actor_detail(id: str) -> dict[str, Any]:
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
        "shareUrl": _share_url(data) or None,
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


def fetch_actor_recommend() -> dict[str, Any]:
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


def fetch_related_lists(movie_id: str, page: int, limit: int) -> dict[str, Any]:
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


def fetch_list_detail(id: str) -> dict[str, Any]:
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
    detail["isCreator"] = _bool(data.get("is_creator"))
    detail["hasCollected"] = _bool(data.get("has_collected"))
    return detail


def fetch_recent_viewed() -> dict[str, Any]:
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


def fetch_account() -> dict[str, Any]:
    """AVDB 账号状态（``javdb/account``）：是否已登录 / 是否 VIP。"""
    try:
        data = request_json("/api/v1/javdb/account")
    except AvdbError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    if not isinstance(data, dict):
        return {"loggedIn": False, "username": None, "isVip": False}
    return {
        "loggedIn": _bool(data.get("logged_in")),
        "username": _s(data, "username") or None,
        "isVip": _bool(data.get("is_vip")),
    }


# ── 在线播放源聚合 ────────────────────────────────


def _stream(
    *,
    url: str,
    title: str,
    provider: str,
    source: str,
) -> dict[str, Any]:
    """统一成影视播放器的片源结构（含来源标记）。"""
    playable = bool(url)
    return {
        "addon": provider,
        "addonSlug": source,
        "name": title,
        "title": title,
        "url": url,
        "externalUrl": "" if playable else url,
        "infoHash": "",
        "fileIdx": None,
        "filename": "",
        "size": None,
        "kind": "direct" if playable else "external",
        "playable": playable,
        "source": source,
    }


def _plugin_play_sources(keyword: str) -> dict[str, Any]:
    """插件仓库里片商类（category=studio/provider）插件的在线播放源。

    只取「片商」分组插件，影视 / 短剧类插件不参与片商页的播放源聚合。
    """
    data = dispatcher.playable_streams(("studio", "provider"), keyword)
    streams = [
        {**item, "source": "plugin"}
        for item in (data.get("streams") or [])
        if isinstance(item, dict)
    ]
    return {"streams": streams, "reason": str(data.get("reason") or "")}


def _stremio_play_sources(keyword: str) -> dict[str, Any]:
    """Stremio 社区插件聚合源：用番号直接查询 addon。"""
    try:
        data = asyncio.run(addon_streams.collect("movie", keyword, any_id=True))
    except RuntimeError as e:
        return {"streams": [], "reason": f"社区插件查询失败：{e}"}
    if not isinstance(data, dict):
        return {"streams": [], "reason": "社区插件返回异常"}
    streams = [
        {**item, "source": "stremio"}
        for item in (data.get("streams") or [])
        if isinstance(item, dict)
    ]
    reason = "" if streams else str(data.get("reason") or "")
    return {"streams": streams, "reason": reason}


def _avdb_play_sources(movie_id: str) -> dict[str, Any]:
    """AVDB 在线播放源：读详情的 play_sources，再逐个换取播放地址。"""
    try:
        detail = request_json(f"/api/v1/javdb/movies/{movie_id}")
    except AvdbError as e:
        return {"streams": [], "reason": f"AVDB: {e}"}
    data = detail if isinstance(detail, dict) else {}
    movie = data.get("movie") if isinstance(data.get("movie"), dict) else data
    sources = data.get("play_sources") or movie.get("play_sources") or []
    if not isinstance(sources, list) or not sources:
        return {"streams": [], "reason": ""}
    streams: list[dict[str, Any]] = []
    reasons: list[str] = []
    for source in sources:
        if not isinstance(source, dict):
            continue
        name = _s(source, "name", "title") or "AVDB 播放源"
        try:
            played = request_json(
                f"/api/v1/javdb/movies/{movie_id}/play",
                {"source_id": source.get("id")},
            )
        except AvdbError as e:
            reasons.append(f"AVDB {name}: {e}")
            continue
        url = dispatcher.play_url(played)
        if not url:
            reasons.append(f"AVDB {name}: 未获取到播放地址")
            continue
        streams.append(_stream(url=url, title=name, provider="AVDB", source="avdb"))
    return {"streams": streams, "reason": "；".join(reasons)}


def fetch_play_sources(movie_id: str, number: str = "", title: str = "") -> dict[str, Any]:
    """聚合在线播放源：片商类插件 / Stremio 社区插件 / AVDB 播放源。"""
    mid = movie_id.strip()
    keyword = number.strip() or title.strip()
    results: list[dict[str, Any]] = []
    if mid:
        results.append(_avdb_play_sources(mid))
    if keyword:
        results.append(_plugin_play_sources(keyword))
        results.append(_stremio_play_sources(keyword))

    streams: list[dict[str, Any]] = []
    seen: set[str] = set()
    for result in results:
        for stream in result.get("streams") or []:
            key = stream.get("url") or stream.get("externalUrl") or stream.get("infoHash") or ""
            if not key or key in seen:
                continue
            seen.add(key)
            streams.append(stream)

    reasons: list[str] = []
    if not keyword:
        reasons.append("缺少番号，无法匹配插件片源")
    for result in results:
        reason = str(result.get("reason") or "").strip()
        if reason and reason not in reasons:
            reasons.append(reason)
    return {"streams": streams, "total": len(streams), "reason": "；".join(reasons)}

