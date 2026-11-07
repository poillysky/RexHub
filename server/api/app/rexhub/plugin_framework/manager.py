"""插件框架门面：仓库、市场、安装、生命周期、配置、能力调度。

路由层只调用这里，不直接碰存储或运行时，保证框架边界清晰。
"""


import time
from typing import Any

from app.rexhub import network_store
from app.rexhub.plugin_framework import (
    dispatcher,
    exporter,
    installer,
    manifest,
    repositories,
    runtime,
    stremio_adapter,
    store,
)


DEFAULT_ENDPOINTS = {
    "resource.search": "/plugin/resource/search",
    "playback.resolve": "/plugin/playback/resolve",
    "playback.extract": "/plugin/playback/extract",
    "playback.headers": "/plugin/playback/headers",
    "playback.stream": "/plugin/playback/stream",
    "subtitle.search": "/plugin/subtitle/search",
    "subtitle.download": "/plugin/subtitle/download",
    "danmaku.search": "/plugin/danmaku/search",
    "danmaku.fetch": "/plugin/danmaku/fetch",
    "metadata.movie": "/plugin/metadata/movie",
    "metadata.tv": "/plugin/metadata/tv",
    "cloud.search": "/plugin/cloud/search",
    "cloud.transfer": "/plugin/cloud/transfer",
}


def add_http_provider(payload: dict[str, Any]) -> dict[str, Any]:
    """直接登记一个外部 HTTP 插件（Provider），不下载代码。"""
    plugin_id = str(payload.get("id") or "").strip()
    capabilities = payload.get("capabilities") if isinstance(payload.get("capabilities"), list) else []
    endpoints = payload.get("endpoints") if isinstance(payload.get("endpoints"), dict) else {}
    for capability in capabilities:
        if capability not in endpoints and capability in DEFAULT_ENDPOINTS:
            endpoints[capability] = {"path": DEFAULT_ENDPOINTS[capability], "method": "POST"}
    raw = {
        "id": plugin_id,
        "name": payload.get("name") or plugin_id,
        "version": payload.get("version") or "1.0.0",
        "description": payload.get("description") or "",
        "author": payload.get("author") or "",
        "category": payload.get("category") or "tool",
        "api_version": payload.get("api_version") or "1.0",
        "capabilities": capabilities,
        "endpoints": endpoints,
        "runtime": {
            "type": "http",
            "engine": "node",
            "base_url": payload.get("base_url") or "",
            "headers": payload.get("headers") if isinstance(payload.get("headers"), dict) else {},
        },
        "permissions": payload.get("permissions") or ["network"],
        "config": payload.get("config") if isinstance(payload.get("config"), list) else [],
        "healthcheck": payload.get("healthcheck") or "/health",
    }
    normalized = manifest.normalize_manifest(raw)
    row = store.upsert_plugin(
        {
            "id": normalized["id"],
            "name": normalized["name"],
            "description": normalized["description"],
            "author": normalized["author"],
            "category": normalized["category"],
            "api_version": normalized["api_version"],
            "capabilities": normalized["capabilities"],
            "endpoints": normalized["endpoints"],
            "runtime": normalized["runtime"],
            "entrypoint": "",
            "permissions": normalized["permissions"],
            "manifest_config": normalized["config"],
            "healthcheck": normalized["healthcheck"],
            "installed_version": normalized["version"],
            "install_path": "",
            "source_repo": "custom",
            "config": {
                field["key"]: field.get("default", "")
                for field in normalized["config"]
                if field.get("default")
            },
            "enabled": True,
            "state": "installed",
            "error": "",
        }
    )
    return {"plugin": runtime.status(row), "health": dispatcher.health(row)}


def initialize() -> dict[str, Any]:
    """应用启动：迁移旧模块、注册默认仓库、后台拉起已启用插件。"""
    migrated = store.migrate_legacy()
    runtime.autostart()
    return migrated


def repositories_list() -> list[dict[str, Any]]:
    result = []
    for row in store.list_repositories():
        payload = dict(row)
        try:
            payload["owner"], payload["repo"] = repositories.parse_repo(
                str(row.get("url") or "")
            )
        except ValueError:
            payload["owner"] = payload["repo"] = ""
        result.append(payload)
    return result


