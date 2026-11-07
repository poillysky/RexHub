"""插件 Manifest 协议：插件包的唯一描述格式。

每个插件目录根部的 ``manifest.json`` 使用下面的结构，框架不认其它安装方式：

    {
      "id": "playback.hongguo",
      "name": "红果短剧",
      "version": "4.0.0",
      "description": "…",
      "author": "RexHub",
      "category": "playback",
      "api_version": "1.0",
      "capabilities": ["playback.stream", "playback.extract"],
      "runtime": {"type": "isolated", "engine": "node", "entrypoint": "module.mjs"},
      "endpoints": {"playback.stream": "/v1/episodes/{id}/stream"},
      "permissions": ["network"],
      "config": [{"key": "COOKIE", "title": "Cookie", "type": "password"}]
    }
"""


import re
from typing import Any

API_VERSION = "1.0"
SUPPORTED_API_VERSIONS = ("1.0",)

CATEGORIES = (
    "video",
    "shortdrama",
    "studio",
    "subtitle",
    "danmaku",
    "other",
    "resource",
    "playback",
    "metadata",
    "cloud",
    "tool",
)
CAPABILITIES = (
    "resource.search",
    "playback.resolve",
    "playback.extract",
    "playback.headers",
    "playback.stream",
    "subtitle.search",
    "subtitle.download",
    "danmaku.search",
    "danmaku.detail",
    "danmaku.fetch",
    "metadata.movie",
    "metadata.tv",
    "cloud.search",
    "cloud.transfer",
    "shortdrama.ranks",
    "shortdrama.catalog",
    "shortdrama.search",
    "shortdrama.detail",
    "shortdrama.stream",
)
RUNTIME_TYPES = ("http", "shared", "isolated")
ENGINES = ("node", "python", "widget-js", "process")
PROTOCOLS = ("native", "widget-js", "stremio", "process")
PERMISSIONS = ("network", "storage", "browser", "gpu", "shared-cache")

_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,240}$")
_HOST_RE = re.compile(r"^https?://[^\s]{1,300}$")
_ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,79}$")
CONFIG_TYPES = ("text", "password", "number", "boolean", "select", "textarea")


class ManifestError(ValueError):
    """Manifest 或仓库索引不合法。"""


def _text(value: object, limit: int = 300) -> str:
    return str(value or "").strip()[:limit]


def _rel_path(value: object, label: str) -> str:
    text = _text(value, 240).lstrip("/")
    if not text or ".." in text.split("/") or not _PATH_RE.match(text):
        raise ManifestError(f"{label}不合法：{value}")
    return text


def _clean_config(value: object) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    fields: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in value[:60]:
        if not isinstance(raw, dict):
            continue
        key = _text(raw.get("key"), 80)
        if not key or key in seen or not _ENV_RE.match(key):
            continue
        seen.add(key)
        field_type = _text(raw.get("type"), 20)
        if field_type not in CONFIG_TYPES:
            field_type = "text"
        options = []
        for option in raw.get("options") or []:
            if isinstance(option, dict):
                option_value = _text(option.get("value"), 120)
                option_label = _text(option.get("label"), 120) or option_value
            else:
                option_value = _text(option, 120)
                option_label = option_value
            if option_value:
                options.append({"value": option_value, "label": option_label})
        default = raw.get("default")
        fields.append(
            {
                "key": key,
                "title": _text(raw.get("title"), 120) or key,
                "type": field_type,
                "default": _text(default, 4000),
                "description": _text(raw.get("description"), 400),
                "required": bool(raw.get("required")),
                "secret": bool(raw.get("secret")) or field_type == "password",
                "options": options[:50],
            }
        )
    return fields


