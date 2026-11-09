"""Auth HTTP routes — opaque cookie session (指南 §5.4.D)."""

import ipaddress
import os

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response

from pydantic import BaseModel, Field

import app.auth.store as auth_store
import app.core.rate_limit as rate_limit
from app.core.envelope import Envelope
from app.rexhub.auth_guard import session_token

router = APIRouter(prefix="/api/auth", tags=["auth"])

# 注册低频、登录高频：按客户端 IP 的滑动窗口限流
REGISTER_LIMIT = 5
REGISTER_WINDOW_S = 600
LOGIN_LIMIT = 10
LOGIN_WINDOW_S = 60


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
    is_admin: bool = False


class AdminSetRoleBody(BaseModel):
    is_admin: bool


class AdminResetPasswordBody(BaseModel):
    new_password: str = Field(min_length=1, max_length=128)


def _cookie_secure(request: Request) -> bool:
    """Cookie 的 Secure 属性：显式环境变量优先，否则按本次请求的真实协议判断。"""
    override = os.environ.get("SNS_COOKIE_SECURE", "").strip().lower()
    if override in {"1", "true", "yes"}:
        return True
    if override in {"0", "false", "no"}:
        return False
    proto = request.headers.get("x-forwarded-proto", "").split(",")[0].strip().lower()
    if proto:
        return proto == "https"
    return request.url.scheme == "https"


def _set_session_cookie(request: Request, response: Response, raw: str) -> None:
    response.set_cookie(
        key=auth_store.COOKIE_NAME,
        value=raw,
        httponly=True,
        samesite="lax",
        secure=_cookie_secure(request),
        max_age=auth_store.SESSION_DAYS * 24 * 60 * 60,
        path="/",
    )


def _clear_session_cookie(request: Request, response: Response) -> None:
    response.delete_cookie(
        key=auth_store.COOKIE_NAME,
        path="/",
        httponly=True,
        samesite="lax",
        secure=_cookie_secure(request),
    )


def _client_key(request: Request) -> str:
    """限流键：仅当直连方是内网/回环（反向代理）时才信任 X-Forwarded-For。

    取 XFF 最右一跳 —— 它由最近的反向代理追加，客户端无法伪造；
    直连公网时一律用连接地址，避免用 XFF 绕过限流。
    """
    peer = request.client.host if request.client else ""
    if peer:
        try:
            trusted = ipaddress.ip_address(peer).is_private or ipaddress.ip_address(
                peer
            ).is_loopback
        except ValueError:
            trusted = False
        if trusted:
            forwarded = request.headers.get("x-forwarded-for", "")
            hops = [h.strip() for h in forwarded.split(",") if h.strip()]
            if hops:
                return hops[-1]
    return peer or "unknown"


def _enforce_rate_limit(
    request: Request,
    scope: str,
    *,
    limit: int,
    window_s: float,
) -> None:
    if not rate_limit.allow(scope, _client_key(request), limit=limit, window_s=window_s):
        raise HTTPException(
            status_code=429,
            detail="操作过于频繁，请稍后再试",
            headers={"Retry-After": str(int(window_s))},
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
def register(body: RegisterBody, request: Request, response: Response) -> Envelope:
    _enforce_rate_limit(
        request,
        "auth:register",
        limit=REGISTER_LIMIT,
        window_s=REGISTER_WINDOW_S,
    )
    is_admin = auth_store.resolve_invite(body.invite_code)
    if is_admin is None:
        raise HTTPException(status_code=400, detail="注册码无效")
    try:
        user = auth_store.create_user(body.username, body.password, is_admin=is_admin)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    raw = auth_store.create_session(int(user["id"]))
    _set_session_cookie(request, response, raw)
    response.status_code = 201
    return Envelope(
        data={**auth_store.public_user(user), "token": raw},
        message="registered",
        status=201,
    )


@router.post("/login", response_model=Envelope)
def login(body: AuthBody, request: Request, response: Response) -> Envelope:
    _enforce_rate_limit(
        request,
        "auth:login",
        limit=LOGIN_LIMIT,
        window_s=LOGIN_WINDOW_S,
    )
    user = auth_store.get_user_by_username(body.username)
    if not user or not auth_store.verify_password(body.password, user["password_hash"]):
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    raw = auth_store.create_session(int(user["id"]))
    _set_session_cookie(request, response, raw)
    # token 同时返回给 iOS（Bearer）；Web 只依赖 Cookie，忽略该字段
    return Envelope(data={**auth_store.public_user(user), "token": raw}, message="ok")


@router.post("/logout", response_model=Envelope)
def logout(request: Request, response: Response) -> Envelope:
    auth_store.revoke_session(session_token(request))
    _clear_session_cookie(request, response)
    return Envelope(data=None, message="logged_out")


@router.get("/me", response_model=Envelope)
def me(user: dict[str, Any] = Depends(require_user)) -> Envelope:
    return Envelope(data=auth_store.public_user(user), message="ok")


@router.get("/invites", response_model=Envelope)
def get_invites(_admin: dict[str, Any] = Depends(require_admin)) -> Envelope:
    """管理员查看当前邀请码（注册码）。"""
    return Envelope(data=auth_store.invite_codes(), message="ok")


@router.post("/invites/rotate", response_model=Envelope)
def rotate_invites(_admin: dict[str, Any] = Depends(require_admin)) -> Envelope:
    """管理员轮换邀请码，旧码立即失效。"""
    return Envelope(data=auth_store.rotate_invites(), message="rotated")


@router.post("/password", response_model=Envelope)
def change_password(
    body: ChangePasswordBody,
    request: Request,
    user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    try:
        auth_store.change_password(
            int(user["id"]),
            body.current_password,
            body.new_password,
            keep_token=session_token(request),
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
    response: Response,
    _admin: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    """管理员创建用户：角色直接指定，邀请码只用于自助注册。"""
    try:
        user = auth_store.create_user(
            body.username,
            body.password,
            is_admin=body.is_admin,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    response.status_code = 201
    return Envelope(
        data=auth_store.public_user(user),
        message="created",
        status=201,
    )


@router.put("/users/{user_id}/role", response_model=Envelope)
def admin_set_user_role(
    user_id: int,
    body: AdminSetRoleBody,
    admin: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    """设置 / 取消管理员（不能取消自己，也不能取消最后一个管理员）。"""
    try:
        user = auth_store.set_user_role(
            user_id,
            body.is_admin,
            actor_id=int(admin["id"]),
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return Envelope(data=auth_store.public_user(user), message="role_updated")


@router.post("/users/{user_id}/sessions/revoke", response_model=Envelope)
def admin_revoke_sessions(
    user_id: int,
    admin: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    """强制某用户下线（吊销其全部会话）。"""
    try:
        revoked = auth_store.revoke_user_sessions(
            user_id,
            actor_id=int(admin["id"]),
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return Envelope(data={"revoked": revoked}, message="sessions_revoked")


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
    admin: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    if user_id == int(admin["id"]):
        raise HTTPException(
            status_code=400,
            detail="修改自己的密码请使用「修改密码」",
        )
    try:
        auth_store.admin_set_password(user_id, body.new_password)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return Envelope(data=None, message="password_reset")
