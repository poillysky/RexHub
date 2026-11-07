"""插件安装器：Release 包 / 多文件安装、原子切换、回滚与卸载。

安装过程全部先落到 ``plugins/<id>/.staging-*``，校验 Manifest 与哈希后
再切换到 ``plugins/<id>/<version>``；旧版本目录保留用于回滚。插件用户数据
永远放在 ``plugin_data/<id>``，卸载程序文件时默认不删除。
"""


import hashlib
import io
import json
import os
import posixpath
import time
import zipfile
from pathlib import Path
from typing import Any

from app.rexhub.plugin_framework import manifest as manifest_mod
from app.rexhub.plugin_framework import repositories, store

MAX_ARCHIVE_BYTES = 200 * 1024 * 1024


class InstallError(ValueError):
    """插件安装失败。"""


def _safe_member(name: str) -> str:
    text = name.replace("\\", "/").lstrip("/")
    parts = [part for part in text.split("/") if part]
    if not parts or ".." in parts:
        raise InstallError(f"安装包路径不合法：{name}")
    return "/".join(parts)


def _extract_zip(data: bytes, target: Path) -> None:
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise InstallError("插件发行包不是合法 zip") from exc
    target.mkdir(parents=True, exist_ok=True)
    total = 0
    for info in archive.infolist():
        if info.is_dir():
            continue
        name = _safe_member(info.filename)
        total += info.file_size
        if total > MAX_ARCHIVE_BYTES:
            raise InstallError("插件发行包解压后超过大小限制")
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(info) as source, path.open("wb") as dest:
            dest.write(source.read())


def _find_manifest_root(staging: Path) -> tuple[Path, dict[str, Any]]:
    direct = staging / "manifest.json"
    if direct.is_file():
        return staging, manifest_mod.normalize_manifest(json.loads(direct.read_text("utf-8")))
    candidates = sorted(
        path
        for path in staging.iterdir()
        if path.is_dir() and (path / "manifest.json").is_file()
    )
    if len(candidates) == 1:
        path = candidates[0] / "manifest.json"
        return candidates[0], manifest_mod.normalize_manifest(
            json.loads(path.read_text("utf-8"))
        )
    raise InstallError("安装包中未找到 manifest.json")


def _config_defaults(fields: list[dict[str, Any]]) -> dict[str, str]:
    config: dict[str, str] = {}
    for field in fields:
        if field.get("default"):
            config[str(field["key"])] = str(field["default"])
    return config


def _download_manifest_files(
    repo: dict[str, Any], branch: str, entry: dict[str, Any], manifest_row: dict[str, Any], staging: Path
) -> None:
    """无 Release 包时按 Manifest 的文件列表逐文件下载。"""
    base = posixpath.dirname(str(entry.get("manifest") or ""))
    files = manifest_row.get("files")
    if not isinstance(files, list) or not files:
        files = [{"file": manifest_row.get("entrypoint") or "module.mjs", "target": manifest_row.get("entrypoint") or "module.mjs"}]
    for spec in files[:40]:
        if isinstance(spec, str):
            source = spec
            target = spec
        elif isinstance(spec, dict):
            source = str(spec.get("file") or spec.get("src") or "")
            target = str(spec.get("target") or source)
        else:
            continue
        source = _safe_member(source)
        target = _safe_member(target)
        repo_path = posixpath.join(base, source) if base else source
        data = repositories.fetch_bytes(repo, branch, repo_path)
        path = staging / target
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def _download_legacy_files(
    repo: dict[str, Any], branch: str, entry: dict[str, Any], staging: Path
) -> None:
    for spec in entry.get("files") or []:
        if isinstance(spec, str):
            source = spec
            target = spec
        elif isinstance(spec, dict):
            source = str(spec.get("file") or spec.get("src") or "")
            target = str(spec.get("target") or source)
        else:
            continue
        source = _safe_member(source) if not str(source).startswith(("http://", "https://")) else str(source)
        target = _safe_member(target)
        path = staging / target
        path.parent.mkdir(parents=True, exist_ok=True)
        data = (
            repositories.fetch_absolute(source)
            if source.startswith(("http://", "https://"))
            else repositories.fetch_bytes(repo, branch, source)
        )
        path.write_bytes(data)


def _synthesize_manifest(entry: dict[str, Any]) -> dict[str, Any]:
    runtime = entry.get("runtime") if isinstance(entry.get("runtime"), dict) else {}
    protocol = str(entry.get("protocol") or "native")
    files = entry.get("files") if isinstance(entry.get("files"), list) else []
    js_target = next(
        (str(item.get("target") or "") for item in files if str(item.get("target") or "").endswith(".js")),
        "",
    )
    engine = runtime.get("engine") or ("widget-js" if protocol == "widget-js" else "node")
    entrypoint = runtime.get("entrypoint") or js_target or "module.mjs"
    runtime = {
        "type": runtime.get("type") or "isolated",
        "engine": engine,
        "entrypoint": entrypoint,
        **({"port": runtime["port"]} if runtime.get("port") else {}),
    }
    raw = {
        "id": entry["id"],
        "name": entry.get("name") or entry["id"],
        "version": entry["version"],
        "description": entry.get("description") or "",
        "author": entry.get("author") or "",
        "category": entry.get("category") or "tool",
        "protocol": protocol,
        "api_version": "1.0",
        "capabilities": entry.get("capabilities") or [],
        "endpoints": entry.get("endpoints") or {},
        "runtime": runtime,
        "entrypoint": entrypoint,
        "permissions": ["network", "storage", "shared-cache"],
        "config": entry.get("config") or [],
        "env": entry.get("env") or {},
        "ui": entry.get("ui") or {},
    }
    return manifest_mod.normalize_manifest(raw)