def _clean_runtime(value: object) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ManifestError("runtime 必须是对象")
    runtime_type = _text(value.get("type"), 20) or "isolated"
    if runtime_type not in RUNTIME_TYPES:
        raise ManifestError(f"不支持的运行时类型：{runtime_type}")
    engine = _text(value.get("engine"), 20) or "node"
    if engine not in ENGINES:
        raise ManifestError(f"不支持的运行时引擎：{engine}")
    runtime: dict[str, Any] = {"type": runtime_type, "engine": engine}
    if engine == "widget-js" and runtime_type != "isolated":
        raise ManifestError("widget-js 运行时仅支持 isolated 模式")
    if runtime_type == "http":
        if engine == "widget-js":
            raise ManifestError("widget-js 不能使用 http 运行时")
        base_url = _text(value.get("base_url"), 300).rstrip("/")
        if not base_url or not _HOST_RE.match(base_url):
            raise ManifestError("http 运行时需要合法的 runtime.base_url")
        runtime["base_url"] = base_url
        headers = value.get("headers")
        if isinstance(headers, dict):
            runtime["headers"] = {
                str(key): str(item) for key, item in headers.items() if str(key)
            }
        return runtime
    entrypoint = value.get("entrypoint")
    if entrypoint:
        runtime["entrypoint"] = _rel_path(entrypoint, "入口文件")
    if not runtime.get("entrypoint"):
        raise ManifestError("runtime.entrypoint 不能为空")
    command = value.get("command")
    if command is not None:
        if not isinstance(command, list) or not command:
            raise ManifestError("runtime.command 必须是非空数组")
        runtime["command"] = [str(item) for item in command]
    port = value.get("port")
    if port:
        try:
            port_value = int(port)
        except (TypeError, ValueError) as exc:
            raise ManifestError("runtime.port 必须是整数") from exc
        if not (1 <= port_value <= 65535):
            raise ManifestError("runtime.port 超出范围")
        runtime["port"] = port_value
    env = value.get("env")
    if isinstance(env, dict):
        runtime["env"] = {str(k): str(v) for k, v in env.items() if _ENV_RE.match(str(k))}
    return runtime


