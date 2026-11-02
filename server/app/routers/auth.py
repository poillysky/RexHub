from fastapi import APIRouter, Header, HTTPException, Request, Response, status

from .. import security
from ..schemas import ChangePasswordRequest, LoginRequest, LoginResponse, UserOut

router = APIRouter(prefix="/api/auth", tags=["auth"])


def _token_from(authorization: str | None) -> str:
    if authorization and authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return ""


def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


@router.post("/login", response_model=LoginResponse)
async def login(payload: LoginRequest, request: Request) -> LoginResponse:
    if not security.has_account():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="服务端尚未初始化，请先在管理台创建账号",
        )

    throttle_key = f"api:{_client_ip(request)}:{payload.username}"
    locked = security.login_locked_for(throttle_key)
    if locked:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"登录失败次数过多，请 {locked} 秒后再试",
        )

    if not security.verify_credentials(payload.username, payload.password):
        security.record_login_failure(throttle_key)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="账号或密码错误")

    security.clear_login_failures(throttle_key)
    token, ttl = security.issue_token(payload.username)
    return LoginResponse(
        token=token,
        expires_in=ttl,
        user=UserOut(id=payload.username, name=payload.username),
    )


@router.get("/me", response_model=UserOut)
async def me(authorization: str | None = Header(default=None)) -> UserOut:
    """校验会话，供 App 冷启动恢复登录态。"""
    token = _token_from(authorization)

    payload = security.verify_token(token, scope="api") if token else None
    if payload is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="登录已过期，请重新登录",
        )
    return UserOut(id=payload["sub"], name=payload["sub"])


@router.post("/password", status_code=status.HTTP_204_NO_CONTENT)
async def update_password(
    payload: ChangePasswordRequest,
    authorization: str | None = Header(default=None),
) -> Response:
    """修改密码：校验会话 + 旧密码后重写哈希，旧令牌随即失效。"""
    token = _token_from(authorization)
    session = security.verify_token(token, scope="api") if token else None
    if session is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="登录已过期，请重新登录",
        )

    if not security.change_password(
        session["sub"], payload.old_password, payload.new_password
    ):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="当前密码不正确",
        )

    return Response(status_code=status.HTTP_204_NO_CONTENT)
