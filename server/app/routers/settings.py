"""App 端外观配置：目前只有图标库地址列表。

配置统一由服务端保存，App 负责管理，避免每台设备各存一份。
"""

from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException, status
from pydantic import BaseModel, Field

from .. import appearance_store, security

router = APIRouter(prefix="/api/settings", tags=["settings"])


class IconLibrariesPayload(BaseModel):
    urls: list[str] = Field(default_factory=list)


class IconLibrariesResponse(BaseModel):
    urls: list[str]


def _require_token(authorization: str | None) -> None:
    token = ""
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
    if not token or security.verify_token(token, scope="api") is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="登录已过期，请重新登录",
        )


@router.get("/icon-libraries", response_model=IconLibrariesResponse)
async def get_icon_libraries(
    authorization: str | None = Header(default=None),
) -> IconLibrariesResponse:
    _require_token(authorization)
    return IconLibrariesResponse(urls=appearance_store.icon_libraries())


@router.put("/icon-libraries", response_model=IconLibrariesResponse)
async def put_icon_libraries(
    payload: IconLibrariesPayload,
    authorization: str | None = Header(default=None),
) -> IconLibrariesResponse:
    _require_token(authorization)
    try:
        urls = appearance_store.save_icon_libraries(payload.urls)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc
    return IconLibrariesResponse(urls=urls)
