#!/usr/bin/env python3
"""一次性迁移：旧 Postgres 元库（app_settings/users）→ SQLite `data/meta.db`。

用法（在 api 下）：
    .venv/bin/python ../../scripts/migrate_meta_pg_to_sqlite.py
    .venv/bin/python ../../scripts/migrate_meta_pg_to_sqlite.py --from postgresql://...

只迁设置与账号；会话不迁（旧 cookie 失效，重新登录即可）。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "apps" / "api"))

from app.core.db import connect, init_db, meta_db_path  # noqa: E402

DEFAULT_SRC = "postgresql://postgres:postgres@192.168.2.38:5439/nextweb"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="src", default=DEFAULT_SRC, help="旧元库 Postgres DSN")
    ap.add_argument("--dry-run", action="store_true", help="只读旧库，不写 SQLite")
    args = ap.parse_args()

    import psycopg
    from psycopg.rows import dict_row

    init_db()
    print(f"target sqlite: {meta_db_path()}")

    with psycopg.connect(args.src, connect_timeout=10, row_factory=dict_row) as src:
        settings = src.execute(
            "SELECT key, value_json, updated_at FROM app_settings"
        ).fetchall()
        users = src.execute(
            "SELECT id, username, password_hash, is_admin, created_at FROM users"
        ).fetchall()

    print(f"source: {len(settings)} settings, {len(users)} users")
    if args.dry_run:
        for s in settings:
            print("  setting", s["key"])
        for u in users:
            print("  user", u["id"], u["username"], "admin=", u["is_admin"])
        return 0

    with connect() as dst:
        for s in settings:
            dst.execute(
                """
                INSERT INTO app_settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                  value_json = excluded.value_json,
                  updated_at = excluded.updated_at
                """,
                (s["key"], s["value_json"], str(s["updated_at"])),
            )
        for u in users:
            dst.execute(
                """
                INSERT INTO users (id, username, password_hash, is_admin, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  username = excluded.username,
                  password_hash = excluded.password_hash,
                  is_admin = excluded.is_admin
                """,
                (
                    int(u["id"]),
                    u["username"],
                    u["password_hash"],
                    int(u["is_admin"] or 0),
                    str(u["created_at"]),
                ),
            )
        dst.commit()

    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
