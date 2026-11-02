from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import time

from . import config


_ITERATIONS = 200_000


def _secret() -> bytes:
    config.ensure_data_dir()
    if not config.SECRET_PATH.exists():
        config.SECRET_PATH.write_bytes(secrets.token_bytes(32))
        os.chmod(config.SECRET_PATH, 0o600)
    return config.SECRET_PATH.read_bytes()


def _b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _b64d(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _hash_password(password: str, salt: bytes, iterations: int = _ITERATIONS) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)


def load_account() -> dict | None:
    try:
        account = json.loads(config.ACCOUNT_PATH.read_text())
        if not all(key in account for key in ("username", "salt", "hash")):
            return None
        return account
    except (OSError, json.JSONDecodeError):
        return None


def has_account() -> bool:
    return load_account() is not None


def account_username() -> str:
    account = load_account()
    return account["username"] if account else ""


def create_account(username: str, password: str) -> None:
    if has_account():
        raise RuntimeError("账号已存在")

    config.ensure_data_dir()
    salt = secrets.token_bytes(16)
    data = {
        "username": username,
        "salt": _b64e(salt),
        "hash": _b64e(_hash_password(password, salt)),
        "iterations": _ITERATIONS,
        "created_at": int(time.time()),
    }

    tmp_path = config.ACCOUNT_PATH.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(data, ensure_ascii=False))
    os.chmod(tmp_path, 0o600)
    tmp_path.replace(config.ACCOUNT_PATH)


def verify_credentials(username: str, password: str) -> bool:
    account = load_account()
    if not account:
        return False
    if not secrets.compare_digest(username.encode(), account["username"].encode()):
        return False

    salt = _b64d(account["salt"])
    expected = _b64d(account["hash"])
    actual = _hash_password(password, salt, account.get("iterations", _ITERATIONS))
    return secrets.compare_digest(actual, expected)


def _token_epoch(account: dict | None = None) -> int:
    """账号的令牌版本号，改密时递增，用于让旧令牌立即失效。"""
    account = account if account is not None else load_account()
    if not account:
        return 0
    try:
        return int(account.get("token_epoch", 0))
    except (TypeError, ValueError):
        return 0


def change_password(username: str, old_password: str, new_password: str) -> bool:
    """校验旧密码后重写盐与哈希，并轮换令牌版本使旧令牌失效。"""
    account = load_account()
    if not account:
        return False
    if not secrets.compare_digest(username.encode(), account["username"].encode()):
        return False

    salt = _b64d(account["salt"])
    expected = _b64d(account["hash"])
    actual = _hash_password(old_password, salt, account.get("iterations", _ITERATIONS))
    if not secrets.compare_digest(actual, expected):
        return False

    new_salt = secrets.token_bytes(16)
    account["salt"] = _b64e(new_salt)
    account["hash"] = _b64e(_hash_password(new_password, new_salt))
    account["iterations"] = _ITERATIONS
    account["token_epoch"] = _token_epoch(account) + 1
    account["updated_at"] = int(time.time())

    config.ensure_data_dir()
    tmp_path = config.ACCOUNT_PATH.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(account, ensure_ascii=False))
    os.chmod(tmp_path, 0o600)
    tmp_path.replace(config.ACCOUNT_PATH)
    return True


def issue_token(username: str, scope: str = "api") -> tuple[str, int]:
    issued_at = int(time.time())
    payload = json.dumps(
        {
            "sub": username,
            "iat": issued_at,
            "exp": issued_at + config.TOKEN_TTL_SECONDS,
            "scope": scope,
            "ver": _token_epoch(),
        },
        separators=(",", ":"),
    ).encode()
    body = _b64e(payload)
    signature = hmac.new(_secret(), body.encode(), hashlib.sha256).digest()
    return f"{body}.{_b64e(signature)}", config.TOKEN_TTL_SECONDS


def verify_token(token: str, scope: str | None = None) -> dict | None:
    """校验签名、有效期、令牌版本与可选的作用域。"""
    try:
        body, signature = token.split(".")
        expected = hmac.new(_secret(), body.encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(_b64d(signature), expected):
            return None
        payload = json.loads(_b64d(body))
        if payload.get("exp", 0) < time.time():
            return None
        if payload.get("ver", 0) != _token_epoch():
            return None
        if scope is not None and payload.get("scope") != scope:
            return None
        return payload
    except Exception:
        return None


# 登录失败计数：key 为「来源 + 账号」，仅在进程内保存，重启即清空。
_login_failures: dict[str, list[float]] = {}


def login_locked_for(key: str) -> int:
    """返回剩余锁定秒数，0 表示当前可登录。"""
    now = time.time()
    recent = [stamp for stamp in _login_failures.get(key, []) if now - stamp < config.LOGIN_LOCK_SECONDS]
    if recent:
        _login_failures[key] = recent
    else:
        _login_failures.pop(key, None)
    if len(recent) < config.LOGIN_MAX_FAILURES:
        return 0
    return int(config.LOGIN_LOCK_SECONDS - (now - recent[0])) + 1


def record_login_failure(key: str) -> None:
    _login_failures.setdefault(key, []).append(time.time())


def clear_login_failures(key: str) -> None:
    _login_failures.pop(key, None)