def save_repository(payload: dict[str, Any]) -> dict[str, Any]:
    url = str(payload.get("url") or "").strip()
    if not url:
        raise ValueError("请填写插件仓库地址")
    owner, name = repositories.parse_repo(url)
    repo_id = str(payload.get("id") or "").strip()
    if not repo_id:
        repo_id = f"{owner}-{name}".lower().replace("_", "-")[:60]
    row = store.save_repository(
        {
            "id": repo_id,
            "name": str(payload.get("name") or f"{owner}/{name}"),
            "url": f"{owner}/{name}",
            "branch": str(payload.get("branch") or ""),
            "index_path": str(payload.get("index_path") or "repository.json"),
            "format": str(payload.get("format") or "repository"),
            "enabled": payload.get("enabled", True),
        }
    )
    repositories.clear_cache()
    return row


def delete_repository(repo_id: str) -> bool:
    deleted = store.delete_repository(repo_id)
    repositories.clear_cache()
    return deleted


def refresh_repository(repo_id: str) -> dict[str, Any]:
    repo = store.get_repository(repo_id)
    repositories.clear_cache()
    index = repositories.load_index(repo)
    return {
        "repository": repo,
        "name": index["name"],
        "branch": index["branch"],
        "fetched_at": index["fetched_at"],
        "entries": index["entries"],
    }


def market(repo_id: str = "") -> dict[str, Any]:
    """插件市场：未指定仓库时聚合所有已启用仓库。"""
    repos = [store.get_repository(repo_id)] if repo_id else [
        row for row in store.list_repositories() if row.get("enabled", True)
    ]
    installed = {row["id"]: row for row in store.list_plugins()}
    plugins: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    for repo in repos:
        try:
            index = repositories.load_index(repo)
        except (ValueError, RuntimeError) as exc:
            errors.append({"repository": repo["id"], "error": str(exc)})
            continue
        for entry in index["entries"]:
            current = installed.get(entry["id"])
            plugins.append(
                {
                    **entry,
                    "repository": repo["id"],
                    "repository_url": repo.get("url"),
                    "installed": bool(current),
                    "installed_version": (current or {}).get("installed_version", ""),
                    "enabled": bool((current or {}).get("enabled")),
                    "update_available": bool(
                        current
                        and current.get("source_repo") == repo["id"]
                        and entry["version"]
                        and entry["version"] != (current or {}).get("installed_version")
                    ),
                }
            )
    return {"plugins": plugins, "errors": errors, "fetched_at": int(time.time())}


def installed() -> list[dict[str, Any]]:
    proxy_available = bool(network_store.proxy_url())
    rows = []
    for row in store.list_plugins():
        info = runtime.status(row)
        info["proxy_available"] = proxy_available
        rows.append(info)
    return rows


def updates() -> list[dict[str, Any]]:
    """已安装插件中有新版本的条目。"""
    by_repo: dict[str, list[dict[str, Any]]] = {}
    for row in store.list_plugins():
        repo_id = str(row.get("source_repo") or "")
        if repo_id:
            by_repo.setdefault(repo_id, []).append(row)
    result: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    for repo_id, rows in by_repo.items():
        try:
            repo = store.get_repository(repo_id)
            index = repositories.load_index(repo)
        except (ValueError, RuntimeError) as exc:
            errors.append({"repository": repo_id, "error": str(exc)})
            continue
        entries = {item["id"]: item for item in index["entries"]}
        for row in rows:
            entry = entries.get(row["id"])
            if entry and entry["version"] != row.get("installed_version"):
                result.append(
                    {
                        "id": row["id"],
                        "name": row.get("name") or row["id"],
                        "repository": repo_id,
                        "installed_version": row.get("installed_version"),
                        "latest_version": entry["version"],
                        "category": row.get("category"),
                    }
                )
    return result


def update_all() -> dict[str, Any]:
    """批量更新所有有新版插件的条目，单条失败不影响其它插件。"""
    items = updates()
    updated: list[dict[str, Any]] = []
    failed: list[dict[str, str]] = []
    for item in items:
        plugin_id = str(item["id"])
        try:
            result = update(plugin_id)
        except (ValueError, RuntimeError) as exc:
            failed.append({"id": plugin_id, "error": str(exc)})
            continue
        if result.get("error"):
            failed.append({"id": plugin_id, "error": result["error"]})
        else:
            updated.append({"id": plugin_id, "version": item.get("latest_version")})
    return {"updated": updated, "failed": failed}