def install(repo_id: str, plugin_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """安装或更新插件，返回 (插件记录, 回滚信息)。"""
    repo = store.get_repository(repo_id)
    if not repo.get("enabled", True):
        raise InstallError("该插件仓库已停用")
    index = repositories.load_index(repo)
    entry = next((item for item in index["entries"] if item["id"] == plugin_id), None)
    if entry is None:
        raise InstallError("仓库索引中没有该插件")
    branch = index["branch"]

    plugin_dir = store.plugin_dir(plugin_id)
    plugin_dir.mkdir(parents=True, exist_ok=True)
    staging = plugin_dir / f".staging-{int(time.time())}-{os.getpid()}"
    store.remove_tree(staging)
    staging.mkdir(parents=True, exist_ok=True)
    try:
        if entry.get("release"):
            data = repositories.fetch_bytes(repo, branch, entry["release"], max_bytes=MAX_ARCHIVE_BYTES)
            checksum = str(entry.get("sha256") or "")
            if checksum and hashlib.sha256(data).hexdigest() != checksum:
                raise InstallError("插件发行包哈希校验失败")
            _extract_zip(data, staging)
            root, manifest_row = _find_manifest_root(staging)
        elif entry.get("legacy") is not True and entry.get("manifest"):
            manifest_raw = repositories.fetch_text(repo, branch, entry["manifest"])
            manifest_row = manifest_mod.normalize_manifest(json.loads(manifest_raw))
            store.write_manifest_file(staging / "manifest.json", manifest_row)
            if manifest_row["runtime"]["type"] != "http":
                if entry.get("files"):
                    _download_legacy_files(repo, branch, entry, staging)
                else:
                    _download_manifest_files(repo, branch, entry, manifest_row, staging)
            root = staging
        else:
            manifest_row = _synthesize_manifest(entry)
            store.write_manifest_file(staging / "manifest.json", manifest_row)
            _download_legacy_files(repo, branch, entry, staging)
            root = staging

        if manifest_row["id"] != plugin_id:
            raise InstallError(
                f"Manifest 插件 ID（{manifest_row['id']}）与索引（{plugin_id}）不一致"
            )
        version = manifest_row["version"]
        target = store.version_dir(plugin_id, version)

        # 保留当前版本用于回滚
        current = next(
            (item for item in store.list_plugins() if item.get("id") == plugin_id), None
        )
        previous: dict[str, Any] = {}
        if current and current.get("installed_version"):
            previous = {
                "version": current.get("installed_version"),
                "path": current.get("install_path"),
                "installed_at": current.get("installed_at"),
            }

        if target.exists():
            store.remove_tree(target)
        root.rename(target)
    except Exception:
        store.remove_tree(staging)
        raise

    existing = current or {}
    config = dict(existing.get("config") or {})
    defaults = _config_defaults(manifest_row["config"])
    config = {**defaults, **{k: str(v) for k, v in config.items()}}
    runtime = dict(manifest_row["runtime"])
    port = int(existing.get("runtime", {}).get("port") or runtime.get("port") or 0)
    if port:
        runtime["port"] = port

    row = store.upsert_plugin(
        {
            "id": plugin_id,
            "name": manifest_row["name"],
            "description": manifest_row["description"],
            "author": manifest_row["author"],
            "category": manifest_row["category"],
            "protocol": manifest_row.get("protocol") or "native",
            "api_version": manifest_row["api_version"],
            "capabilities": manifest_row["capabilities"],
            "endpoints": manifest_row["endpoints"],
            "runtime": runtime,
            "entrypoint": manifest_row["entrypoint"],
            "permissions": manifest_row["permissions"],
            "manifest_config": manifest_row["config"],
            "ui": manifest_row.get("ui") or {},
            "healthcheck": manifest_row["healthcheck"],
            "installed_version": version,
            "install_path": str(target),
            "previous_version": previous.get("version") or existing.get("previous_version") or "",
            "previous_path": previous.get("path") or existing.get("previous_path") or "",
            "source_repo": repo_id,
            "source_repo_url": repo.get("url"),
            "source_manifest": entry.get("manifest"),
            "source_release": entry.get("release") or "",
            "config": config,
            "widget_meta": None,
            "proxy": bool(existing.get("proxy")),
            "enabled": bool(existing.get("enabled", True)),
            "state": "installed" if existing.get("enabled", True) else "disabled",
            "error": "",
        }
    )
    return row, previous


def rollback(plugin_id: str) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    previous_version = str(row.get("previous_version") or "")
    previous_path = str(row.get("previous_path") or "")
    if not previous_version or not previous_path:
        raise InstallError("没有可回滚的版本")
    path = Path(previous_path)
    if not path.is_dir():
        raise InstallError("上一版本目录不存在，无法回滚")
    return store.patch_plugin(
        plugin_id,
        installed_version=previous_version,
        install_path=str(path),
        previous_version=str(row.get("installed_version") or ""),
        previous_path=str(row.get("install_path") or ""),
        state="installed" if row.get("enabled") else "disabled",
        error="",
    )


def remove_files(plugin_id: str, *, purge_data: bool = False) -> None:
    store.remove_tree(store.plugin_dir(plugin_id))
    if purge_data:
        store.remove_tree(store.PLUGIN_DATA_DIR / store.safe_id(plugin_id))
