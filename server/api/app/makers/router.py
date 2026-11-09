"""片商页：AVDB 榜单/搜索/影片/磁力代理。

- ``/makers/rank``        AVDB 榜单（类别 × 日/周/月）
- ``/makers/search``      AVDB 片商搜索
- ``/makers/movies``      片商影片（先解析 maker id，取完整片库；失败退回番号搜索）
- ``/makers/movie/{id}``  影片详情 + 磁力列表

查询与数据组装逻辑见 ``app.makers.service``，归一化函数见 ``app.makers.normalize``。
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Query, Response

from app.auth.routes import require_user
from app.makers import service
from app.makers.service import MOVIE_LIMIT_MAX, TORRENT_LIMIT_MAX

router = APIRouter(
    prefix="/makers",
    tags=["makers"],
    dependencies=[Depends(require_user)],
)


@router.get("/rank")
def makers_rank(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
    period: str = Query("daily", description="daily / weekly / monthly"),
) -> dict[str, Any]:
    """AVDB 排行榜（榜单接口直连，带 5 分钟缓存）。"""
    return service.fetch_rank(category, period)


@router.get("/playback")
def makers_playback(
    period: str = Query("daily", description="daily / weekly / monthly"),
    filter_by: str = Query("all", description="all 热播 / high_score 热门"),
) -> dict[str, Any]:
    """可播放榜（``rankings/playback``，该接口不区分内容类别）。

    ``filter_by=all`` 为官方「热播」榜，``filter_by=high_score`` 为官方「热门」榜
    （同一接口的高分重排版，交集约 2/3，排序不同）。
    """
    return service.fetch_playback(period, filter_by)


@router.get("/latest")
def makers_latest(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=MOVIE_LIMIT_MAX),
    sort_by: str = Query("update", description="update 更新 / release 发行"),
    filter_by: str = Query("all", description="all 全部 / magnets 含磁链 / subtitle 含字幕"),
) -> dict[str, Any]:
    """最新影片（``movies/latest``）。"""
    return service.fetch_latest(category, page, limit, sort_by, filter_by)


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
    return service.fetch_top(category, page, limit, year)


@router.get("/years")
def makers_years() -> dict[str, Any]:
    """TOP250 年份下拉选项（取自 ``javdb/tags`` 的年份分组，仅保留有榜单数据的年份）。"""
    return service.fetch_years()


@router.get("/recommend")
def makers_recommend() -> dict[str, Any]:
    """编辑推荐（``movies/recommend``）。"""
    return service.fetch_recommend()


@router.get("/hot-reviews")
def makers_hot_reviews(
    period: str = Query("weekly", description="daily / weekly / monthly"),
) -> dict[str, Any]:
    """热评（``reviews/hotly``），带影片快照。"""
    return service.fetch_hot_reviews(period)


@router.get("/reviews")
def makers_reviews(
    movie_id: str = Query(..., min_length=1),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(20, ge=1, le=100),
) -> dict[str, Any]:
    """某影片的评论（``movies/{id}/reviews``）。"""
    return service.fetch_reviews(movie_id, page, limit)


@router.get("/actors")
def makers_actors(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美"),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=100),
) -> dict[str, Any]:
    """演员列表（``javdb/actors``；type=1/2 有各自演员，type=3/4 与 0 相同）。"""
    return service.fetch_actors(category, page, limit)


@router.get("/tags")
def makers_tags(
    category: str = Query("0", description="0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫"),
) -> dict[str, Any]:
    """分类标签（``javdb/tags``，按类别分组；含「基本」组）。"""
    return service.fetch_tags(category)


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
    return service.fetch_browse(
        category,
        group,
        tag_id,
        tag_ids,
        actor_id,
        year,
        maker_id,
        director_id,
        list_id,
        publisher_id,
        series_id,
        series_type,
        sort_by,
        order_by,
        page,
        limit,
    )


@router.get("/image")
def makers_image(
    url: str = Query(..., min_length=8, max_length=1600),
    w: int = Query(0, ge=0, le=2000),
) -> Response:
    """AVDB 图片代理：封面 CDN 是加扰字节流，须经 AVDB ``img-proxy`` 解码。"""
    raw, media_type = service.fetch_image(url, w)
    return Response(
        content=raw,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/search")
def makers_search(
    q: str = Query(..., min_length=1),
    search_type: str = Query("maker", alias="type"),
) -> dict[str, Any]:
    """AVDB 站内搜索：片商 / 演员 / 片单 / 系列 / 导演 / 番号前缀。"""
    return service.fetch_search(q, search_type)


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
    return service.fetch_movie_search(q, page, limit, cnsub, filter_by, movie_type, sort_by)


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
    return service.fetch_maker_movies(name, page, limit)


@router.get("/torrents")
def makers_torrents(
    keyword: str = Query(..., min_length=1, max_length=120),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(24, ge=1, le=TORRENT_LIMIT_MAX),
    exact: bool = Query(False, description="仅保留番号完全一致的记录"),
) -> dict[str, Any]:
    """AVDB 自有种子库检索（番号 / 片商名 / 标题关键词）。"""
    return service.fetch_torrents(keyword, page, limit, exact)


@router.get("/movie/{movie_id}")
def makers_movie(movie_id: str) -> dict[str, Any]:
    """影片详情 + 磁力列表 + 评论资源 + 相关影片。"""
    return service.fetch_movie_detail(movie_id)


@router.get("/movie/{movie_id}/play-sources")
def makers_movie_play_sources(
    movie_id: str,
    number: str = Query("", max_length=40),
    title: str = Query("", max_length=200),
) -> dict[str, Any]:
    """在线播放源聚合：片商类插件 / Stremio 社区插件 / AVDB 播放源。"""
    return service.fetch_play_sources(movie_id, number, title)


@router.get("/entity")
def makers_entity(
    kind: str = Query("maker", description="maker / director / series"),
    id: str = Query(..., min_length=1, max_length=64),
) -> dict[str, Any]:
    """片商 / 导演 / 系列详情（``javdb/makers|directors|series/{id}``）。"""
    return service.fetch_entity(kind, id)


@router.get("/actor-detail")
def makers_actor_detail(
    id: str = Query(..., min_length=1, max_length=64),
) -> dict[str, Any]:
    """演员详情（``javdb/actors/{id}``）：资料 + 标签组。"""
    return service.fetch_actor_detail(id)


@router.get("/actor-recommend")
def makers_actor_recommend() -> dict[str, Any]:
    """推荐演员（``javdb/actors/recommend``）：新晋 / 月榜 / 推荐三组。"""
    return service.fetch_actor_recommend()


@router.get("/lists/related")
def makers_related_lists(
    movie_id: str = Query(..., min_length=1),
    page: int = Query(1, ge=1, le=9999),
    limit: int = Query(10, ge=1, le=50),
) -> dict[str, Any]:
    """某影片的相关片单（``javdb/lists/related``）。"""
    return service.fetch_related_lists(movie_id, page, limit)


@router.get("/list-detail")
def makers_list_detail(
    id: str = Query(..., min_length=1, max_length=64),
) -> dict[str, Any]:
    """片单详情（``javdb/lists/{id}``）。"""
    return service.fetch_list_detail(id)


@router.get("/recent-viewed")
def makers_recent_viewed() -> dict[str, Any]:
    """最近浏览（``javdb/users/recent_viewed``）。"""
    return service.fetch_recent_viewed()


@router.get("/account")
def makers_account() -> dict[str, Any]:
    """AVDB 账号状态（``javdb/account``）：是否已登录 / 是否 VIP。"""
    return service.fetch_account()
