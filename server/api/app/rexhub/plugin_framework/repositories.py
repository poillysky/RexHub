"""多 GitHub 插件仓库：索引拉取、文件下载与仓库地址解析。

仓库索引支持两种格式，框架自动识别：

1. 新格式 ``repository.json``：

    {"name": "…", "repository_id": "…", "version": 1, "plugins": [ … ]}

2. 兼容旧格式 ``modules.json``：``{"modules": [ … ]}`` 或直接数组。

下载优先使用 GitHub Contents API（配置 Token 时可读私有仓库），否则走
raw.githubusercontent.com；两者都经过「网络管理」的出站代理与 GitHub 镜像。
"""


import ipaddress
import json
import re
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

from app.rexhub import network_store
from app.rexhub.plugin_framework import manifest as manifest_mod

FETCH_TIMEOUT = 20
MAX_INDEX_BYTES = 2 * 1024 * 1024
MAX_FILE_BYTES = 16 * 1024 * 1024
USER_AGENT = "RexHub-PluginFramework/1.0"
_OWNER_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")

_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
_CACHE_TTL = 60


def _ip_is_private(value: str) -> bool:
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    return bool(
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    )


def _assert_public_url(url: str) -> None:
    """插件仓库/CDN 下载只允许公网 http(s)，避免经仓库索引访问内网。"""
    parsed = urlparse(str(url or ""))
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("插件下载地址必须是 http(s)")
    host = parsed.hostname
    if _ip_is_private(host):
        raise ValueError("插件下载地址不允许指向内网")
    try:
        infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80))
    except OSError as exc:
        raise ValueError("插件下载地址无法解析") from exc
    for info in infos:
        address = str(info[4][0]).split("%", 1)[0]
        if _ip_is_private(address):
            raise ValueError("插件下载地址解析到内网，已拒绝")


def parse_repo(value: str) -> tuple[str, str]:
    raw = str(value or "").strip()
    raw = re.sub(r"^https?://(www\.)?github\.com/", "", raw, flags=re.I)
    raw = raw.split("?", 1)[0].split("#", 1)[0].rstrip("/")
    parts = [part for part in raw.split("/") if part]
    if len(parts) < 2:
        raise ValueError("请填写 GitHub 仓库地址，例如 owner/repo")
    owner, name = parts[0], parts[1]
    if name.endswith(".git"):
        name = name[:-4]
    if not _OWNER_RE.match(owner) or not _OWNER_RE.match(name):
        raise ValueError("GitHub 仓库地址不合法")
    return owner, name


def repo_owner_name(row: dict[str, Any]) -> tuple[str, str]:
    try:
        return parse_repo(str(row.get("url") or ""))
    except ValueError as exc:
        raise ValueError("插件仓库地址不合法") from exc


def _file_url(owner: str, name: str, branch: str, path: str) -> str:
    encoded = quote(path, safe="/")
    if network_store.github_token():
        return (
            f"{network_store.github_api()}/repos/{owner}/{name}"
            f"/contents/{encoded}?ref={quote(branch, safe='')}"
        )
    return (
        f"https://raw.githubusercontent.com/{owner}/{name}"
        f"/{quote(branch, safe='')}/{encoded}"
    )


def _request(url: str, *, max_bytes: int) -> bytes:
    is_github_api = url.startswith(network_store.github_api())
    headers = {"User-Agent": USER_AGENT}
    if is_github_api:
        headers["Accept"] = "application/vnd.github.raw+json"
        token = network_store.github_token()
        if token:
            # 只对 GitHub API 发送令牌，避免把令牌带到第三方 CDN
            headers["Authorization"] = f"Bearer {token}"
    elif not url.startswith("https://raw.githubusercontent.com/"):
        _assert_public_url(url)
    request = urllib.request.Request(
        network_store.rewrite_github(url), headers=headers, method="GET"
    )
    try:
        with network_store.open_plugin_url(request, FETCH_TIMEOUT) as response:
            final_url = str(getattr(response, "geturl", lambda: url)() or url)
            if not final_url.startswith(network_store.github_api()) and not final_url.startswith(
                "https://raw.githubusercontent.com/"
            ):
                _assert_public_url(final_url)
            data = response.read(max_bytes + 1)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise ValueError("仓库或文件不存在，请检查地址、分支与索引路径") from exc
        raise RuntimeError(f"仓库请求失败（HTTP {exc.code}）") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError("无法连接 GitHub，请检查网络或代理") from exc
    if len(data) > max_bytes:
        raise ValueError("文件超过大小限制")
    return data


def _branches(row: dict[str, Any]) -> list[str]:
    branch = str(row.get("branch") or "").strip()
    return [branch] if branch else ["main", "master"]


def fetch_text(row: dict[str, Any], branch: str, path: str, *, max_bytes: int = MAX_FILE_BYTES) -> str:
    owner, name = repo_owner_name(row)
    raw = _request(_file_url(owner, name, branch, path), max_bytes=max_bytes)
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"文件不是 UTF-8 文本：{path}") from exc


def fetch_bytes(row: dict[str, Any], branch: str, path: str, *, max_bytes: int = MAX_FILE_BYTES) -> bytes:
    owner, name = repo_owner_name(row)
    return _request(_file_url(owner, name, branch, path), max_bytes=max_bytes)


def fetch_absolute(url: str, *, max_bytes: int = MAX_FILE_BYTES) -> bytes:
    return _request(str(url), max_bytes=max_bytes)


