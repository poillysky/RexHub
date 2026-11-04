"""App 端外观配置：目前只有图标库地址列表。

配置统一由服务端保存，App 负责管理，避免每台设备各存一份。
"""

from __future__ import annotations

from fastapi import Request, APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from app.rexhub import appearance_store
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/settings", tags=["settings"])


class IconLibrariesPayload(BaseModel):
    urls: list[str] = Field(default_factory=list)


class IconLibrariesResponse(BaseModel):
    urls: list[str]


def _require_token(request: Request) -> None:
    require_session(request)


@router.get("/icon-libraries", response_model=IconLibrariesResponse)
async def get_icon_libraries(
    request: Request,
) -> IconLibrariesResponse:
    _require_token(request)
    return IconLibrariesResponse(urls=appearance_store.icon_libraries())


@router.put("/icon-libraries", response_model=IconLibrariesResponse)
async def put_icon_libraries(
    payload: IconLibrariesPayload,
    request: Request,
) -> IconLibrariesResponse:
    _require_token(request)
    try:
        urls = appearance_store.save_icon_libraries(payload.urls)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc
    return IconLibrariesResponse(urls=urls)