def _widget_meta(row: dict[str, Any]) -> dict[str, Any]:
    if str(row.get("protocol") or "") != "widget-js":
        return {}
    try:
        base = runtime.base_url(row)
        result = dispatcher._call(f"{base}/metadata", {}, "GET", 8, {})
        return result.get("data") if isinstance(result, dict) else {}
    except (RuntimeError, ValueError):
        return {}


def _refresh_widget_meta(plugin_id: str) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    meta = _widget_meta(row)
    if meta:
        store.patch_plugin(plugin_id, widget_meta=meta)
        row = store.get_plugin(plugin_id)
    return row


def _start_and_check(row: dict[str, Any]) -> tuple[dict[str, Any], str]:
    error = ""
    if row.get("enabled"):
        try:
            runtime.start(row)
            health = dispatcher.health(row)
            if not health.get("ok"):
                error = health.get("error") or f"健康检查失败（HTTP {health.get('status')}）"
            elif str(row.get("protocol") or "") == "widget-js":
                _refresh_widget_meta(str(row["id"]))
                row = store.get_plugin(str(row["id"]))
        except (RuntimeError, ValueError) as exc:
            error = str(exc)
    return runtime.status(row), error


def install(repo_id: str, plugin_id: str) -> dict[str, Any]:
    row, previous = installer.install(repo_id, plugin_id)
    if not row.get("enabled"):
        store.patch_plugin(plugin_id, enabled=True, state="installed")
        row = store.get_plugin(plugin_id)
    info, error = _start_and_check(row)
    if error and previous.get("path"):
        # 启动或健康检查失败：自动回滚到上一版本
        try:
            runtime.stop(plugin_id)
            store.patch_plugin(
                plugin_id,
                installed_version=previous.get("version"),
                install_path=previous.get("path"),
                previous_version="",
                previous_path="",
            )
            row = store.get_plugin(plugin_id)
            info = runtime.start(row)
            info["error"] = f"{error}（已回滚到 {previous.get('version')}）"
        except (RuntimeError, ValueError):
            store.patch_plugin(plugin_id, state="error", error=error)
    elif error:
        store.patch_plugin(plugin_id, state="error", error=error)
    return {"plugin": info, "error": info.get("error") or ""}


def update(plugin_id: str) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    repo_id = str(row.get("source_repo") or "")
    if not repo_id:
        raise ValueError("该插件不是从插件仓库安装的，无法更新")
    was_running = runtime.status(row).get("running")
    updated, previous = installer.install(repo_id, plugin_id)
    if not was_running:
        # 之前处于异常/未运行状态时，更新后立即启动，避免还要等看门狗重试。
        info, error = _start_and_check(updated)
        if error:
            store.patch_plugin(plugin_id, state="error", error=error)
        else:
            store.patch_plugin(plugin_id, state="installed", error="")
            info = runtime.status(store.get_plugin(plugin_id))
        return {"plugin": info, "error": error}
    try:
        runtime.restart(updated)
    except (RuntimeError, ValueError) as exc:
        if previous.get("path"):
            store.patch_plugin(
                plugin_id,
                installed_version=previous.get("version"),
                install_path=previous.get("path"),
                previous_version="",
                previous_path="",
            )
            restored = store.get_plugin(plugin_id)
            info = runtime.start(restored)
            return {"plugin": info, "error": f"更新失败：{exc}（已回滚）"}
        store.patch_plugin(plugin_id, state="error", error=str(exc))
        raise
    info = runtime.status(updated)
    health = dispatcher.health(updated)
    if not health.get("ok"):
        store.patch_plugin(plugin_id, state="error", error=health.get("error") or "健康检查失败")
        info = runtime.status(store.get_plugin(plugin_id))
        return {"plugin": info, "error": info.get("error") or ""}
    store.patch_plugin(plugin_id, state="installed", error="")
    if str(store.get_plugin(plugin_id).get("protocol") or "") == "widget-js":
        _refresh_widget_meta(plugin_id)
        info = runtime.status(store.get_plugin(plugin_id))
    return {"plugin": info, "error": ""}


