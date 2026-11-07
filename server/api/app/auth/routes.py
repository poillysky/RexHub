"""Auth HTTP routes — opaque cookie session (指南 §5.4.D)."""






import os

from typing import Any



from fastapi import APIRouter, Depends, HTTPException, Request, Response

from pydantic import BaseModel, Field



import app.auth.store as auth_store
from app.core.envelope import Envelope
from app.rexhub.auth_guard import session_token



router = APIRouter(prefix="/api/auth", tags=["auth"])





class AuthBody(BaseModel):

    username: str = Field(min_length=1, max_length=64)

    password: str = Field(min_length=1, max_length=128)


class RegisterBody(AuthBody):
    """注册需邀请码：决定注册后的角色（管理员 / 普通用户）。"""

    invite_code: str = Field(min_length=1, max_length=32)





class ChangePasswordBody(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=1, max_length=128)


class AdminCreateUserBody(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)
    invite_code: str = Field(min_length=1, max_length=32)


class AdminResetPasswordBody(BaseModel):
    new_password: str = Field(min_length=1, max_length=128)


def _cookie_secure() -> bool:

    return os.environ.get("SNS_COOKIE_SECURE", "").strip() in {"1", "true", "yes"}





def _set_session_cookie(response: Response, raw: str) -> None:

    response.set_cookie(

        key=auth_store.COOKIE_NAME,

        value=raw,

        httponly=True,

        samesite="lax",

        secure=_cookie_secure(),

        max_age=auth_store.SESSION_DAYS * 24 * 60 * 60,

        path="/",

    )





def _clear_session_cookie(response: Response) -> None:

    response.delete_cookie(

        key=auth_store.COOKIE_NAME,

        path="/",

        httponly=True,

        samesite="lax",

        secure=_cookie_secure(),

    )





def get_optional_user(request: Request) -> dict[str, Any] | None:
    return auth_store.user_from_session(session_token(request))





def require_user(request: Request) -> dict[str, Any]:

    user = get_optional_user(request)

    if not user:

        raise HTTPException(status_code=401, detail="未登录")

    return user





def require_admin(request: Request) -> dict[str, Any]:

    user = require_user(request)

    if not user.get("is_admin"):

        raise HTTPException(status_code=403, detail="需要管理员权限")

    return user





@router.post("/register", response_model=Envelope)

def register(body: RegisterBody, response: Response) -> Envelope:

    is_admin = auth_store.resolve_invite(body.invite_code)

    if is_admin is None:

        raise HTTPException(status_code=400, detail="注册码无效")

    try:

        user = auth_store.create_user(body.username, body.password, is_admin=is_admin)

    except ValueError as e:

        raise HTTPException(status_code=400, detail=str(e)) from e

    raw = auth_store.create_session(int(user["id"]))

    _set_session_cookie(response, raw)

    return Envelope(
        data={**auth_store.public_user(user), "token": raw},
        message="registered",
        status=201,
    )





@router.post("/login", response_model=Envelope)

def login(body: AuthBody, response: Response) -> Envelope:

    user = auth_store.get_user_by_username(body.username)

    if not user or not auth_store.verify_password(body.password, user["password_hash"]):

        raise HTTPException(status_code=401, detail="用户名或密码错误")

    raw = auth_store.create_session(int(user["id"]))

    _set_session_cookie(response, raw)

    # token 同时返回给 iOS（Bearer）；Web 只依赖 Cookie，忽略该字段
    return Envelope(data={**auth_store.public_user(user), "token": raw}, message="ok")





@router.post("/logout", response_model=Envelope)

def logout(request: Request, response: Response) -> Envelope:

    auth_store.revoke_session(session_token(request))

    _clear_session_cookie(response)

    return Envelope(data=None, message="logged_out")





@router.get("/me", response_model=Envelope)

def me(user: dict[str, Any] = Depends(require_user)) -> Envelope:

    return Envelope(data=auth_store.public_user(user), message="ok")




@router.post("/password", response_model=Envelope)
def change_password(
    body: ChangePasswordBody,
    user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    try:
        auth_store.change_password(
            int(user["id"]),
            body.current_password,
            body.new_password,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return Envelope(data=None, message="password_changed")


@router.get("/users", response_model=Envelope)
def list_users(_admin: dict[str, Any] = Depends(require_admin)) -> Envelope:
    return Envelope(data=auth_store.list_users(), message="ok")


@router.post("/users", response_model=Envelope)
def admin_create_user(
    body: AdminCreateUserBody,
    _admin: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    """管理员创建用户：注册码决定角色（与注册页一致）。"""
    is_admin = auth_store.resolve_invite(body.invite_code)
    if is_admin is None:
        raise HTTPException(status_code=400, detail="注册码无效")
    try:
        user = auth_store.create_user(body.username, body.password, is_admin=is_admin)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return Envelope(
        data=auth_store.public_user(user),
        message="created",
        status=201,
    )


@router.delete("/users/{user_id}", response_model=Envelope)
def admin_delete_user(
    user_id: int,
    admin: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    try:
        auth_store.delete_user(user_id, actor_id=int(admin["id"]))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return Envelope(data=None, message="deleted")


@router.post("/users/{user_id}/password", response_model=Envelope)
def admin_reset_password(
    user_id: int,
    body: AdminResetPasswordBody,
    _admin: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    try:
        auth_store.admin_set_password(user_id, body.new_password)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return Envelope(data=None, message="password_reset")


