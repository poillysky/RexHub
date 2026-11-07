"""App / 插件接口的统一鉴权。

**只有一套会话**：``/api/auth/login`` 下发的会话 token，存在 ``data/meta.db`` 的
``sessions`` 表里。Web 用 Cookie（``sns_session``）携带，iOS 用
``Authorization: Bearer <token>`` 携带，两者指向同一条会话记录。
"""


from fastapi import HTTPException, Request, status

import app.auth.store as auth_store


def session_token(request: Request, token_query: str | None = None) -> str:
    """取会话 token：查询参数 > Cookie（Web）> Authorization: Bearer（iOS）。"""
    token = (token_query or "").strip()
    if token:
        return token
    token = request.cookies.get(auth_store.COOKIE_NAME, "")
    if token:
        return token
    auth = request.headers.get("authorization", "")
    scheme, _, value = auth.partition(" ")
    if scheme.lower() == "bearer":
        return value.strip()
    return ""


def require_session(request: Request, token_query: str | None = None) -> dict:
    """校验会话，返回用户；无效则抛 401。

    ``token_query`` 供播放器/图片这类无法带 Header 的场景用查询参数传 token。
    """
    user = auth_store.user_from_session(session_token(request, token_query))
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="登录已过期，请重新登录",
        )
    return user
