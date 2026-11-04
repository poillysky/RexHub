"""App 端资源搜索：检索已接入的自托管服务。

与 Web 管理台的「搜索服务」共用 `resource_search`，只返回结构化 JSON。
"""

from __future__ import annotations

from fastapi import Request, APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from app.rexhub import resource_search, services_store
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/search", tags=["search"])

MAX_KEYWORD = 120


class SearchServiceItem(BaseModel):
    id: str
    name: str
    categoryLabel: str
    notes: str


class SearchServicesResponse(BaseModel):
    items: list[SearchServiceItem]


class SearchResultItem(BaseModel):
    title: str
    # 色花堂的帖子标题与文件名是两回事：title 用于列表与详情页顶部，
    # resourceName 是真实的资源文件名，详情页单独一行展示，其他来源留空。
    resourceName: str = ""
    link: str
    password: str = ""
    kind: str = ""
    # 详情页展示用的资源元数据，取不到的字段留空，客户端按空值隐藏对应行
    size: int = 0
    sizeText: str = ""
    filesCount: int = 0
    createdAt: str = ""
    seeders: int | None = None
    leechers: int | None = None
    resolution: str = ""
    codec: str = ""
    releaseGroup: str = ""
    boardName: str = ""
    sourceUrl: str = ""
    description: str = ""
    previewImages: list[str] = Field(default_factory=list)
    actresses: list[str] = Field(default_factory=list)
    code: str = ""
    censored: str = ""


def _result_item(row: dict) -> SearchResultItem:
    """把检索结果字典收敛成固定结构，缺字段统一落成空值。"""

    def text(key: str) -> str:
        return str(row.get(key) or "").strip()

    def count(key: str) -> int:
        try:
            return int(row.get(key) or 0)
        except (TypeError, ValueError):
            return 0

    def maybe_int(key: str) -> int | None:
        value = row.get(key)
        try:
            return int(value) if value is not None else None
        except (TypeError, ValueError):
            return None

    def strings(key: str) -> list[str]:
        value = row.get(key)
        if not isinstance(value, (list, tuple)):
            return []
        return [str(item).strip() for item in value if str(item).strip()]

    return SearchResultItem(
        title=text("title") or "未命名资源",
        resourceName=text("resourceName"),
        link=text("link"),
        password=text("password"),
        kind=text("kind"),
        size=count("size"),
        sizeText=text("sizeText"),
        filesCount=count("filesCount"),
        createdAt=text("createdAt"),
        seeders=maybe_int("seeders"),
        leechers=maybe_int("leechers"),
        resolution=text("resolution"),
        codec=text("codec"),
        releaseGroup=text("releaseGroup"),
        boardName=text("boardName"),
        sourceUrl=text("sourceUrl"),
        description=text("description"),
        previewImages=strings("previewImages"),
        actresses=strings("actresses"),
        code=text("code"),
        censored=text("censored"),
    )


class SearchGroup(BaseModel):
    id: str
    name: str
    error: str = ""
    hasMore: bool = False
    truncated: bool = False  # 还有匹配数据，但已达到单次检索的候选上限
    items: list[SearchResultItem]


class SearchResponse(BaseModel):
    keyword: str
    groups: list[SearchGroup]


def _require_token(request: Request) -> None:
    require_session(request)


def _searchable() -> list[dict]:
    """只保留已接入检索实现的服务，避免搜索时出现无关来源。"""

    return [
        item
        for item in services_store.list_services()
        if resource_search.resolve_provider(item) is not None
    ]


@router.get("/services", response_model=SearchServicesResponse)
async def search_services(
    request: Request,
) -> SearchServicesResponse:
    """参与搜索的服务列表，App 用来渲染来源筛选。"""

    _require_token(request)
    return SearchServicesResponse(
        items=[
            SearchServiceItem(
                id=str(item.get("id") or ""),
                name=str(item.get("name") or ""),
                categoryLabel=services_store.category_label(
                    str(item.get("category") or "other")
                ),
                notes=str(item.get("notes") or ""),
            )
            for item in _searchable()
        ]
    )


@router.get("", response_model=SearchResponse)
async def search_resources(
    request: Request,
    q: str = "",
    svc: str = "",
    offset: int = 0,
) -> SearchResponse:
    """按服务并发检索；`svc` 为逗号分隔的服务 id，留空表示搜索全部。"""

    _require_token(request)

    keyword = q.strip()[:MAX_KEYWORD]
    if not keyword:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="请输入搜索关键词",
        )

    available = _searchable()
    if not available:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="还没有可搜索的服务，请先在服务管理里添加",
        )

    chosen = {part.strip() for part in svc.split(",") if part.strip()}
    picked = [item for item in available if not chosen or item.get("id") in chosen]
    if not picked:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="所选服务不可用于搜索",
        )

    outcomes = await resource_search.search(picked, keyword, offset=max(0, offset))

    return SearchResponse(
        keyword=keyword,
        groups=[
            SearchGroup(
                id=str(item.get("id") or ""),
                name=str(item.get("name") or ""),
                error=error,
                hasMore=has_more,
                truncated=truncated,
                items=[_result_item(row) for row in rows],
            )
            for item, rows, error, has_more, truncated in outcomes
        ],
    )
