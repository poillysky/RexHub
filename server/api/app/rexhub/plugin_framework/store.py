"""插件框架存储：仓库注册表、已安装插件、程序目录与数据目录。

文件布局（``config.DATA_DIR`` 下）：

    plugin_framework/repositories.json    # 插件仓库注册
    plugin_framework/plugins.json         # 已安装插件状态
    plugins/<plugin_id>/<version>/        # 插件程序文件（可回滚保留上一版）
    plugin_data/<plugin_id>/              # 插件用户数据，卸载程序不删除

旧版「功能模块」的 ``modules.json`` 与 ``module_repo.json`` 会在首次初始化时
自动迁移成插件记录，原目录保留不动，红果模块因此可以直接作为第一个插件运行。
"""


import functools
import json
import os
import re
import shutil
import threading
import time
from pathlib import Path
from typing import Any

from app.rexhub import config

BASE_DIR = config.DATA_DIR / "plugin_framework"
REPOS_FILE = BASE_DIR / "repositories.json"
PLUGINS_FILE = BASE_DIR / "plugins.json"
PLUGINS_DIR = config.DATA_DIR / "plugins"
PLUGIN_DATA_DIR = config.DATA_DIR / "plugin_data"

LEGACY_MODULES_FILE = config.DATA_DIR / "modules.json"
LEGACY_REPO_FILE = config.DATA_DIR / "module_repo.json"

MAX_FILE_BYTES = 16 * 1024 * 1024
_IO_LOCK = threading.RLock()
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,240}$")


def _locked(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        with _IO_LOCK:
            return func(*args, **kwargs)

    return wrapper


def _read(path: Path, key: str) -> list[dict[str, Any]]:
    try:
        data = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return []
    if isinstance(data, dict):
        items = data.get(key)
    elif isinstance(data, list):
        items = data
    else:
        items = None
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, dict) and item.get("id")]


def _write(path: Path, key: str, items: list[dict[str, Any]]) -> None:
    config.ensure_data_dir()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    try:
        tmp.write_text(
            json.dumps({key: items}, ensure_ascii=False, indent=2), "utf-8"
        )
        os.chmod(tmp, 0o600)
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def _text(value: object, limit: int = 300) -> str:
    return str(value or "").strip()[:limit]


def safe_id(plugin_id: str) -> str:
    text = _text(plugin_id, 80)
    if not text or not _ID_RE.match(text):
        raise ValueError(f"插件 ID 不合法：{plugin_id}")
    return text


# ---------------------------------------------------------------------------
# 仓库
# ---------------------------------------------------------------------------


def list_repositories() -> list[dict[str, Any]]:
    items = _read(REPOS_FILE, "repositories")
    return sorted(items, key=lambda item: item.get("created_at", 0))


def get_repository(repo_id: str) -> dict[str, Any]:
    repo_id = _text(repo_id, 80)
    row = next(
        (item for item in list_repositories() if _text(item.get("id")) == repo_id), None
    )
    if row is None:
        raise ValueError("插件仓库不存在")
    return dict(row)


@_locked
def save_repository(row: dict[str, Any]) -> dict[str, Any]:
    repo_id = safe_id(str(row.get("id") or ""))
    items = _read(REPOS_FILE, "repositories")
    now = int(time.time())
    existing = next((item for item in items if _text(item.get("id")) == repo_id), None)
    payload = {
        "id": repo_id,
        "name": _text(row.get("name"), 120) or repo_id,
        "url": _text(row.get("url"), 200),
        "branch": _text(row.get("branch"), 80),
        "index_path": _text(row.get("index_path"), 160) or "repository.json",
        "format": _text(row.get("format"), 20) or "repository",
        "enabled": bool(row.get("enabled", True)),
        "created_at": int(existing.get("created_at") or now) if existing else now,
        "updated_at": now,
    }
    if existing is None:
        items.append(payload)
    else:
        items = [payload if _text(item.get("id")) == repo_id else item for item in items]
    _write(REPOS_FILE, "repositories", items)
    return dict(payload)


