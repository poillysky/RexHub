"""User + opaque session store (Postgres meta DB)."""


import hashlib
import re
import secrets
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from typing import Any

import bcrypt

import app.core.settings_store as settings_store
from app.core.db import connect

SESSION_DAYS = 30
COOKIE_NAME = "sns_session"
USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,32}$")

# 注册码 → 角色：存元库 settings_store（key: auth.invite.admin / auth.invite.user）。
# 首次访问时按需生成，管理员可在 PWA 设置页查看与轮换。
INVITE_ADMIN_KEY = "auth.invite.admin"
INVITE_USER_KEY = "auth.invite.user"

# 首次并发访问时避免两个请求各自生成邀请码、后写覆盖前写
_invite_lock = threading.Lock()


def _new_invite_code() -> str:
    return secrets.token_hex(8)


def _read_invite(key: str) -> str:
    value = settings_store.get_setting(key)
    return value.strip() if isinstance(value, str) else ""


def invite_codes() -> dict[str, str]:
    """返回当前两个邀请码；缺失或异常时生成并写库。"""
    with _invite_lock:
        admin = _read_invite(INVITE_ADMIN_KEY)
        if not admin:
            admin = _new_invite_code()
            settings_store.put_setting(INVITE_ADMIN_KEY, admin)

        user = _read_invite(INVITE_USER_KEY)
        if not user or user == admin:
            user = _new_invite_code()
            while user == admin:
                user = _new_invite_code()
            settings_store.put_setting(INVITE_USER_KEY, user)

        return {"admin": admin, "user": user}


def ensure_invite_codes() -> dict[str, str]:
    """启动时调用：确保邀请码已落库。"""
    return invite_codes()


def rotate_invites() -> dict[str, str]:
    """轮换两个邀请码，旧码立即失效。"""
    with _invite_lock:
        admin = _new_invite_code()
        user = _new_invite_code()
        while user == admin:
            user = _new_invite_code()
        settings_store.put_setting(INVITE_ADMIN_KEY, admin)
        settings_store.put_setting(INVITE_USER_KEY, user)
        return {"admin": admin, "user": user}


def resolve_invite(code: str) -> bool | None:
    """校验注册码，返回该注册码对应的管理员身份；无效返回 None。"""
    text = (code or "").strip()
    if not text:
        return None
    codes = invite_codes()
    if secrets.compare_digest(text, codes["admin"]):
        return True
    if secrets.compare_digest(text, codes["user"]):
        return False
    return None


def admin_count() -> int:
    with connect() as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS c FROM users WHERE is_admin = 1"
        ).fetchone()
    return int(row["c"] or 0) if row else 0


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _fmt(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def _parse(ts: str) -> datetime:
    return datetime.strptime(str(ts)[:19], "%Y-%m-%d %H:%M:%S").replace(
        tzinfo=timezone.utc
    )


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return bcrypt.checkpw(
            password.encode("utf-8"),
            password_hash.encode("utf-8"),
        )
    except ValueError:
        return False


def hash_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def validate_username(username: str) -> str | None:
    u = username.strip()
    if not USERNAME_RE.match(u):
        return "用户名须为 3–32 位字母/数字/下划线"
    return None


def validate_password(password: str) -> str | None:
    if len(password) < 8 or len(password) > 128:
        return "密码须为 8–128 位"
    # bcrypt 只使用前 72 字节，超出部分会被静默忽略，直接拒绝更安全
    if len(password.encode("utf-8")) > 72:
        return "密码过长：最多 72 字节（中文约 24 个字符）"
    return None


def create_user(
    username: str,
    password: str,
    *,
    is_admin: bool = False,
) -> dict[str, Any]:
    err = validate_username(username) or validate_password(password)
    if err:
        raise ValueError(err)
    uname = username.strip()
    with connect() as conn:
        exists = conn.execute(
            "SELECT 1 AS ok FROM users WHERE LOWER(username) = LOWER(?)",
            (uname,),
        ).fetchone()
        if exists:
            raise ValueError("用户名已被占用")
        cur = None
        try:
            cur = conn.execute(
                """
                INSERT INTO users (username, password_hash, is_admin)
                VALUES (?, ?, ?)
                """,
                (uname, hash_password(password), 1 if is_admin else 0),
            )
        except sqlite3.IntegrityError as e:
            # 并发注册同名时唯一索引会命中这里
            raise ValueError("用户名已被占用") from e
        conn.commit()
        row = conn.execute(
            "SELECT id, username, is_admin, created_at FROM users WHERE id = ?",
            (cur.lastrowid,),
        ).fetchone()
    return dict(row)


def get_user_by_username(username: str) -> dict[str, Any] | None:
    with connect() as conn:
        row = conn.execute(
            """
            SELECT id, username, password_hash, is_admin, created_at
            FROM users WHERE LOWER(username) = LOWER(?)
            """,
            (username.strip(),),
        ).fetchone()
    return dict(row) if row else None


def create_session(user_id: int) -> str:
    raw = secrets.token_urlsafe(32)
    token_hash = hash_token(raw)
    expires = _utc_now() + timedelta(days=SESSION_DAYS)
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO sessions (user_id, token_hash, expires_at)
            VALUES (?, ?, ?)
            """,
            (user_id, token_hash, _fmt(expires)),
        )
        conn.commit()
    return raw


def revoke_session(raw_token: str | None) -> None:
    if not raw_token:
        return
    with connect() as conn:
        conn.execute(
            """
            UPDATE sessions
            SET revoked_at = CURRENT_TIMESTAMP
            WHERE token_hash = ? AND revoked_at IS NULL
            """,
            (hash_token(raw_token),),
        )
        conn.commit()


def prune_sessions() -> int:
    """删除已过期会话，避免 sessions 表无限增长；返回清理条数。"""
    with connect() as conn:
        cur = conn.execute(
            "DELETE FROM sessions WHERE expires_at <= ?",
            (_fmt(_utc_now()),),
        )
        conn.commit()
    return int(cur.rowcount or 0)


def user_from_session(raw_token: str | None) -> dict[str, Any] | None:
    if not raw_token:
        return None
    with connect() as conn:
        row = conn.execute(
            """
            SELECT u.id, u.username, u.is_admin, u.created_at,
                   s.expires_at, s.revoked_at
            FROM sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = ?
            """,
            (hash_token(raw_token),),
        ).fetchone()
    if not row:
        return None
    if row["revoked_at"]:
        return None
    if _parse(str(row["expires_at"])) <= _utc_now():
        return None
    return {
        "id": row["id"],
        "username": row["username"],
        "is_admin": bool(row["is_admin"]),
        "created_at": row["created_at"],
    }


def public_user(user: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": user["id"],
        "username": user["username"],
        "is_admin": bool(user.get("is_admin")),
        "created_at": user.get("created_at"),
    }


def change_password(
    user_id: int,
    current_password: str,
    new_password: str,
    *,
    keep_token: str | None = None,
) -> None:
    err = validate_password(new_password)
    if err:
        raise ValueError(err)
    if current_password == new_password:
        raise ValueError("新密码不能与当前密码相同")

    with connect() as conn:
        row = conn.execute(
            "SELECT id, password_hash FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if not row:
            raise ValueError("用户不存在")
        if not verify_password(current_password, row["password_hash"]):
            raise ValueError("当前密码不正确")
        conn.execute(
            "UPDATE users SET password_hash = ? WHERE id = ?",
            (hash_password(new_password), user_id),
        )
        # 改密后吊销其它会话（保留当前这次登录），避免旧会话继续可用
        conn.execute(
            """
            UPDATE sessions
            SET revoked_at = CURRENT_TIMESTAMP
            WHERE user_id = ? AND revoked_at IS NULL AND token_hash != ?
            """,
            (user_id, hash_token(keep_token or "")),
        )
        conn.commit()


def list_users() -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT u.id, u.username, u.is_admin, u.created_at,
                   COUNT(s.id) AS sessions
            FROM users u
            LEFT JOIN sessions s
              ON s.user_id = u.id
             AND s.revoked_at IS NULL
             AND s.expires_at > ?
            GROUP BY u.id
            ORDER BY u.is_admin DESC, u.id ASC
            """,
            (_fmt(_utc_now()),),
        ).fetchall()
    return [{**public_user(dict(r)), "sessions": int(r["sessions"] or 0)} for r in rows]