def rollback(plugin_id: str) -> dict[str, Any]:
    runtime.stop(plugin_id)
    row = installer.rollback(plugin_id)
    info = runtime.start(row)
    if str(row.get("protocol") or "") == "widget-js":
        _refresh_widget_meta(plugin_id)
        info = runtime.status(store.get_plugin(plugin_id))
    return {"plugin": info, "error": ""}


def enable(plugin_id: str) -> dict[str, Any]:
    store.patch_plugin(plugin_id, enabled=True, state="installed", error="")
    row = store.get_plugin(plugin_id)
    info, error = _start_and_check(row)
    if error:
        store.patch_plugin(plugin_id, state="error", error=error)
    return {"plugin": info, "error": error}


def disable(plugin_id: str) -> dict[str, Any]:
    store.patch_plugin(plugin_id, enabled=False, state="disabled", error="")
    runtime.stop(plugin_id)
    return {"plugin": runtime.status(store.get_plugin(plugin_id)), "error": ""}


def restart(plugin_id: str) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    info, error = _start_and_check(row)
    if error:
        store.patch_plugin(plugin_id, state="error", error=error)
    return {"plugin": info, "error": error}


def uninstall(plugin_id: str, *, purge_data: bool = False) -> dict[str, Any]:
    runtime.stop(plugin_id)
    installer.remove_files(plugin_id, purge_data=purge_data)
    store.delete_plugin(plugin_id)
    return {"ok": True, "data_kept": not purge_data}


def save_config(plugin_id: str, config: dict[str, Any]) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    clean = {str(key): str(value) for key, value in config.items()}
    store.patch_plugin(plugin_id, config=clean)
    if runtime.status(row).get("running"):
        row = store.get_plugin(plugin_id)
        info = runtime.restart(row)
        return {"plugin": info, "restarted": True}
    return {"plugin": runtime.status(store.get_plugin(plugin_id)), "restarted": False}


def set_proxy(plugin_id: str, enabled: bool) -> dict[str, Any]:
    """单插件运行时代理开关：只影响插件自身出站请求，不改全局网络配置。"""
    store.get_plugin(plugin_id)
    store.patch_plugin(plugin_id, proxy=bool(enabled))
    row = store.get_plugin(plugin_id)
    info = runtime.status(row)
    if info.get("running"):
        try:
            info = runtime.restart(row)
        except (RuntimeError, ValueError) as exc:
            store.patch_plugin(plugin_id, state="error", error=str(exc))
            return {
                "plugin": runtime.status(store.get_plugin(plugin_id)),
                "restarted": True,
                "error": str(exc),
            }
        return {"plugin": info, "restarted": True, "error": ""}
    return {"plugin": info, "restarted": False, "error": ""}


def set_shortdrama_visible(plugin_id: str, enabled: bool) -> dict[str, Any]:
    """是否在 App 短剧页展示该插件的入口卡片。"""
    row = store.get_plugin(plugin_id)
    if str(row.get("category") or "") != "shortdrama":
        raise ValueError("只有短剧插件可以显示在短剧页")
    store.patch_plugin(plugin_id, show_in_drama=bool(enabled))
    return {"plugin": runtime.status(store.get_plugin(plugin_id)), "enabled": bool(enabled)}


def config_schema(plugin_id: str) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    fields = row.get("manifest_config") if isinstance(row.get("manifest_config"), list) else []
    if not fields:
        manifest_file = store.install_path(row) / "manifest.json"
        try:
            import json

            raw = json.loads(manifest_file.read_text("utf-8"))
            fields = manifest.normalize_manifest(raw)["config"]
        except (OSError, ValueError):
            fields = []
    return {"config": row.get("config") or {}, "fields": fields}


def capabilities() -> list[dict[str, Any]]:
    result = []
    for capability in manifest.CAPABILITIES:
        providers = dispatcher.providers(capability)
        result.append(
            {
                "capability": capability,
                "providers": providers,
                "available": bool(providers),
            }
        )
    return result


