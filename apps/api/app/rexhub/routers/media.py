"""影视海报墙数据接口。

数据来自服务端的 TMDB 插件（`rexhub.tmdb`），这里把插件产物收敛成 App 需要的
结构；图片统一走 `/api/media/image` 代理，客户端不需要直连 image.tmdb.org。
"""


from fastapi import Request, APIRouter, HTTPException, Query, Response, status
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from app.rexhub import media_bridge
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/media", tags=["media"])


class MediaCatalogItem(BaseModel):
    id: str
    title: str
    mediaType: str


class MediaCatalogsResponse(BaseModel):
    items: list[MediaCatalogItem]


class MediaListItem(BaseModel):
    id: str
    mediaType: str
    title: str
    poster: str = ""
    backdrop: str = ""
    overview: str = ""
    year: str = ""
    rating: float | None = None


class MediaListResponse(BaseModel):
    catalog: str
    page: int
    hasMore: bool
    items: list[MediaListItem]


class MediaTrailer(BaseModel):
    name: str = ""
    url: str = ""


class MediaVideo(BaseModel):
    season: int
    episode: int
    title: str = ""
    overview: str = ""
    still: str = ""
    rating: float | None = None
    released: str = ""


class MediaCastMember(BaseModel):
    name: str
    character: str = ""
    profile: str = ""


class MediaDetail(BaseModel):
    id: str
    mediaType: str
    title: str
    poster: str = ""
    backdrop: str = ""
    logo: str = ""
    overview: str = ""
    tagline: str = ""
    year: str = ""
    released: str = ""
    rating: float | None = None
    runtime: str = ""
    genres: list[str] = Field(default_factory=list)
    countries: list[str] = Field(default_factory=list)
    cast: list[str] = Field(default_factory=list)
    director: list[str] = Field(default_factory=list)
    writer: list[str] = Field(default_factory=list)
    trailers: list[MediaTrailer] = Field(default_factory=list)
    videos: list[MediaVideo] = Field(default_factory=list)
    castPeople: list[MediaCastMember] = Field(default_factory=list)
    recommendations: list[MediaListItem] = Field(default_factory=list)



def _upstream_error(exc: ValueError) -> HTTPException:
    """插件侧失败统一按网关错误返回，客户端据此做单栏降级。"""

    return HTTPException(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail=str(exc) or "影视插件执行失败",
    )


@router.get("/catalogs", response_model=MediaCatalogsResponse)
async def media_catalogs(
    request: Request,
) -> MediaCatalogsResponse:
    """插件声明的前台栏目（电影/剧集），用于首页分栏与筛选。"""

    require_session(request)
    try:
        items = media_bridge.catalogs()
    except ValueError as exc:
        raise _upstream_error(exc) from exc
    return MediaCatalogsResponse(
        items=[MediaCatalogItem(**item) for item in items]
    )


@router.get("/list", response_model=MediaListResponse)
async def media_list(
    request: Request,
    catalog: str = Query(..., min_length=1, max_length=64),
    page: int = Query(1, ge=1, le=500),
) -> MediaListResponse:
    """取某个栏目的一页海报。"""

    require_session(request)
    try:
        items, has_more = await media_bridge.list_catalog(catalog, page)
    except ValueError as exc:
        raise _upstream_error(exc) from exc
    return MediaListResponse(
        catalog=catalog,
        page=page,
        hasMore=has_more,
        items=[MediaListItem(**item) for item in items],
    )


@router.get("/detail", response_model=MediaDetail)
async def media_detail(
    request: Request,
    id: str = Query(..., min_length=1, max_length=120),
) -> MediaDetail:
    """影视详情：简介、演职员、预告片与剧集分集。"""

    require_session(request)
    try:
        item = await media_bridge.detail(id)
    except ValueError as exc:
        raise _upstream_error(exc) from exc
    return MediaDetail(**item)


@router.get("/image")
async def media_image(
    request: Request,
    path: str = Query(..., min_length=1, max_length=200),
    size: str = Query("w500", max_length=16),
) -> Response:
    """TMDB 图片代理（公开）：客户端直接当图片 URL 用，服务端做内存缓存。"""

    try:
        data, content_type = await run_in_threadpool(media_bridge.fetch_image, path, size)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)
        ) from exc
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY, detail="图片拉取失败"
        ) from exc
    return Response(
        content=data,
        media_type=content_type,
        headers={"Cache-Control": "public, max-age=604800, immutable"},
    )
