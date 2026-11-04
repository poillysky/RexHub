"""把现有明文 ForwardWidget 插件桥接成 Stremio Addon。

插件仍按 WidgetMetadata 格式保存，服务端用 Bun 子进程执行插件函数，
再按 Stremio Addon Protocol 输出 manifest / catalog / meta / stream。
订阅里的 REXENC 密文模块无法执行，这里直接跳过。
"""


import asyncio
import json
import os
import re
import shutil
import time
from pathlib import Path
from typing import Any

from app.rexhub import plugins_store

RUNNER_PATH = Path(__file__).resolve().parent / "runtime" / "plugin_runner.mjs"
RUN_TIMEOUT = 30
CACHE_TTL = 60
MAX_CONCURRENT_RUNS = 4

_SEMAPHORE: asyncio.Semaphore | None = None
_CACHE: dict[tuple[str, str, str, str], tuple[float, Any]] = {}
_CACHE_LOCK: asyncio.Lock | None = None

ENCRYPTED_HEAD = ("FWENC", "REXENC")


def _semaphore() -> asyncio.Semaphore:
    global _SEMAPHORE
    if _SEMAPHORE is None:
        _SEMAPHORE = asyncio.Semaphore(MAX_CONCURRENT_RUNS)
    return _SEMAPHORE


def _cache_lock() -> asyncio.Lock:
    global _CACHE_LOCK
    if _CACHE_LOCK is None:
        _CACHE_LOCK = asyncio.Lock()
    return _CACHE_LOCK


def _bun_path() -> str:
    configured = str(os.environ.get("REXHUB_BUN") or "").strip()
    if configured:
        return configured
    found = shutil.which("bun")
    if found:
        return found
    fallback = Path.home() / ".bun" / "bin" / "bun"
    if fallback.is_file():
        return str(fallback)
    raise ValueError("未找到 Bun 可执行文件，可通过 REXHUB_BUN 指定路径")


def _slug(plugin_id: str) -> str:
    return plugins_store.plugin_slug(str(plugin_id or ""))


def _is_plain_plugin(plugin: dict[str, Any]) -> bool:
    analysis = plugin.get("analysis")
    if not isinstance(analysis, dict) or not analysis.get("ok"):
        return False
    if analysis.get("encrypted"):
        return False
    source = str(plugin.get("source") or "").strip()
    if not source:
        return False
    return not source[:16].upper().startswith(ENCRYPTED_HEAD)


def _enabled_plugins() -> list[dict[str, Any]]:
    return [
        row
        for row in plugins_store._read()["plugins"]
        if row.get("enabled", True) and _is_plain_plugin(row)
    ]


def _find_plugin(plugin_id: str) -> dict[str, Any] | None:
    target = str(plugin_id or "").strip()
    if not target:
        return None
    for row in _enabled_plugins():
        if str(row.get("id")) == target or _slug(str(row.get("id"))) == target:
            return row
    return None


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def plugin_proxy(plugin: dict[str, Any]) -> str:
    """插件在管理台勾选了代理时，返回可用于 Fetch 的代理地址。"""

    if not plugin.get("proxy_enabled"):
        return ""
    proxy = _text(plugin.get("proxy_url"))
    return proxy if proxy.startswith(("http://", "https://")) else ""


def _meta_prefix(plugin: dict[str, Any]) -> str:
    return f"rexhub.{_slug(str(plugin.get('id')))}."


def _global_params(plugin: dict[str, Any]) -> dict[str, Any]:
    """插件声明的全局参数默认值，管理台填写的接口地址 / Key 覆盖同名项。"""
    analysis = plugin.get("analysis") or {}
    metadata = analysis.get("metadata") or {}
    params: dict[str, Any] = {}
    names: list[str] = []
    for item in metadata.get("global_params") or []:
        if not isinstance(item, dict):
            continue
        name = _text(item.get("name"))
        if not name:
            continue
        names.append(name)
        params[name] = item.get("default")

    api_url = _text(plugin.get("api_url"))
    if api_url:
        target = next((name for name in names if name.lower() in {"apibase", "apiurl", "baseurl", "base"}), "")
        if target:
            params[target] = api_url

    api_key = _text(plugin.get("api_key"))
    if api_key:
        target = next(
            (name for name in names if name.lower() in {"apikey", "api_key", "key", "token"}),
            "",
        )
        if target:
            params[target] = api_key
    return params


def _merge_params(plugin: dict[str, Any], extra: dict[str, Any]) -> dict[str, Any]:
    params = _global_params(plugin)
    for key, value in (extra or {}).items():
        if value is not None:
            params[key] = value
    return params