@_locked
def delete_repository(repo_id: str) -> bool:
    repo_id = _text(repo_id, 80)
    items = _read(REPOS_FILE, "repositories")
    kept = [item for item in items if _text(item.get("id")) != repo_id]
    if len(kept) == len(items):
        return False
    _write(REPOS_FILE, "repositories", kept)
    return True


# ---------------------------------------------------------------------------
# 插件
# ---------------------------------------------------------------------------


def list_plugins() -> list[dict[str, Any]]:
    items = sorted(_read(PLUGINS_FILE, "plugins"), key=lambda item: item.get("installed_at", 0))
    for item in items:
        item.setdefault("protocol", "native")
    return items


def get_plugin(plugin_id: str) -> dict[str, Any]:
    plugin_id = _text(plugin_id, 80)
    row = next(
        (item for item in list_plugins() if _text(item.get("id")) == plugin_id), None
    )
    if row is None:
        raise ValueError("插件不存在")
    return dict(row)


@_locked
def upsert_plugin(row: dict[str, Any]) -> dict[str, Any]:
    plugin_id = safe_id(str(row.get("id") or ""))
    items = _read(PLUGINS_FILE, "plugins")
    now = int(time.time())
    existing = next((item for item in items if _text(item.get("id")) == plugin_id), None)
    payload = dict(existing or {})
    payload.update(row)
    payload["id"] = plugin_id
    payload["installed_at"] = int(existing.get("installed_at") or now) if existing else now
    payload["updated_at"] = now
    if existing is None:
        items.append(payload)
    else:
        items = [payload if _text(item.get("id")) == plugin_id else item for item in items]
    _write(PLUGINS_FILE, "plugins", items)
    return dict(payload)


@_locked
def patch_plugin(plugin_id: str, **fields: Any) -> dict[str, Any]:
    plugin_id = _text(plugin_id, 80)
    items = _read(PLUGINS_FILE, "plugins")
    row = next((item for item in items if _text(item.get("id")) == plugin_id), None)
    if row is None:
        raise ValueError("插件不存在")
    row.update(fields)
    row["updated_at"] = int(time.time())
    _write(PLUGINS_FILE, "plugins", items)
    return dict(row)


@_locked
def delete_plugin(plugin_id: str) -> bool:
    plugin_id = _text(plugin_id, 80)
    items = _read(PLUGINS_FILE, "plugins")
    kept = [item for item in items if _text(item.get("id")) != plugin_id]
    if len(kept) == len(items):
        return False
    _write(PLUGINS_FILE, "plugins", kept)
    return True


# ---------------------------------------------------------------------------
# 目录
# ---------------------------------------------------------------------------


def plugin_dir(plugin_id: str) -> Path:
    return PLUGINS_DIR / safe_id(plugin_id)


def version_dir(plugin_id: str, version: str) -> Path:
    text = _text(version, 40)
    if not text or ".." in text or not _PATH_RE.match(text):
        raise ValueError(f"版本号不合法：{version}")
    return plugin_dir(plugin_id) / text


def data_dir(plugin_id: str) -> Path:
    path = PLUGIN_DATA_DIR / safe_id(plugin_id)
    path.mkdir(parents=True, exist_ok=True)
    return path


def install_path(row: dict[str, Any]) -> Path:
    raw = _text(row.get("install_path"), 400)
    if raw:
        return Path(raw)
    return version_dir(str(row["id"]), _text(row.get("installed_version")) or "current")


