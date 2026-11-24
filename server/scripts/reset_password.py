#!/usr/bin/env python3
"""重置本地账号密码 / 列出账号（直连 data/meta.db）。

用法（在 server/ 下）：
    .venv 里的解释器执行，例如：
    api/.venv/bin/python scripts/reset_password.py --list
    api/.venv/bin/python scripts/reset_password.py poilly 'NewPass1234'
    api/.venv/bin/python scripts/reset_password.py poilly 'NewPass1234' --admin
    api/.venv/bin/python scripts/reset_password.py poilly --unlock   # 只吊销该用户全部会话

说明：
  - 直接写库，不经过 HTTP，因此不受登录限流影响。
  - 重置后该用户所有旧会话一并吊销，强制用新密码重新登录。
  - 密码规则与后端一致：8–128 位、UTF-8 不超过 72 字节。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

API_DIR = Path(__file__).resolve().parents[1] / "api"
sys.path.insert(0, str(API_DIR))

import app.auth.store as auth_store  # noqa: E402


def cmd_list() -> int:
    users = auth_store.list_users()
    if not users:
        print("（无账号）")
        return 0
    print(f"{'id':>4}  {'username':<24} {'admin':<6} created_at")
    for u in users:
        print(
            f"{int(u['id']):>4}  {u['username']:<24} "
            f"{'yes' if u.get('is_admin') else 'no':<6} {u.get('created_at', '')}"
        )
    return 0


def cmd_reset(username: str, password: str | None, make_admin: bool | None) -> int:
    user = auth_store.get_user_by_username(username)
    if not user:
        print(f"账号不存在：{username}", file=sys.stderr)
        return 1

    uid = int(user["id"])
    if password is not None:
        err = auth_store.validate_password(password)
        if err:
            print(err, file=sys.stderr)
            return 1
        auth_store.admin_set_password(uid, password)
        print(f"已重置密码：{username} (id={uid})")

    if make_admin is not None:
        auth_store.set_user_role(uid, make_admin, actor_id=uid)
        print(f"角色已更新：{username} -> {'管理员' if make_admin else '普通用户'}")

    revoked = auth_store.revoke_user_sessions(uid, actor_id=uid)
    print(f"已吊销会话：{revoked} 条")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="RexHub 账号密码重置 / 列表")
    ap.add_argument("username", nargs="?", help="目标账号用户名")
    ap.add_argument("password", nargs="?", help="新密码（8–128 位）")
    ap.add_argument("--list", "-l", action="store_true", help="列出所有账号")
    ap.add_argument("--admin", action="store_true", help="同时设为管理员")
    ap.add_argument("--no-admin", action="store_true", help="同时取消管理员")
    ap.add_argument("--unlock", action="store_true", help="只吊销会话，不改密码")
    args = ap.parse_args()

    if args.list or not args.username:
        return cmd_list()

    if args.admin and args.no_admin:
        print("--admin 与 --no-admin 不能同时使用", file=sys.stderr)
        return 1

    password = None if args.unlock else args.password
    if not args.unlock and not password:
        print("需要提供新密码，或用 --unlock 只吊销会话", file=sys.stderr)
        return 1

    make_admin = True if args.admin else (False if args.no_admin else None)
    return cmd_reset(args.username, password, make_admin)


if __name__ == "__main__":
    raise SystemExit(main())
