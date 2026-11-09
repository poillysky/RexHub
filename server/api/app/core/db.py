"""SQLite 元库 — 设置 + 账号 + 会话 + 种子文件缓存；从不存资源行。

资源库（色花 / Bitmagnet / 向量库）仍是外部 Postgres，见 `pg.py` / `bitmagnet_pg.py`。
"""


import logging
import os
import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Sequence

# app/core/db.py → parents[3] = 部署根 server/（含 api/ web/ maps/ config/ data/）
ROOT = Path(__file__).resolve().parents[3]
DATA_DIR = ROOT / "data"
META_DB_FILENAME = "meta.db"

logger = logging.getLogger("app.db")

_init_lock = threading.Lock()
_initialized = False
_nofile_raised = False
_wal_ready = False


def _raise_nofile_limit() -> None:
    """尽量抬高进程 nofile，避免并发打满默认 1024。"""
    global _nofile_raised
    if _nofile_raised:
        return
    _nofile_raised = True
    try:
        import resource

        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        ceiling = 65535
        if hard != resource.RLIM_INFINITY and hard > 0:
            ceiling = min(ceiling, int(hard))
        if soft >= ceiling:
            return
        resource.setrlimit(resource.RLIMIT_NOFILE, (ceiling, hard))
        logger.info("raised RLIMIT_NOFILE soft %s -> %s (hard=%s)", soft, ceiling, hard)
    except Exception as e:
        logger.debug("could not raise RLIMIT_NOFILE: %s", e)


def _ensure_dir(p: Path) -> Path:
    """返回目录，**只在缺失时** mkdir。

    ⚠️ 不要退回「每次调用都 `mkdir(parents=True, exist_ok=True)`」：
    Windows 上实测 `mkdir(exist_ok=True)` **0.26 ms/次**，而 `is_dir()` 探测只要
    **0.003 ms**（≈90×）。这些 helper 被热路径反复调用。
    """
    if not p.is_dir():
        p.mkdir(parents=True, exist_ok=True)
    return p


def data_dir() -> Path:
    return _ensure_dir(DATA_DIR)


def prefix_runtime_dir() -> Path:
    return _ensure_dir(data_dir() / "prefix")


def prefix_code_ranges_cache() -> Path:
    return prefix_runtime_dir() / "code-ranges.json"


def meta_db_path() -> Path:
    """元库文件：默认 `data/meta.db`，可用 `SNS_META_DB` 覆盖。"""
    raw = (os.environ.get("SNS_META_DB") or "").strip()
    if raw:
        return Path(raw).expanduser().resolve()
    return data_dir() / META_DB_FILENAME


def meta_db_label() -> str:
    """健康检查用：只暴露路径，不含敏感信息。"""
    return f"sqlite:{meta_db_path()}"


class CursorResult:
    __slots__ = ("_cur", "lastrowid", "rowcount", "_rows", "_idx")

    def __init__(
        self,
        cur: Any,
        *,
        lastrowid: int | None = None,
        rows: list[Any] | None = None,
    ) -> None:
        self._cur = cur
        self.lastrowid = lastrowid
        self.rowcount = int(getattr(cur, "rowcount", 0) or 0)
        self._rows = rows
        self._idx = 0

    def fetchone(self) -> Any | None:
        if self._rows is not None:
            if self._idx >= len(self._rows):
                return None
            row = self._rows[self._idx]
            self._idx += 1
            return row
        return self._cur.fetchone()

    def fetchall(self) -> list[Any]:
        if self._rows is not None:
            out = self._rows[self._idx :]
            self._idx = len(self._rows)
            return list(out)
        return list(self._cur.fetchall())


class MetaConnection:
    """SQLite 连接包装：保留 `execute/executemany/commit + ?` 旧调用习惯。"""

    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn

    def execute(
        self,
        sql: str,
        params: Sequence[Any] | None = None,
    ) -> CursorResult:
        cur = self._conn.cursor()
        args: Sequence[Any] = () if params is None else params
        cur.execute(sql, args)
        return CursorResult(cur, lastrowid=cur.lastrowid)

    def executemany(
        self,
        sql: str,
        params_seq: Sequence[Sequence[Any]],
    ) -> CursorResult:
        cur = self._conn.cursor()
        cur.executemany(sql, list(params_seq))
        return CursorResult(cur)

    def commit(self) -> None:
        self._conn.commit()

    def rollback(self) -> None:
        self._conn.rollback()


def _enable_wal() -> None:
    """WAL 只需设一次；失败不影响可用性（退化为默认日志模式）。"""
    global _wal_ready
    if _wal_ready:
        return
    try:
        with connect() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
        _wal_ready = True
    except Exception as e:  # noqa: BLE001
        logger.debug("enable WAL failed: %s", e)


@contextmanager
def connect() -> Iterator[MetaConnection]:
    """获取一条元库连接（sqlite3，用完即关；WAL + busy_timeout 支持并发读）。"""
    _raise_nofile_limit()
    path = meta_db_path()
    if not path.parent.is_dir():
        path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA busy_timeout=30000")
        conn.execute("PRAGMA foreign_keys=ON")
        yield MetaConnection(conn)
    finally:
        conn.close()


def close_meta_db() -> None:
    """兼容 lifespan 关停调用：SQLite 每连接即用即关，这里只重置建表标记。"""
    global _initialized
    _initialized = False


def _table_columns(conn: MetaConnection, table: str) -> set[str]:
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return {str(r["name"]) for r in rows}


def _ensure_column(conn: MetaConnection, table: str, column: str, decl: str) -> None:
    cols = _table_columns(conn, table)
    if column not in cols:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")


def init_db() -> None:
    global _initialized
    _raise_nofile_limit()
    if _initialized:
        return
    with _init_lock:
        if _initialized:
            return
        data_dir()
        _enable_wal()
        with connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS app_settings (
                  key TEXT PRIMARY KEY,
                  value_json TEXT NOT NULL,
                  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  username TEXT NOT NULL,
                  password_hash TEXT NOT NULL,
                  is_admin INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            _ensure_column(conn, "users", "is_admin", "INTEGER NOT NULL DEFAULT 0")
            conn.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_lower
                ON users (LOWER(username))
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  token_hash TEXT NOT NULL UNIQUE,
                  expires_at TEXT NOT NULL,
                  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  revoked_at TEXT
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)"
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS torrent_file_cache (
                  info_hash TEXT PRIMARY KEY,
                  files_json TEXT NOT NULL,
                  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.commit()
        _initialized = True
        logger.info("meta schema ready on %s", meta_db_label())