def _has_function(plugin: dict[str, Any], name: str) -> bool:
    analysis = plugin.get("analysis") or {}
    if name in (analysis.get("functions") or {}):
        return True
    source = str(plugin.get("source") or "")
    return re.search(rf"(?:async\s+)?function\s+{re.escape(name)}\s*\(", source) is not None


def _catalog_modules(plugin: dict[str, Any]) -> list[dict[str, Any]]:
    analysis = plugin.get("analysis") or {}
    modules = [item for item in analysis.get("modules") or [] if isinstance(item, dict)]
    return [item for item in modules if _text(item.get("function")) != "loadResource"]


def build_manifest(plugin: dict[str, Any]) -> dict[str, Any]:
    analysis = plugin.get("analysis") or {}
    metadata = analysis.get("metadata") or {}
    slug = _slug(str(plugin.get("id")))
    prefix = f"rexhub.{slug}."

    catalogs = []
    for module in _catalog_modules(plugin):
        catalog_id = _text(module.get("id")) or _text(module.get("function"))
        if not catalog_id:
            continue
        catalogs.append(
            {
                "type": "series",
                "id": catalog_id,
                "name": _text(module.get("title")) or catalog_id,
                "extra": [
                    {"name": "search", "isRequired": False},
                    {"name": "skip", "isRequired": False},
                ],
            }
        )

    resources = [
        {"name": "catalog", "types": ["series"], "idPrefixes": [prefix]},
        {"name": "meta", "types": ["series"], "idPrefixes": [prefix]},
        {"name": "stream", "types": ["series"], "idPrefixes": [prefix]},
    ]
    return {
        "id": f"org.rexhub.{slug[7:] if slug.startswith('rexhub.') else slug}",
        "version": _text(plugin.get("version")) or _text(metadata.get("version")) or "1.0.0",
        "name": _text(plugin.get("title_override"))
        or _text(plugin.get("title"))
        or _text(metadata.get("title"))
        or str(plugin.get("id")),
        "description": _text(plugin.get("description_override"))
        or _text(plugin.get("description"))
        or _text(metadata.get("description")),
        "types": ["series"],
        "idPrefixes": [prefix],
        "catalogs": catalogs,
        "resources": resources,
    }


def _pick_cover(item: dict[str, Any]) -> str:
    for key in ("cover", "coverUrl", "poster", "posterPath", "image", "backdropPath"):
        value = _text(item.get(key))
        if value:
            return value
    return ""


def _meta_id(plugin: dict[str, Any], content_id: str) -> str:
    return _meta_prefix(plugin) + _text(content_id)


def _content_from_meta(plugin: dict[str, Any], meta_id: str) -> str:
    text = _text(meta_id)
    prefix = _meta_prefix(plugin)
    return text[len(prefix) :] if text.startswith(prefix) else text


def _parse_video_id(plugin: dict[str, Any], video_id: str) -> tuple[str, int, int]:
    text = _text(video_id)
    prefix = _meta_prefix(plugin)
    if text.startswith(prefix):
        text = text[len(prefix) :]
    parts = text.rsplit(":", 2)
    if len(parts) == 3 and parts[1].isdigit() and parts[2].isdigit():
        return parts[0], int(parts[1]), int(parts[2])
    return text, 1, 0