def write_manifest_file(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.tmp")
    tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def remove_tree(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)


def read_legacy_modules() -> list[dict[str, Any]]:
    return _read(LEGACY_MODULES_FILE, "modules")


def read_legacy_repo() -> dict[str, Any]:
    try:
        data = json.loads(LEGACY_REPO_FILE.read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _infer_category(module_id: str, title: str) -> tuple[str, list[str], dict[str, str]]:
    label = f"{module_id} {title}".lower()
    if "hongguo" in label or "红果" in title or "短剧" in title:
        return (
            "shortdrama",
            ["playback.extract", "playback.stream"],
            {
                "playback.extract": {"path": "/v1/rankings", "method": "GET"},
                "playback.stream": {
                    "path": "/v1/episodes/{id}/stream",
                    "method": "GET",
                },
            },
        )
    if "subtitle" in label or "字幕" in title:
        return "subtitle", ["subtitle.search", "subtitle.download"], {}
    if "danmaku" in label or "弹幕" in title:
        return "danmaku", ["danmaku.search", "danmaku.fetch"], {}
    if "search" in label or "resource" in label or "资源" in title:
        return "resource", ["resource.search"], {}
    return "tool", [], {}


@_locked
def migrate_legacy() -> dict[str, Any]:
    """首次启动时把旧模块与单仓库配置迁移为插件记录；已有插件文件则跳过。"""
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    migrated_plugins: list[str] = []
    migrated_repos: list[str] = []

    legacy = read_legacy_repo()
    legacy_url = _text(legacy.get("url"), 200)
    legacy_repo_id = ""
    if not REPOS_FILE.exists() and legacy_url:
        branch = _text(legacy.get("branch"), 80)
        index_path = _text(legacy.get("manifest"), 160) or "modules.json"
        legacy_repo_id = f"legacy-{re.sub(r'[^a-z0-9]+', '-', legacy_url.lower()).strip('-')[:40]}"
        save_repository(
            {
                "id": legacy_repo_id,
                "name": legacy_url,
                "url": legacy_url,
                "branch": branch,
                "index_path": index_path,
                "format": "modules",
                "enabled": True,
            }
        )
        migrated_repos.append(legacy_repo_id)

    if not PLUGINS_FILE.exists():
        for item in read_legacy_modules():
            if not item.get("id"):
                continue
            plugin_id = safe_id(str(item["id"]))
            title = _text(item.get("title"), 120) or plugin_id
            category, capabilities, endpoints = _infer_category(plugin_id, title)
            version = _text(item.get("version"), 40) or "0.0.0"
            origin = item.get("origin") if isinstance(item.get("origin"), dict) else {}
            legacy_path = config.DATA_DIR / "modules" / plugin_id / "module.mjs"
            source_path = legacy_path if legacy_path.is_file() else None
            row = {
                "id": plugin_id,
                "name": title,
                "description": _text(item.get("description"), 800),
                "author": _text(item.get("author"), 80),
                "category": category,
                "api_version": "1.0",
                "capabilities": capabilities,
                "endpoints": endpoints,
                "runtime": {
                    "type": "isolated",
                    "engine": "node",
                    "entrypoint": "module.mjs",
                    **({"port": int(item.get("port") or 0)} if item.get("port") else {}),
                },
                "entrypoint": "module.mjs",
                "permissions": ["network"],
                "config": [],
                "healthcheck": "",
                "installed_version": version,
                "install_path": str(source_path.parent) if source_path else "",
                "source_repo": legacy_repo_id,
                "source_manifest": _text(origin.get("path"), 240),
                "enabled": bool(item.get("enabled")),
                "state": "installed" if item.get("enabled") else "disabled",
                "error": "",
                "migrated_from": "modules.json",
            }
            if source_path:
                manifest = {
                    "id": plugin_id,
                    "name": title,
                    "version": version,
                    "description": row["description"],
                    "author": row["author"],
                    "category": category,
                    "api_version": "1.0",
                    "capabilities": capabilities,
                    "runtime": row["runtime"],
                    "entrypoint": "module.mjs",
                    "endpoints": endpoints,
                    "permissions": ["network"],
                }
                write_manifest_file(source_path.parent / "manifest.json", manifest)
            upsert_plugin(row)
            migrated_plugins.append(plugin_id)

    # 旧模块迁移过来的插件：把字符串版 endpoints 补成 {path, method}
    for row in list_plugins():
        if row.get("migrated_from") != "modules.json":
            continue
        endpoints = row.get("endpoints")
        if not isinstance(endpoints, dict) or not any(
            isinstance(value, str) for value in endpoints.values()
        ):
            continue
        category, capabilities, fixed = _infer_category(
            str(row["id"]), str(row.get("name") or "")
        )
        patch_plugin(
            str(row["id"]),
            category=category,
            capabilities=capabilities,
            endpoints=fixed,
        )

    return {"plugins": migrated_plugins, "repositories": migrated_repos}