def _clean_ui(value: object) -> dict[str, Any]:
    """插件自带的短剧页展示内容，由统一模板渲染。"""
    if not isinstance(value, dict):
        return {}
    block = value.get("shortdrama")
    if not isinstance(block, dict):
        return {}
    accent = _text(block.get("accent"), 40)
    if accent and not re.match(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$", accent):
        accent = ""
    logo = _text(block.get("logo"), 240)
    if logo and not logo.startswith("/"):
        logo = ""
    content: dict[str, Any] = {
        "title": _text(block.get("title"), 40),
        "subtitle": _text(block.get("subtitle"), 120),
        "accent": accent,
        "icon": _text(block.get("icon"), 4000),
        "logo": logo,
        "badge": _text(block.get("badge"), 20),
    }
    if not any(content.values()):
        return {}
    return {"shortdrama": {key: item for key, item in content.items() if item}}


def normalize_manifest(raw: object) -> dict[str, Any]:
    """校验并补全 Manifest，返回可直接入库的字典。"""
    if not isinstance(raw, dict):
        raise ManifestError("manifest.json 必须是对象")
    plugin_id = _text(raw.get("id"), 80)
    if not plugin_id or not _ID_RE.match(plugin_id):
        raise ManifestError("插件 id 不合法")
    version = _text(raw.get("version"), 40)
    if not version:
        raise ManifestError("插件 version 不能为空")
    api_version = _text(raw.get("api_version"), 20) or API_VERSION
    if api_version not in SUPPORTED_API_VERSIONS:
        raise ManifestError(f"插件 API 版本 {api_version} 不兼容（当前 {API_VERSION}）")
    category = _text(raw.get("category"), 20) or "tool"
    if category not in CATEGORIES:
        raise ManifestError(f"不支持的插件分类：{category}")
    capabilities = []
    for item in raw.get("capabilities") or []:
        name = _text(item, 80)
        if name in CAPABILITIES and name not in capabilities:
            capabilities.append(name)
    endpoints = {}
    raw_endpoints = raw.get("endpoints")
    if isinstance(raw_endpoints, dict):
        for key, item in raw_endpoints.items():
            name = _text(key, 80)
            if name not in CAPABILITIES:
                continue
            if isinstance(item, dict):
                path = _text(item.get("path"), 240)
                method = _text(item.get("method"), 8).upper() or "POST"
            else:
                path = _text(item, 240)
                method = "POST"
            if not path.startswith("/") or "://" in path or ".." in path:
                continue
            if method not in ("GET", "POST", "PUT", "DELETE"):
                method = "POST"
            endpoints[name] = {"path": path, "method": method}
            if isinstance(item, dict) and item.get("redirect") is True:
                endpoints[name]["redirect"] = True
    runtime = _clean_runtime(raw.get("runtime") or {"type": "isolated", "engine": "node", "entrypoint": raw.get("entrypoint") or "module.mjs"})
    protocol = _text(raw.get("protocol"), 20)
    if not protocol:
        protocol = "widget-js" if runtime.get("engine") == "widget-js" else "native"
    if protocol not in PROTOCOLS:
        raise ManifestError(f"不支持的插件协议：{protocol}")
    if protocol == "widget-js" and runtime.get("engine") != "widget-js":
        raise ManifestError("protocol=widget-js 必须使用 engine=widget-js")
    entrypoint = runtime.get("entrypoint") or _rel_path(raw.get("entrypoint") or "module.mjs", "入口文件")
    if protocol == "widget-js" and not entrypoint.endswith(".js"):
        raise ManifestError("widget-js 插件入口必须是 .js 文件")
    permissions = []
    for item in raw.get("permissions") or []:
        name = _text(item, 20)
        if name in PERMISSIONS and name not in permissions:
            permissions.append(name)
    health = _text(raw.get("healthcheck"), 240) or ""
    if health and (not health.startswith("/") or "://" in health):
        raise ManifestError("healthcheck 必须是以 / 开头的路径")
    return {
        "id": plugin_id,
        "name": _text(raw.get("name") or plugin_id, 120),
        "version": version,
        "description": _text(raw.get("description"), 800),
        "author": _text(raw.get("author"), 80),
        "category": category,
        "protocol": protocol,
        "api_version": api_version,
        "capabilities": capabilities,
        "endpoints": endpoints,
        "runtime": runtime,
        "entrypoint": entrypoint,
        "permissions": permissions,
        "config": _clean_config(raw.get("config")),
        "ui": _clean_ui(raw.get("ui")),
        "healthcheck": health,
        "homepage": _text(raw.get("homepage"), 300),
        "license": _text(raw.get("license"), 80),
    }


def normalize_repository_entry(raw: object) -> dict[str, Any]:
    """仓库索引中的单个插件条目。"""
    if not isinstance(raw, dict):
        raise ManifestError("仓库索引中存在无效插件项")
    plugin_id = _text(raw.get("id"), 80)
    if not plugin_id or not _ID_RE.match(plugin_id):
        raise ManifestError(f"插件 id 不合法：{plugin_id}")
    version = _text(raw.get("version"), 40)
    if not version:
        raise ManifestError(f"插件 {plugin_id} 缺少 version")
    category = _text(raw.get("category"), 20) or "tool"
    if category not in CATEGORIES:
        category = "tool"
    entry_path = _text(raw.get("entry") or raw.get("file") or raw.get("path"), 240)
    absolute_entry = entry_path.startswith(("http://", "https://"))
    if entry_path and not absolute_entry:
        entry_path = _rel_path(entry_path, "插件入口路径")
    protocol = _text(raw.get("protocol"), 20)
    runtime = raw.get("runtime")
    if isinstance(runtime, str):
        protocol = protocol or ("widget-js" if runtime in ("rexhub-js", "widget-js") else "native")
    if protocol not in PROTOCOLS:
        protocol = "widget-js" if entry_path.endswith(".js") else "native"
    files = raw.get("files")
    if isinstance(files, list) and files:
        normalized_files = []
        for item in files[:40]:
            if isinstance(item, str):
                normalized_files.append({"file": _rel_path(item, "文件路径"), "target": _rel_path(item, "安装路径")})
            elif isinstance(item, dict):
                source = _text(item.get("file") or item.get("src"), 240)
                target = _text(item.get("target") or source, 240)
                if source:
                    safe_source = source if source.startswith(("http://", "https://")) else _rel_path(source, "文件路径")
                    normalized_files.append({"file": safe_source, "target": _rel_path(target, "安装路径")})
        files = normalized_files
    elif entry_path:
        target = "plugin.js" if protocol == "widget-js" else "module.mjs"
        files = [{"file": entry_path, "target": target}]
    else:
        files = []
    if protocol == "widget-js" and not any(item["target"].endswith(".js") for item in files):
        raise ManifestError(f"插件 {plugin_id} 缺少 JS 入口文件")
    manifest_path = _text(raw.get("manifest"), 240)
    if manifest_path:
        manifest_path = _rel_path(manifest_path, "manifest 路径")
    elif protocol != "widget-js":
        manifest_path = "manifest.json"
    release = _text(raw.get("release"), 240)
    if release:
        release = _rel_path(release, "release 路径")
    checksum = _text(raw.get("sha256"), 64).lower()
    return {
        "id": plugin_id,
        "name": _text(raw.get("name") or plugin_id, 120),
        "version": version,
        "description": _text(raw.get("description"), 800),
        "author": _text(raw.get("author"), 80),
        "category": category,
        "protocol": protocol,
        "manifest": manifest_path,
        "release": release,
        "sha256": checksum,
        "files": files,
        "entry": entry_path,
        "runtime": raw.get("runtime") if isinstance(raw.get("runtime"), dict) else {},
        "capabilities": raw.get("capabilities") if isinstance(raw.get("capabilities"), list) else [],
        "endpoints": raw.get("endpoints") if isinstance(raw.get("endpoints"), dict) else {},
        "config": raw.get("config") if isinstance(raw.get("config"), list) else [],
        "ui": raw.get("ui") if isinstance(raw.get("ui"), dict) else {},
        "env": raw.get("env") if isinstance(raw.get("env"), dict) else {},
        "requirements": raw.get("requirements") if isinstance(raw.get("requirements"), list) else [],
        "homepage": _text(raw.get("homepage"), 300),
    }