def admin_set_password(user_id: int, new_password: str) -> None:
    """管理员重置他人密码（无需旧密码），并吊销该用户全部会话。"""
    err = validate_password(new_password)
    if err:
        raise ValueError(err)
    with connect() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if not row:
            raise ValueError("用户不存在")
        conn.execute(
            "UPDATE users SET password_hash = ? WHERE id = ?",
            (hash_password(new_password), user_id),
        )
        conn.execute(
            """
            UPDATE sessions
            SET revoked_at = CURRENT_TIMESTAMP
            WHERE user_id = ? AND revoked_at IS NULL
            """,
            (user_id,),
        )
        conn.commit()


def set_user_role(
    user_id: int,
    is_admin: bool,
    *,
    actor_id: int,
) -> dict[str, Any]:
    """设置 / 取消管理员；不允许取消自己，也不允许取消最后一个管理员。"""
    if int(user_id) == int(actor_id) and not is_admin:
        raise ValueError("不能取消自己的管理员权限")
    with connect() as conn:
        row = conn.execute(
            "SELECT id, is_admin FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if not row:
            raise ValueError("用户不存在")
        if int(row["is_admin"] or 0) == 1 and not is_admin:
            count = conn.execute(
                "SELECT COUNT(*) AS c FROM users WHERE is_admin = 1"
            ).fetchone()
            if int(count["c"] or 0) <= 1:
                raise ValueError("不能取消最后一个管理员")
        conn.execute(
            "UPDATE users SET is_admin = ? WHERE id = ?",
            (1 if is_admin else 0, user_id),
        )
        conn.commit()
        out = conn.execute(
            "SELECT id, username, is_admin, created_at FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
    return dict(out)


def revoke_user_sessions(user_id: int, *, actor_id: int) -> int:
    """吊销某用户全部会话（强制下线）；不能用于自己，自己请走 logout。"""
    if int(user_id) == int(actor_id):
        raise ValueError("请使用「退出登录」下线自己的会话")
    with connect() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if not row:
            raise ValueError("用户不存在")
        cur = conn.execute(
            """
            UPDATE sessions
            SET revoked_at = CURRENT_TIMESTAMP
            WHERE user_id = ? AND revoked_at IS NULL
            """,
            (user_id,),
        )
        conn.commit()
    return int(cur.rowcount or 0)


def delete_user(user_id: int, *, actor_id: int) -> None:
    if int(user_id) == int(actor_id):
        raise ValueError("不能删除当前登录账号")
    with connect() as conn:
        row = conn.execute(
            "SELECT id, is_admin FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if not row:
            raise ValueError("用户不存在")
        if int(row["is_admin"] or 0) == 1:
            admin_count = conn.execute(
                "SELECT COUNT(*) AS c FROM users WHERE is_admin = 1"
            ).fetchone()
            if int(admin_count["c"] or 0) <= 1:
                raise ValueError("不能删除最后一个管理员")
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
        conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
        conn.commit()
