"""ForwardWidget 插件仓库。

本地 JS 模块与远程 .fwd 索引统一存放在 data/plugins.json（0600），
对外由 /plugins/forward-widgets.fwd 暴露订阅索引。模块统一保存明文源码。
"""


import functools
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from typing import Any
from urllib.parse import urljoin, urlparse

from app.rexhub import config, network_store, plugin_analyzer

PLUGINS_PATH = config.DATA_DIR / "plugins.json"
WIDGETS_DIR = config.DATA_DIR / "widgets"

FEED_TIMEOUT = 20
# 自动更新全部失败时的重试间隔（秒），不必等满整个更新周期
RETRY_DELAY = 300

MAX_SOURCE_BYTES = 2 * 1024 * 1024
MAX_FEED_BYTES = 4 * 1024 * 1024
MAX_FEED_WIDGETS = 200
FIELD_LIMIT = 300

# 自定义插件分类：键用于存储，值用于管理台展示
CATEGORIES = (
    ("video", "影视"),
    ("drama", "短剧"),
    ("danmu", "弹幕"),
    ("subtitle", "字幕"),
    ("maker", "片商"),
    ("other", "其他"),
)
CATEGORY_LABELS = dict(CATEGORIES)
_CATEGORY_ALIASES = {label: key for key, label in CATEGORIES}

DEFAULT_CATEGORY = "other"

# 自动更新：定时重新拉取所有订阅（刷新）
AUTO_UPDATE_CHOICES = (
    (30, "30 分钟"),
    (60, "1 小时"),
    (180, "3 小时"),
    (360, "6 小时"),
    (720, "12 小时"),
    (1440, "24 小时"),
)
DEFAULT_AUTO_UPDATE = {
    "enabled": False,
    "interval_minutes": 360,
    "last_run": 0,
    "last_result": "",
}
_AUTO_LOCK = threading.Lock()
# data/plugins.json 的读写锁：后台自动更新与管理台保存可能并发
_IO_LOCK = threading.RLock()


def _locked(func):
    """串行化「读-改-写」，避免并发保存互相覆盖。"""

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        with _IO_LOCK:
            return func(*args, **kwargs)

    return wrapper


def _empty() -> dict[str, Any]:
    return {"plugins": [], "feeds": [], "auto_update": dict(DEFAULT_AUTO_UPDATE)}


def _normalize_auto(value: object) -> dict[str, Any]:
    cfg = dict(DEFAULT_AUTO_UPDATE)
    if not isinstance(value, dict):
        return cfg
    cfg["enabled"] = bool(value.get("enabled"))
    cfg["interval_minutes"] = _normalize_interval(value.get("interval_minutes"))
    try:
        cfg["last_run"] = int(value.get("last_run") or 0)
    except (TypeError, ValueError):
        cfg["last_run"] = 0
    cfg["last_result"] = str(value.get("last_result") or "")[:200]
    return cfg


def _normalize_interval(value: object) -> int:
    allowed = [minutes for minutes, _ in AUTO_UPDATE_CHOICES]
    try:
        minutes = int(value or 0)
    except (TypeError, ValueError):
        minutes = 0
    return minutes if minutes in allowed else DEFAULT_AUTO_UPDATE["interval_minutes"]