def _normalize_fwd_entry(raw: dict[str, Any]) -> dict[str, Any]:
    """ForwardWidgets 索引条目：CDN 地址 + 元数据。"""
    source = (
        raw.get("cdnUrl")
        or raw.get("downloadUrl")
        or raw.get("url")
        or raw.get("src")
        or ""
    )
    return manifest_mod.normalize_repository_entry(
        {
            "id": raw.get("id"),
            "name": raw.get("title") or raw.get("name") or raw.get("id"),
            "version": raw.get("version") or "0.0.0",
            "description": raw.get("description") or "",
            "author": raw.get("author") or "",
            "category": raw.get("category") or "tool",
            "protocol": "widget-js",
            "entry": source,
            "sha256": raw.get("sha256") or "",
        }
    )


def _normalize_modules_entry(raw: dict[str, Any]) -> dict[str, Any]:
    """旧版 modules.json 条目 → 统一仓库条目。"""
    plugin_id = str(raw.get("id") or "").strip()
    if not plugin_id:
        stem = Path(str(raw.get("file") or raw.get("path") or "plugin")).stem
        plugin_id = f"repo.{re.sub(r'[^a-z0-9-]+', '-', stem.lower()).strip('-')[:48]}"
    name = raw.get("title") or raw.get("name") or plugin_id
    category = raw.get("category") or ""
    if not category:
        label = f"{plugin_id} {name}".lower()
        category = "shortdrama" if ("hongguo" in label or "红果" in label or "短剧" in label) else "tool"
    entry = manifest_mod.normalize_repository_entry(
        {
            "id": plugin_id,
            "name": name,
            "version": raw.get("version") or "0.0.0",
            "description": raw.get("description") or "",
            "author": raw.get("author") or "",
            "category": category,
            "manifest": raw.get("manifest") or "",
            "release": raw.get("release") or "",
            "sha256": raw.get("sha256") or "",
        }
    )
    files = raw.get("files")
    if isinstance(files, list) and files:
        entry["files"] = files[:40]
    elif raw.get("file") or raw.get("path"):
        entry["files"] = [{"file": raw.get("file") or raw.get("path"), "target": "module.mjs"}]
    entry["legacy"] = True
    entry["env"] = raw.get("env") if isinstance(raw.get("env"), dict) else {}
    entry["config"] = raw.get("config") if isinstance(raw.get("config"), list) else []
    entry["capabilities"] = raw.get("capabilities") if isinstance(raw.get("capabilities"), list) else []
    entry["endpoints"] = raw.get("endpoints") if isinstance(raw.get("endpoints"), dict) else {}
    entry["runtime"] = raw.get("runtime") if isinstance(raw.get("runtime"), dict) else {}
    entry["ui"] = raw.get("ui") if isinstance(raw.get("ui"), dict) else {}
    return entry


def load_index(row: dict[str, Any]) -> dict[str, Any]:
    """拉取并规范化仓库索引；返回 entries 与实际使用的分支。"""
    cache_key = f"{row.get('id')}|{row.get('updated_at')}|{row.get('branch')}"
    hit = _CACHE.get(cache_key)
    if hit and time.time() - hit[0] < _CACHE_TTL:
        return hit[1]
    index_path = str(row.get("index_path") or "repository.json")
    last_error = "仓库索引不存在"
    for branch in _branches(row):
        try:
            text = fetch_text(row, branch, index_path, max_bytes=MAX_INDEX_BYTES)
            data = json.loads(text)
        except ValueError as exc:
            last_error = str(exc)
            continue
        except json.JSONDecodeError as exc:
            raise ValueError(f"仓库索引不是有效 JSON：{exc}") from exc
        if isinstance(data, dict) and isinstance(data.get("plugins"), list):
            raw_entries = data["plugins"]
            repo_name = str(data.get("name") or row.get("name") or "")
            repository_id = str(data.get("repository_id") or row.get("id") or "")
        elif isinstance(data, dict) and isinstance(data.get("modules"), list):
            raw_entries = data["modules"]
            repo_name = str(data.get("name") or row.get("name") or "")
            repository_id = str(data.get("repository_id") or row.get("id") or "")
        elif isinstance(data, dict) and isinstance(data.get("widgets"), list):
            raw_entries = data["widgets"]
            repo_name = str(data.get("name") or row.get("name") or "")
            repository_id = str(data.get("repository_id") or row.get("id") or "")
        elif isinstance(data, list):
            raw_entries = data
            repo_name = str(row.get("name") or "")
            repository_id = str(row.get("id") or "")
        else:
            raise ValueError("仓库索引格式错误：需要 plugins/modules/widgets 数组")
        entries: list[dict[str, Any]] = []
        for item in raw_entries:
            if not isinstance(item, dict):
                continue
            if item.get("cdnUrl") or item.get("downloadUrl") or (
                item.get("url") and item.get("id") and not item.get("manifest")
            ):
                entry = _normalize_fwd_entry(item)
            elif isinstance(item.get("files"), list) or item.get("file") or item.get("path"):
                entry = _normalize_modules_entry(item)
            else:
                entry = manifest_mod.normalize_repository_entry(item)
            entries.append(entry)
        result = {
            "ok": True,
            "error": "",
            "name": repo_name,
            "repository_id": repository_id,
            "branch": branch,
            "fetched_at": int(time.time()),
            "entries": entries,
        }
        _CACHE[cache_key] = (time.time(), result)
        return result
    raise ValueError(last_error)


def clear_cache() -> None:
    _CACHE.clear()