async def catalog(plugin_id: str, catalog_id: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    plugin = _find_plugin(plugin_id)
    if plugin is None:
        raise ValueError("插件不存在或未启用")
    extra = extra or {}
    analysis = plugin.get("analysis") or {}
    modules = _catalog_modules(plugin)
    module = next(
        (
            item
            for item in modules
            if _text(item.get("id")) == _text(catalog_id)
            or _text(item.get("function")) == _text(catalog_id)
        ),
        None,
    )
    if module is None and modules:
        module = modules[0]

    keyword = _text(extra.get("search") or extra.get("keyword"))
    search = analysis.get("search") or {}
    if keyword and _text(search.get("function")):
        function = _text(search.get("function"))
        params = _merge_params(plugin, {"keyword": keyword, "page": 1})
    elif module is not None and _text(module.get("function")):
        function = _text(module.get("function"))
        params = _merge_params(plugin, {"page": 1})
    else:
        raise ValueError("插件没有可用的目录函数")

    result = await _call_plugin(plugin, function, params)
    metas: list[dict[str, Any]] = []
    for item in result if isinstance(result, list) else []:
        if not isinstance(item, dict):
            continue
        content_id = _text(item.get("id"))
        title = _text(item.get("title") or item.get("name"))
        if not content_id or not title:
            continue
        metas.append(
            {
                "id": _meta_id(plugin, content_id),
                "type": "series",
                "name": title,
                "poster": _pick_cover(item),
                "description": _text(item.get("description")),
            }
        )
    return {"metas": metas}


async def meta(plugin_id: str, meta_id: str) -> dict[str, Any]:
    plugin = _find_plugin(plugin_id)
    if plugin is None:
        raise ValueError("插件不存在或未启用")
    content_id = _content_from_meta(plugin, meta_id)
    fallback = {
        "id": _meta_id(plugin, content_id),
        "type": "series",
        "name": content_id,
        "videos": [],
    }
    if not content_id or not _has_function(plugin, "loadDetail"):
        return fallback

    detail = await _call_plugin(plugin, "loadDetail", _merge_params(plugin, {"id": content_id}))
    if not isinstance(detail, dict):
        return fallback

    videos: list[dict[str, Any]] = []
    for index, entry in enumerate(detail.get("videos") or detail.get("episodes") or []):
        if not isinstance(entry, dict):
            continue
        try:
            episode = int(entry.get("episode") or entry.get("ep") or index + 1)
        except (TypeError, ValueError):
            episode = index + 1
        if episode < 1:
            continue
        videos.append(
            {
                "id": _meta_id(plugin, content_id) + f":1:{episode}",
                "season": 1,
                "episode": episode,
                "title": _text(entry.get("title") or entry.get("name")) or f"第{episode}集",
            }
        )

    result = {
        "id": _meta_id(plugin, content_id),
        "type": "series",
        "name": _text(detail.get("title") or detail.get("name")) or content_id,
        "poster": _pick_cover(detail),
        "description": _text(detail.get("description")),
        "videos": videos,
    }
    background = _text(detail.get("background"))
    if background:
        result["background"] = background
    return result


async def stream(plugin_id: str, video_id: str) -> dict[str, Any]:
    plugin = _find_plugin(plugin_id)
    if plugin is None:
        raise ValueError("插件不存在或未启用")
    analysis = plugin.get("analysis") or {}
    content_id, _season, episode = _parse_video_id(plugin, video_id)
    modules = [item for item in analysis.get("modules") or [] if isinstance(item, dict)]
    module = next((item for item in modules if _text(item.get("function")) == "loadResource"), None)
    function = _text(module.get("function")) if module else ""

    result = await _call_plugin(
        plugin,
        function or "loadResource",
        _merge_params(plugin, {"id": content_id, "episode": episode}),
    )
    streams: list[dict[str, Any]] = []
    for item in result if isinstance(result, list) else []:
        if not isinstance(item, dict):
            continue
        url = _text(item.get("url"))
        if not re.match(r"^https?://", url, re.I):
            continue
        name = _text(item.get("name")) or "播放"
        streams.append(
            {
                "name": name,
                "url": url,
                "behaviorHints": {"notWebReady": False},
            }
        )
    return {"streams": streams}


async def _call_plugin(plugin: dict[str, Any], function_name: str, params: dict[str, Any]) -> Any:
    plugin_id = str(plugin.get("id"))
    proxy = plugin_proxy(plugin)
    cache_key = (
        plugin_id,
        function_name,
        json.dumps(params, sort_keys=True, ensure_ascii=False, default=str),
        proxy,
    )
    cache = _cache_lock()
    now = time.monotonic()
    async with cache:
        entry = _CACHE.get(cache_key)
        if entry and entry[0] > now:
            return entry[1]

    payload = json.dumps(
        {
            "source": str(plugin.get("source") or ""),
            "functionName": function_name,
            "params": params,
            "proxy": proxy,
        },
        ensure_ascii=False,
    ).encode("utf-8")

    bun = _bun_path()
    async with _semaphore():
        try:
            process = await asyncio.create_subprocess_exec(
                bun,
                str(RUNNER_PATH),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except OSError as exc:
            raise ValueError("无法启动插件运行时") from exc
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(payload), timeout=RUN_TIMEOUT)
        except asyncio.TimeoutError as exc:
            process.kill()
            await process.wait()
            raise ValueError("插件执行超时") from exc

    text = stdout.decode("utf-8", "replace").strip()
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        reason = stderr.decode("utf-8", "replace").strip()[-300:]
        raise ValueError(reason or "插件运行时没有返回结果")
    try:
        result = json.loads(lines[-1])
    except ValueError as exc:
        raise ValueError("插件运行时返回了无效数据") from exc
    if not isinstance(result, dict) or not result.get("ok"):
        reason = result.get("error") if isinstance(result, dict) else ""
        raise ValueError(str(reason or "插件执行失败"))

    value = result.get("result")
    async with cache:
        _CACHE[cache_key] = (time.monotonic() + CACHE_TTL, value)
    return value