def _read() -> dict[str, Any]:
    try:
        data = json.loads(PLUGINS_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    plugins = [
        item
        for item in data.get("plugins") or []
        if isinstance(item, dict) and item.get("id")
    ]
    feeds = [
        item
        for item in data.get("feeds") or []
        if isinstance(item, dict) and item.get("url")
    ]
    return {
        "plugins": plugins,
        "feeds": feeds,
        "auto_update": _normalize_auto(data.get("auto_update")),
    }


def _write(data: dict[str, Any]) -> None:
    config.ensure_data_dir()
    with _IO_LOCK:
        # 临时文件名带上进程与线程，避免并发写互相覆盖
        tmp = PLUGINS_PATH.with_name(
            f"{PLUGINS_PATH.name}.{os.getpid()}.{threading.get_ident()}.tmp"
        )
        try:
            tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")
            os.chmod(tmp, 0o600)
            tmp.replace(PLUGINS_PATH)
        finally:
            tmp.unlink(missing_ok=True)


def _text(payload: dict, key: str, limit: int = FIELD_LIMIT) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        return ""
    return value.strip()[:limit]


def plugin_slug(plugin_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", plugin_id)


def category_label(key: object) -> str:
    return CATEGORY_LABELS.get(str(key or ""), "未分类")


def _normalize_category(value: object) -> str:
    """接受分类键（drama）或中文名（短剧），非法值返回空串。"""
    text = str(value or "").strip()
    if not text:
        return ""
    if text in CATEGORY_LABELS:
        return text
    return _CATEGORY_ALIASES.get(text, "")


def _balanced_object(text: str, start: int) -> str:
    """从 start 处的 { 开始，返回配对完整的对象字面量。"""
    depth = 0
    quote = ""
    i = start
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = ""
        elif ch in ("'", '"', "`"):
            quote = ch
        elif ch == "/" and i + 1 < len(text) and text[i + 1] == "/":
            nl = text.find("\n", i)
            i = len(text) if nl < 0 else nl
            continue
        elif ch == "/" and i + 1 < len(text) and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 1
            continue
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
        i += 1
    return text[start:]


def _unescape(value: str) -> str:
    def repl(match: re.Match) -> str:
        return {"n": "\n", "t": "\t", "r": "\r"}.get(match.group(1), match.group(1))

    return re.sub(r"\\(.)", repl, value)


def _string_field(block: str, key: str) -> str:
    pattern = (
        r"(?<![\w$.])(?:\"" + key + r"\"|'" + key + r"'|" + key + r")\s*:\s*"
        r"(?:\"((?:\\.|[^\"\\])*)\"|'((?:\\.|[^'\\])*)'|`((?:\\.|[^`\\])*)`)"
    )
    match = re.search(pattern, block)
    if not match:
        return ""
    raw = next((group for group in match.groups() if group is not None), "")
    return _unescape(raw).strip()


def parse_metadata(source: str) -> dict[str, Any]:
    match = re.search(r"WidgetMetadata\s*=", source)
    if not match:
        raise ValueError("源码中未找到 WidgetMetadata 定义")
    brace = source.find("{", match.end())
    if brace < 0:
        raise ValueError("WidgetMetadata 不是对象字面量")
    block = _balanced_object(source, brace)
    plugin_id = _string_field(block, "id")
    if not plugin_id:
        raise ValueError("WidgetMetadata 缺少 id")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", plugin_id):
        raise ValueError("插件 id 只能包含字母、数字、点、下划线和短横线")
    title = _string_field(block, "title") or plugin_id
    return {
        "id": plugin_id,
        "title": title[:FIELD_LIMIT],
        "description": _string_field(block, "description")[:FIELD_LIMIT],
        "version": _string_field(block, "version")[:32] or "1.0.0",
        "required_version": _string_field(block, "requiredVersion")[:32] or "0.0.1",
        "author": _string_field(block, "author")[:64],
        "modules": len(re.findall(r"functionName\s*:", block)),
    }


def _validate_source(source: str) -> str:
    text = (source or "").strip()
    if not text:
        raise ValueError("请粘贴或上传插件源码")
    if len(text.encode("utf-8")) > MAX_SOURCE_BYTES:
        raise ValueError("插件源码超过 2 MB 限制")
    head = text[:16].upper()
    if head.startswith(("FWENC", "REXENC")):
        raise ValueError("这是已加密的插件文件，无法解析，请上传明文源码")
    return text


@_locked
def save_plugin(source: str, category: str = "") -> dict[str, Any]:
    text = _validate_source(source)
    meta = parse_metadata(text)

    data = _read()
    now = int(time.time())
    row = next((item for item in data["plugins"] if item.get("id") == meta["id"]), None)
    created = row is None
    if row is None:
        row = {"id": meta["id"], "enabled": True, "created_at": now}
        data["plugins"].append(row)
    row.update(meta)
    picked = _normalize_category(category)
    if picked:
        row["category"] = picked
    elif not row.get("category"):
        row["category"] = DEFAULT_CATEGORY
    row["source"] = text
    row["analysis"] = plugin_analyzer.analyze(text)
    row["updated_at"] = now
    _write(data)
    return {"id": row["id"], "title": row["title"], "created": created}


@_locked
def set_enabled(plugin_id: str, enabled: bool) -> bool:
    data = _read()
    row = next((item for item in data["plugins"] if item.get("id") == plugin_id), None)
    if row is None:
        return False
    row["enabled"] = enabled
    row["updated_at"] = int(time.time())
    _write(data)
    return True


@_locked
def delete_plugin(plugin_id: str) -> bool:
    data = _read()
    remain = [item for item in data["plugins"] if item.get("id") != plugin_id]
    if len(remain) == len(data["plugins"]):
        return False
    data["plugins"] = remain
    _write(data)
    return True


def find_by_slug(slug: str) -> dict[str, Any] | None:
    """按 slug 取可下发的模块体：本地插件优先，其次订阅缓存到本地的源码。"""
    for row in _read()["plugins"]:
        if plugin_slug(str(row.get("id"))) == slug and row.get("enabled", True):
            return row
    for feed in _read()["feeds"]:
        for item in feed.get("widgets") or []:
            if plugin_slug(str(item.get("id"))) != slug or not item.get("enabled", True):
                continue
            path = WIDGETS_DIR / str(item.get("source_file") or "")
            if not item.get("source_file") or not path.is_file():
                return None
            return {"source": path.read_text("utf-8")}
    return None


def find_with_source(plugin_id: str) -> tuple[dict[str, Any] | None, str]:
    """按插件 id 取配置行与明文源码：本地插件优先，其次订阅已落盘的源码。"""
    data = _read()
    for row in data["plugins"]:
        if str(row.get("id")) == plugin_id:
            return row, str(row.get("source") or "")
    for feed in data["feeds"]:
        for item in feed.get("widgets") or []:
            if str(item.get("id")) != plugin_id:
                continue
            path = WIDGETS_DIR / str(item.get("source_file") or "")
            if item.get("source_file") and path.is_file():
                return item, path.read_text("utf-8")
            return item, ""
    return None, ""


def _download_source(url: str) -> tuple[str, bool]:
    """下载模块源码（原样，可能仍是密文），返回 (文本, 是否加密)。"""
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("插件源码地址需以 http(s):// 开头")
    request = urllib.request.Request(
        network_store.rewrite_github(url),
        headers={"User-Agent": "RexHub", "Accept": "*/*"},
    )
    try:
        with network_store.open_url(request, FEED_TIMEOUT, "plugins") as response:
            raw = response.read(MAX_SOURCE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise ValueError(f"源码返回 HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ValueError("无法下载源码") from exc
    if len(raw) > MAX_SOURCE_BYTES:
        raise ValueError("源码超过 2 MB 限制")
    text = raw.decode("utf-8", "replace")
    return text, text[:16].upper().startswith(("FWENC", "REXENC"))


def _save_widget_source(widget_id: str, text: str) -> str:
    name = f"{plugin_slug(widget_id)}.js"
    config.ensure_data_dir()
    WIDGETS_DIR.mkdir(parents=True, exist_ok=True)
    path = WIDGETS_DIR / name
    tmp = path.with_suffix(".js.tmp")
    tmp.write_text(text, "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    return name


def _attach_sources(widgets: list[dict[str, Any]]) -> None:
    """订阅时把每个模块源码落到 data/widgets，并做一次结构解析。"""

    def one(row: dict[str, Any]) -> None:
        try:
            text, encrypted = _download_source(str(row["url"]))
            row["source_file"] = _save_widget_source(str(row["id"]), text)
            row["source_bytes"] = len(text.encode("utf-8"))
            row["source_encrypted"] = encrypted
            row["source_at"] = int(time.time())
            row["source_error"] = ""
            row["analysis"] = plugin_analyzer.analyze(text)
        except ValueError as exc:
            row.update(
                {
                    "source_file": "",
                    "source_bytes": 0,
                    "source_encrypted": False,
                    "source_at": 0,
                    "source_error": str(exc),
                    "analysis": {},
                }
            )

    if not widgets:
        return
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(one, widgets))


def _fetch_feed(url: str) -> dict[str, Any]:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("请填写 http(s) 索引地址")
    request = urllib.request.Request(
        network_store.rewrite_github(url),
        headers={"User-Agent": "RexHub", "Accept": "application/json, text/plain, */*"},
    )
    try:
        with network_store.open_url(request, FEED_TIMEOUT, "plugins") as response:
            raw = response.read(MAX_FEED_BYTES).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raise ValueError(f"索引地址返回 HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ValueError("无法访问索引地址，请检查网络或地址") from exc
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise ValueError("索引内容不是合法 JSON") from exc
    widgets_raw = doc.get("widgets") if isinstance(doc, dict) else None
    if not isinstance(widgets_raw, list):
        raise ValueError("索引缺少 widgets 列表")

    widgets: list[dict[str, Any]] = []
    for item in widgets_raw[:MAX_FEED_WIDGETS]:
        if not isinstance(item, dict):
            continue
        widget_id = _text(item, "id", 128)
        widget_url = _text(item, "url", 600)
        if not widget_id or not widget_url:
            continue
        widgets.append(
            {
                "id": widget_id,
                "title": _text(item, "title") or widget_id,
                "description": _text(item, "description"),
                "version": _text(item, "version", 32),
                "required_version": _text(item, "requiredVersion", 32),
                "author": _text(item, "author", 64),
                "url": urljoin(url, widget_url),
                "enabled": True,
                "title_override": "",
                "description_override": "",
                "note": "",
                "api_url": "",
                "source_file": "",
                "source_bytes": 0,
                "source_encrypted": False,
                "source_at": 0,
                "source_error": "",
                "analysis": {},
            }
        )
    if not widgets:
        raise ValueError("索引中没有可用的插件")
    _attach_sources(widgets)
    return {
        "url": url,
        "title": _text(doc, "title", 200) or parsed.netloc,
        "description": _text(doc, "description"),
        "widgets": widgets,
        "fetched_at": int(time.time()),
        "message": "",
    }


def add_feed(url: str) -> dict[str, Any]:
    target = (url or "").strip()[:500]
    if not target:
        raise ValueError("请填写索引地址")
    # 网络请求放在锁外，避免阻塞其它配置保存
    feed = _fetch_feed(target)
    with _IO_LOCK:
        data = _read()
        previous = next((item for item in data["feeds"] if item.get("url") == target), None)
        if previous:
            _keep_widget_settings(previous, feed)
        data["feeds"] = [item for item in data["feeds"] if item.get("url") != target]
        data["feeds"].append(feed)
        _write(data)
    return feed


def _keep_widget_settings(old: dict[str, Any], fresh: dict[str, Any]) -> None:
    """刷新订阅时保留用户改过的名称、描述、备注与启用状态。"""
    previous = {str(item.get("id")): item for item in old.get("widgets") or []}
    for item in fresh.get("widgets") or []:
        row = previous.get(str(item.get("id")))
        if not row:
            continue
        item["enabled"] = bool(row.get("enabled", True))
        for key in ("title_override", "description_override", "note", "api_url"):
            value = str(row.get(key) or "")
            if value:
                item[key] = value
        # 本次下载失败时沿用上次已落盘的源码，避免刷新把缓存清空
        if not item.get("source_file") and row.get("source_file"):
            for key in ("source_file", "source_bytes", "source_encrypted", "source_at", "analysis"):
                item[key] = row.get(key)
            item["source_error"] = ""


def refresh_feed(url: str) -> dict[str, Any]:
    if not any(item.get("url") == url for item in _read()["feeds"]):
        raise ValueError("订阅不存在")
    try:
        # 网络请求放在锁外，避免阻塞其它配置保存
        fresh = _fetch_feed(url)
    except ValueError as exc:
        with _IO_LOCK:
            data = _read()
            feed = next((item for item in data["feeds"] if item.get("url") == url), None)
            if feed is None:
                raise ValueError("订阅不存在") from exc
            feed["message"] = str(exc)
            feed["fetched_at"] = int(time.time())
            _write(data)
        raise
    with _IO_LOCK:
        data = _read()
        feed = next((item for item in data["feeds"] if item.get("url") == url), None)
        if feed is None:
            raise ValueError("订阅不存在")
        _keep_widget_settings(feed, fresh)
        data["feeds"] = [fresh if item.get("url") == url else item for item in data["feeds"]]
        _write(data)
    return fresh


def _clean_api_url(value: str) -> str:
    text = (value or "").strip().rstrip("/")[:300]
    if not text:
        return ""
    parsed = urlparse(text)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("接口地址需以 http(s):// 开头")
    return text


def _clean_api_key(value: str) -> str:
    """插件 API Key / Token：不校验格式，只做去空白与长度限制。"""
    return re.sub(r"\s+", "", value or "")[:300]


def _clean_proxy(value: str) -> str:
    """插件专用代理：允许省略 http://，非法地址直接拒绝。"""
    text = (value or "").strip()[:300]
    if not text:
        return ""
    if "://" not in text:
        text = "http://" + text
    parsed = urlparse(text)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("代理地址需为 http://主机:端口")
    return text.rstrip("/")


@_locked
def update_feed_widget(
    feed_url: str,
    widget_id: str,
    title: str = "",
    description: str = "",
    note: str = "",
    api_url: str = "",
    enabled: bool = True,
) -> dict[str, Any]:
    data = _read()
    feed = next((item for item in data["feeds"] if item.get("url") == feed_url), None)
    if feed is None:
        raise ValueError("订阅不存在")
    widget = next(
        (item for item in feed.get("widgets") or [] if str(item.get("id")) == widget_id),
        None,
    )
    if widget is None:
        raise ValueError("插件不存在")
    widget["title_override"] = (title or "").strip()[:200]
    widget["description_override"] = (description or "").strip()[:500]
    widget["note"] = (note or "").strip()[:200]
    widget["api_url"] = _clean_api_url(api_url)
    widget["enabled"] = bool(enabled)
    feed["updated_at"] = int(time.time())
    _write(data)
    return widget


@_locked
def set_feed_widget_enabled(feed_url: str, widget_id: str, enabled: bool) -> dict[str, Any]:
    """只切换订阅内某个插件的启用状态，不动其它配置。"""
    data = _read()
    feed = next((item for item in data["feeds"] if item.get("url") == feed_url), None)
    if feed is None:
        raise ValueError("订阅不存在")
    widget = next(
        (item for item in feed.get("widgets") or [] if str(item.get("id")) == widget_id),
        None,
    )
    if widget is None:
        raise ValueError("插件不存在")
    widget["enabled"] = bool(enabled)
    feed["updated_at"] = int(time.time())
    _write(data)
    return widget


def auto_update_config() -> dict[str, Any]:
    return _read()["auto_update"]


@_locked
def set_auto_update(enabled: bool, interval_minutes: object = None) -> dict[str, Any]:
    data = _read()
    cfg = _normalize_auto(data.get("auto_update"))
    cfg["enabled"] = bool(enabled)
    if interval_minutes is not None:
        cfg["interval_minutes"] = _normalize_interval(interval_minutes)
    data["auto_update"] = cfg
    _write(data)
    return cfg


def _refresh_all_locked() -> dict[str, Any]:
    """刷新全部订阅（调用方需持有 _AUTO_LOCK）。"""
    urls = [str(item.get("url")) for item in _read()["feeds"]]
    ok = 0
    errors: list[str] = []
    for url in urls:
        try:
            refresh_feed(url)
            ok += 1
        except ValueError as exc:
            errors.append(f"{url}：{exc}")
    with _IO_LOCK:
        data = _read()
        cfg = _normalize_auto(data.get("auto_update"))
        now = int(time.time())
        if urls and errors and not ok:
            # 全部失败时提前重试，避免等满整个更新周期
            cfg["last_run"] = now - cfg["interval_minutes"] * 60 + RETRY_DELAY
        else:
            cfg["last_run"] = now
        if not urls:
            cfg["last_result"] = "还没有订阅"
        elif errors:
            cfg["last_result"] = f"{ok}/{len(urls)} 个订阅更新成功，{len(errors)} 个失败：{errors[0]}"
        else:
            cfg["last_result"] = f"{ok} 个订阅已更新"
        data["auto_update"] = cfg
        _write(data)
    return {"total": len(urls), "ok": ok, "errors": errors, "config": cfg}


def refresh_all_feeds() -> dict[str, Any]:
    """手动「全部更新」：并发安全地刷新所有订阅。"""
    with _AUTO_LOCK:
        return _refresh_all_locked()


@_locked
def update_plugin_config(
    plugin_id: str,
    title: str = "",
    description: str = "",
    note: str = "",
    api_url: str = "",
    enabled: bool = True,
    category: str = "",
    api_key: str = "",
    proxy_url: str = "",
    proxy_enabled: bool = False,
) -> dict[str, Any]:
    data = _read()
    row = next((item for item in data["plugins"] if item.get("id") == plugin_id), None)
    if row is None:
        raise ValueError("插件不存在")
    proxy = _clean_proxy(proxy_url)
    if proxy_enabled and not proxy:
        raise ValueError("启用代理前请填写代理地址")
    row["title_override"] = (title or "").strip()[:200]
    row["description_override"] = (description or "").strip()[:500]
    row["note"] = (note or "").strip()[:200]
    row["api_url"] = _clean_api_url(api_url)
    row["api_key"] = _clean_api_key(api_key)
    row["proxy_url"] = proxy
    row["proxy_enabled"] = bool(proxy_enabled) and bool(proxy)
    row["category"] = _normalize_category(category) or str(row.get("category") or DEFAULT_CATEGORY)
    row["enabled"] = bool(enabled)
    row["updated_at"] = int(time.time())
    _write(data)
    return row


@_locked
def delete_feed(url: str) -> bool:
    data = _read()
    removed = [item for item in data["feeds"] if item.get("url") == url]
    if not removed:
        return False
    data["feeds"] = [item for item in data["feeds"] if item.get("url") != url]
    _write(data)
    # 清理只被该订阅引用的本地源码缓存
    keep = {
        str(widget.get("source_file") or "")
        for feed in data["feeds"]
        for widget in feed.get("widgets") or []
    }
    for feed in removed:
        for widget in feed.get("widgets") or []:
            name = str(widget.get("source_file") or "")
            if not name or name in keep:
                continue
            path = WIDGETS_DIR / name
            try:
                if path.is_file() and path.parent == WIDGETS_DIR:
                    path.unlink()
            except OSError:
                pass
    return True


def snapshot() -> dict[str, Any]:
    data = _read()
    plugins = data["plugins"]
    return {
        "plugins": plugins,
        "feeds": data["feeds"],
        "auto_update": data["auto_update"],
        "stats": {
            "total": len(plugins),
            "enabled": sum(1 for item in plugins if item.get("enabled", True)),
            "feeds": len(data["feeds"]),
        },
    }


def shortdrama_base_url() -> str:
    """短剧聚合上游地址，取插件配置的接口地址（优先 id 含 shortdrama 的插件）。"""
    data = _read()
    rows: list[tuple[str, str]] = [
        (str(item.get("id") or ""), str(item.get("api_url") or ""))
        for item in data["plugins"]
    ]
    for feed in data["feeds"]:
        rows.extend(
            (str(item.get("id") or ""), str(item.get("api_url") or ""))
            for item in feed.get("widgets") or []
        )
    rows = [(pid, url) for pid, url in rows if url]
    for pid, url in rows:
        if "shortdrama" in pid.lower():
            return url
    return rows[0][1] if rows else ""


def build_index(base_url: str) -> dict[str, Any]:
    data = _read()
    base = base_url.rstrip("/")
    widgets: list[dict[str, Any]] = []
    seen: set[str] = set()

    for row in data["plugins"]:
        if not row.get("enabled", True):
            continue
        plugin_id = str(row.get("id"))
        if plugin_id in seen:
            continue
        seen.add(plugin_id)
        widgets.append(
            {
                "id": plugin_id,
                "title": row.get("title_override") or row.get("title") or plugin_id,
                "description": row.get("description_override") or row.get("description") or "",
                "requiredVersion": row.get("required_version") or "0.0.1",
                "version": row.get("version") or "1.0.0",
                "author": row.get("author") or "",
                "url": f"{base}/plugins/{plugin_slug(plugin_id)}.js",
            }
        )

    for feed in data["feeds"]:
        for item in feed.get("widgets") or []:
            plugin_id = str(item.get("id") or "")
            if not plugin_id or plugin_id in seen or not item.get("url"):
                continue
            if not item.get("enabled", True):
                continue
            seen.add(plugin_id)
            widgets.append(
                {
                    "id": plugin_id,
                    "title": item.get("title_override") or item.get("title") or plugin_id,
                    "description": item.get("description_override") or item.get("description") or "",
                    "requiredVersion": item.get("required_version") or "0.0.1",
                    "version": item.get("version") or "1.0.0",
                    "author": item.get("author") or "",
                    "url": (
                        f"{base}/plugins/{plugin_slug(plugin_id)}.js"
                        if item.get("source_file")
                        else item["url"]
                    ),
                }
            )

    return {
        "title": "RexHub Widgets",
        "description": "RexHub 自托管 ForwardWidget 插件索引",
        "widgets": widgets,
    }
