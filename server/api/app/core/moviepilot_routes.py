"""MoviePilot 媒体自动化服务：设置与连通性探测。

鉴权方式：MoviePilot 开放 API 用 ``?apikey=<令牌>`` 查询参数，
例如 ``GET {base}/api/v1/user/?apikey=<令牌>``。
"""

import hashlib
import time
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

import app.core.settings_store as settings_store
from app.auth.routes import require_admin
from app.core.moviepilot_config import (
    MOVIEPILOT_KEY,
    MoviePilotConfigBody,
    MoviePilotTestBody,
    _probe,
    get_config,
)
from app.core.moviepilot_http import (
    _CACHE_TTL_S,
    _DOWNLOAD_CACHE_TTL_S,
    _PT_SEARCH_BUDGET_S,
    _SEARCH_CACHE_TTL_S,
    _detail_cache,
    _douban_personage_id,
    _download_cache,
    _fetch_list,
    _mp_get,
    _mp_get_rows,
    _mp_post,
    _person_cache,
    _search_cache,
    _seg,
)
from app.core.moviepilot_normalize import (
    _num,
    _normalize_detail,
    _normalize_item,
    _normalize_person,
    _normalize_related,
    _normalize_torrent,
    _promo_rank,
    _text,
)
from app.rexhub.auth_guard import require_session
from app.core.service_config import normalize_base

router = APIRouter(tags=["moviepilot"], dependencies=[Depends(require_session)])


def _wrap(data: Any, message: str = "ok", status: int = 200) -> dict[str, Any]:
    return {"data": data, "message": message, "status": status}


@router.post("/moviepilot/test")
def test_moviepilot_settings(
    body: MoviePilotTestBody,
    _admin: dict = Depends(require_admin),
) -> dict[str, Any]:
    """用请求里的草稿配置探测连接，不落库；令牌留空时复用已保存的令牌。"""
    prev = get_config(include_secrets=True)
    if body.baseUrl.strip():
        base = normalize_base(body.baseUrl)
        if not base:
            raise HTTPException(status_code=400, detail="地址需为 http(s):// 开头的有效地址")
    else:
        base = str(prev["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="请填写服务地址")
    api_key = body.apiKey.strip() or str(prev.get("apiKey") or "")
    if not api_key:
        raise HTTPException(status_code=400, detail="请填写 API 令牌")
    timeout = body.timeoutSec or float(prev["timeoutSec"])
    return _wrap(_probe(base, api_key, timeout))


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
    media_seg = _seg(media_id, "条目 ID")

    cache_key = f"detail:{key_source}:{media_id}:{media_type}"
    now = time.time()
    hit = _detail_cache.get(cache_key)
    if hit and now - hit[0] < _CACHE_TTL_S:
        return _wrap(hit[1])

    raw = _mp_get(
        f"media/{media_seg}",
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
    media_seg = _seg(media_id, "条目 ID")

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
            _mp_get_rows(f"tmdb/recommend/{media_seg}/{kind}")
        )
        similar = _normalize_related(
            _mp_get_rows(f"tmdb/similar/{media_seg}/{kind}")
        )
    elif key_source == "douban":
        recommendations = _normalize_related(
            _mp_get_rows(f"douban/recommend/{media_seg}/{kind}")
        )
    elif key_source == "bangumi":
        recommendations = _normalize_related(
            _mp_get_rows(f"bangumi/recommend/{media_seg}")
        )
    else:
        recommendations = _normalize_related(
            _mp_get_rows(f"anilist/recommend/{media_seg}")
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

    person = _normalize_person(
        _mp_get(f"{src}/person/{_seg(pid, '影人 ID')}"), key_source, pid
    )
    if not person["name"] and key_source == "douban":
        mapped = _douban_personage_id(pid)
        if mapped:
            pid = mapped
            person = _normalize_person(
                _mp_get(f"{src}/person/{_seg(pid, '影人 ID')}"), key_source, pid
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
        f"{src}/person/credits/{_seg(_resolve_person_id(src, pid), '影人 ID')}",
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
        path = f"search/media/{_seg(media_id, 'IMDb ID')}"
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
    deadline = time.monotonic() + _PT_SEARCH_BUDGET_S
    for page_no in range(1, 11):
        remaining = deadline - time.monotonic()
        if remaining <= 1.0:
            break
        try:
            chunk = _mp_get(
                path,
                {**params, "page": str(page_no)},
                timeout_s=min(timeout_s, remaining),
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
def moviepilot_download(
    body: MoviePilotDownloadBody,
    _user: dict = Depends(require_session),
) -> dict[str, Any]:
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
def put_moviepilot_settings(
    body: MoviePilotConfigBody,
    _admin: dict = Depends(require_admin),
) -> dict[str, Any]:
    base = normalize_base(body.baseUrl)
    if not base:
        raise HTTPException(status_code=400, detail="地址需为 http(s):// 开头的有效地址")
    api_key = body.apiKey.strip()
    note = body.note.strip() if body.note is not None else None

    def _merge(prev: dict[str, Any]) -> dict[str, Any]:
        return {
            "enabled": body.enabled,
            "baseUrl": base,
            "apiKey": api_key or str(prev.get("apiKey") or ""),
            "timeoutSec": body.timeoutSec,
            "note": note if note is not None else str(prev.get("note") or ""),
        }

    settings_store.update_setting(MOVIEPILOT_KEY, _merge)
    return _wrap(get_config(include_secrets=False), "saved")