def dispatch(capability: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    return dispatcher.dispatch(capability, payload or {})


def _widget_call(plugin_id: str, endpoint: str, payload: dict[str, Any], timeout: int = 30) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    if str(row.get("protocol") or "") != "widget-js":
        raise ValueError("该插件不是 widget-js 协议")
    if not row.get("enabled"):
        raise ValueError("插件已停用")
    base = runtime.base_url(row)
    result = dispatcher._call(f"{base}{endpoint}", payload, "POST", timeout, {})
    if not isinstance(result, dict):
        raise RuntimeError("插件返回格式错误")
    return result


def execute(plugin_id: str, module_id: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    if plugin_id.startswith(stremio_adapter.PREFIX):
        return stremio_adapter.execute(plugin_id, module_id, params or {})
    return _widget_call(plugin_id, "/execute", {"moduleId": module_id, "params": params or {}})


def search(plugin_id: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    return _widget_call(plugin_id, "/search", {"params": params or {}})


def detail(plugin_id: str, link: str) -> dict[str, Any]:
    return _widget_call(plugin_id, "/detail", {"link": link})


def resource(plugin_id: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    return _widget_call(plugin_id, "/resource", {"params": params or {}}, timeout=35)


def subtitle(plugin_id: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    return _widget_call(plugin_id, "/subtitle", {"params": params or {}}, timeout=35)


def subtitle_archive(plugin_id: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    return _widget_call(plugin_id, "/subtitle/archive", {"params": params or {}}, timeout=35)


def danmu(plugin_id: str, stage: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    mapping = {
        "search": "/danmu/search",
        "detail": "/danmu/detail",
        "comments": "/danmu/comments",
        "segment": "/danmu/segment",
    }
    endpoint = mapping.get(stage)
    if not endpoint:
        raise ValueError("不支持的弹幕阶段")
    return _widget_call(plugin_id, endpoint, {"params": params or {}})


def plugin_catalog() -> list[dict[str, Any]]:
    """供 iOS/Web 的统一插件列表：只暴露可调度信息，不暴露安装路径。"""
    result = []
    for row in store.list_plugins():
        if not row.get("enabled"):
            continue
        info = runtime.status(row)
        widget = row.get("widget_meta") if isinstance(row.get("widget_meta"), dict) else {}
        result.append(
            {
                "id": row["id"],
                "name": row.get("name") or row["id"],
                "version": row.get("installed_version") or row.get("version") or "",
                "category": row.get("category") or "",
                "protocol": row.get("protocol") or "native",
                "runtime": (row.get("runtime") or {}).get("type") or "isolated",
                "capabilities": row.get("capabilities") or [],
                "running": bool(info.get("running")),
                "modules": widget.get("modules") or [],
                "search": widget.get("search") or None,
            }
        )
    try:
        result.extend(stremio_adapter.list_plugins())
    except (RuntimeError, ValueError, OSError):
        pass
    return result


def plugin_detail(plugin_id: str) -> dict[str, Any]:
    if plugin_id.startswith(stremio_adapter.PREFIX):
        return stremio_adapter.detail(plugin_id)
    row = store.get_plugin(plugin_id)
    info = runtime.status(row)
    widget = row.get("widget_meta") if isinstance(row.get("widget_meta"), dict) else {}
    return {
        "id": row["id"],
        "name": row.get("name") or row["id"],
        "description": row.get("description") or "",
        "version": row.get("installed_version") or row.get("version") or "",
        "category": row.get("category") or "",
        "protocol": row.get("protocol") or "native",
        "runtime": row.get("runtime") or {},
        "capabilities": row.get("capabilities") or [],
        "permissions": row.get("permissions") or [],
        "enabled": bool(row.get("enabled")),
        "running": bool(info.get("running")),
        "proxy": bool(row.get("proxy")),
        "proxy_available": bool(network_store.proxy_url()),
        "show_in_drama": bool(row.get("show_in_drama")),
        "ui": row.get("ui") if isinstance(row.get("ui"), dict) else {},
        "modules": widget.get("modules") or [],
        "search": widget.get("search") or None,
        "detailCacheDuration": widget.get("detailCacheDuration") or 0,
    }


def export_js(plugin_id: str, *, base_url: str = "") -> dict[str, Any]:
    return exporter.export_plugin(plugin_id, base_url=base_url)


def logs(plugin_id: str, limit: int = 120) -> dict[str, Any]:
    store.get_plugin(plugin_id)
    return {"id": plugin_id, "lines": runtime.logs(plugin_id, limit)}


def health(plugin_id: str) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    return dispatcher.health(row)
