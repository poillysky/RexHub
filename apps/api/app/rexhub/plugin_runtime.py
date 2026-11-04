"""插件运行时：在 QuickJS 沙箱里执行明文 ForwardWidget 模块。

分工：
  1. 插件层（本模块执行）负责列表、搜索、封面、详情与取流地址；
  2. 播放层（插件返回的 playBase，如 NAS 25566）只负责真正的视频流。

沙箱只注入 Widget.http 与 console，不暴露宿主文件系统；执行放在独立
子进程里，避免插件死循环拖住服务进程。
"""


import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from app.rexhub import config, network_store, plugin_analyzer

MAX_SOURCE_BYTES = 2 * 1024 * 1024
MAX_HTTP_BYTES = 2 * 1024 * 1024
HTTP_TIMEOUT = 15
RUN_TIMEOUT = 30
MEMORY_LIMIT = 64 * 1024 * 1024
MAX_RESULT_BYTES = 4 * 1024 * 1024
MAX_LOG_LINES = 40
# 同时执行的插件子进程上限，避免公开接口被刷爆
MAX_CONCURRENT_RUNS = 4
RUN_SLOT_TIMEOUT = 10
_RUN_SLOTS = threading.BoundedSemaphore(MAX_CONCURRENT_RUNS)

FUNCTION_RE = re.compile(r"^[A-Za-z_$][A-Za-z0-9_$]*$")
ENCRYPTED_HEAD = ("FWENC", "REXENC")

BOOTSTRAP = """
var __nativeCall = __http_call;
function __http(method) {
  return function (url, options) {
    return Promise.resolve().then(function () {
      var payload = __nativeCall(method, String(url), options ? JSON.stringify(options) : "");
      var res = JSON.parse(payload);
      if (res && res.__error) { throw new Error(res.__error); }
      return res;
    });
  };
}
var Widget = {
  http: {
    get: __http("GET"),
    post: __http("POST"),
    put: __http("PUT"),
    delete: __http("DELETE"),
    request: __http("GET")
  }
};
var console = {
  log: __nativeLog,
  info: __nativeLog,
  warn: __nativeLog,
  error: __nativeLog,
  debug: __nativeLog
};
function fetch(url, options) {
  return __http("GET")(url, options || {}).then(function (res) {
    var data = res && res.data;
    var text = typeof data === "string" ? data : JSON.stringify(data);
    var status = Number(res && res.status) || 0;
    var headers = (res && res.headers) || {};
    return {
      ok: !status || (status >= 200 && status < 300),
      status: status,
      url: String(res && res.url || url),
      headers: {
        get: function (name) {
          return headers[String(name || "").toLowerCase()] || "";
        }
      },
      text: function () { return Promise.resolve(text); },
      json: function () { return Promise.resolve(typeof data === "string" ? JSON.parse(data) : data); }
    };
  });
}
function URL(input, base) {
  var raw = String(input == null ? "" : input);
  if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) {
    var origin = /^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#]*)/.exec(String(base));
    if (raw.charAt(0) === "/") {
      raw = (origin ? origin[1] : String(base).replace(/\/+$/, "")) + raw;
    } else {
      raw = String(base).replace(/[^/]*$/, "") + raw;
    }
  }
  var match = /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(raw);
  this.href = raw;
  this.protocol = match ? match[1] : "";
  this.host = match ? match[2] : "";
  this.hostname = this.host.split(":")[0];
  this.pathname = (match && match[3]) || "/";
  this.search = (match && match[4]) || "";
  this.hash = (match && match[5]) || "";
  var search = {};
  var query = this.search.replace(/^\?/, "");
  var pairs = query ? query.split("&") : [];
  for (var i = 0; i < pairs.length; i++) {
    var parts = pairs[i].split("=");
    var key = decodeURIComponent(parts[0] || "");
    if (key) { search[key] = decodeURIComponent(parts.slice(1).join("=") || ""); }
  }
  this.searchParams = {
    get: function (key) {
      return Object.prototype.hasOwnProperty.call(search, key) ? search[key] : null;
    },
    has: function (key) {
      return Object.prototype.hasOwnProperty.call(search, key);
    }
  };
}
var __state = { done: false, value: null, error: null };
"""


class PluginRuntimeError(Exception):
    """插件执行失败（源码、函数、超时或上游请求错误）。"""


def is_encrypted(source: str) -> bool:
    return (source or "").strip()[:16].upper().startswith(ENCRYPTED_HEAD)


def _http_call(method: str, url: str, options_json: str) -> str:
    """JS 侧的 Widget.http 桥接：同步发请求，结果以 JSON 字符串返回。"""
    try:
        return _http_call_inner(method, url, options_json)
    except Exception as exc:  # noqa: BLE001 - 统一回传给 JS 抛错
        return json.dumps({"__error": str(exc) or exc.__class__.__name__}, ensure_ascii=False)


# 当前子进程执行插件时使用的专用代理（每个插件可在管理台单独配置）
_ACTIVE_PROXY = ""


def plugin_proxy(row: dict[str, Any]) -> str:
    """插件配置里启用代理时返回代理地址，否则返回空串。"""
    if not row.get("proxy_enabled"):
        return ""
    return str(row.get("proxy_url") or "").strip()


def _is_local_host(url: str) -> bool:
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    return host in {"localhost", "127.0.0.1", "::1"} or host.endswith(".local")


def _http_call_inner(method: str, url: str, options_json: str) -> str:
    try:
        options = json.loads(options_json) if options_json else {}
    except ValueError:
        options = {}
    if not isinstance(options, dict):
        options = {}

    target = str(url or "").strip()
    if not re.match(r"^https?://", target, re.I):
        raise ValueError("仅支持 http(s) 地址")

    verb = str(options.get("method") or method or "GET").upper()
    headers = options.get("headers") if isinstance(options.get("headers"), dict) else {}
    headers = {str(key): str(value) for key, value in headers.items()}

    query = options.get("params") if isinstance(options.get("params"), dict) else None
    if query:
        joiner = "&" if "?" in target else "?"
        target = target + joiner + urllib.parse.urlencode(query, doseq=True)

    body = options.get("body", options.get("data"))
    payload: bytes | None = None
    if body is not None:
        if isinstance(body, bytes):
            payload = body
        elif isinstance(body, str):
            payload = body.encode("utf-8")
        else:
            payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers.setdefault("Content-Type", "application/json")

    headers.setdefault("User-Agent", "RexHub-Plugin/1.0")
    headers.setdefault("Accept", "*/*")

    request_url = network_store.rewrite_github(target)
    request = urllib.request.Request(
        request_url,
        data=payload,
        headers=headers,
        method=verb,
    )
    try:
        if _ACTIVE_PROXY and not _is_local_host(request_url):
            # 插件单独启用了代理：该插件的上游请求走指定代理
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({"http": _ACTIVE_PROXY, "https": _ACTIVE_PROXY})
            )
            with opener.open(request, timeout=HTTP_TIMEOUT) as response:
                raw = response.read(MAX_HTTP_BYTES + 1)
                status = int(getattr(response, "status", 200) or 200)
                content_type = str(response.headers.get("content-type") or "")
        else:
            with network_store.open_url(request, HTTP_TIMEOUT, "plugins") as response:
                raw = response.read(MAX_HTTP_BYTES + 1)
                status = int(getattr(response, "status", 200) or 200)
                content_type = str(response.headers.get("content-type") or "")
    except urllib.error.HTTPError as exc:
        raw = exc.read(MAX_HTTP_BYTES + 1) if hasattr(exc, "read") else b""
        status = int(exc.code or 0)
        content_type = str(exc.headers.get("content-type") if exc.headers else "")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ValueError("网络请求失败") from exc

    if len(raw) > MAX_HTTP_BYTES:
        raise ValueError("上游响应超过 2 MB 限制")

    text = raw.decode("utf-8", "replace")
    data: Any = text
    if "json" in content_type.lower() or text.lstrip()[:1] in ("{", "["):
        try:
            data = json.loads(text)
        except ValueError:
            data = text
    return json.dumps(
        {"status": status, "headers": {"content-type": content_type}, "data": data, "url": target},
        ensure_ascii=False,
    )


def _log(*args: Any) -> None:
    line = " ".join(str(item) for item in args)[:500]
    print(f"[plugin] {line}", file=sys.stderr)


def _execute_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """子进程入口：构建沙箱、加载源码并调用目标函数。"""
    import quickjs

    global _ACTIVE_PROXY
    _ACTIVE_PROXY = str(payload.get("proxy") or "")

    source = str(payload.get("source") or "")
    function = str(payload.get("function") or "")
    params = payload.get("params") if isinstance(payload.get("params"), dict) else {}

    if is_encrypted(source):
        return {"ok": False, "error": "插件是 REXENC/FWENC 密文，运行时无法执行，请使用明文插件"}
    if not FUNCTION_RE.match(function):
        return {"ok": False, "error": "插件函数名无效"}

    context = quickjs.Context()
    context.set_memory_limit(MEMORY_LIMIT)
    context.add_callable("__http_call", _http_call)
    context.add_callable("__nativeLog", _log)

    try:
        context.eval(BOOTSTRAP)
        context.eval(source)
    except quickjs.JSException as exc:
        return {"ok": False, "error": f"插件加载失败：{exc}"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"插件加载失败：{exc}"}

    if not context.eval(f"typeof {function} === 'function'"):
        return {"ok": False, "error": f"插件中没有函数 {function}()"}

    params_json = json.dumps(params, ensure_ascii=False)
    try:
        context.eval(
            f"""
(function () {{
  try {{
    Promise.resolve({function}({params_json})).then(
      function (value) {{ __state.value = value; __state.done = true; }},
      function (error) {{ __state.error = String(error && error.message || error); __state.done = true; }}
    );
  }} catch (error) {{
    __state.error = String(error && error.message || error);
    __state.done = true;
  }}
}})();
"""
        )
    except quickjs.JSException as exc:
        return {"ok": False, "error": f"插件执行失败：{exc}"}

    deadline = time.monotonic() + RUN_TIMEOUT
    while True:
        try:
            if context.eval("__state.done"):
                break
        except quickjs.JSException as exc:
            return {"ok": False, "error": f"插件执行失败：{exc}"}
        pending = False
        try:
            pending = bool(context.execute_pending_job())
        except quickjs.JSException as exc:
            return {"ok": False, "error": f"插件执行失败：{exc}"}
        if not pending:
            return {"ok": False, "error": "插件未返回结果（可能使用了运行时未支持的异步 API）"}
        if time.monotonic() > deadline:
            return {"ok": False, "error": "插件执行超时"}

    try:
        raw = context.eval("JSON.stringify(__state)")
        state = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"插件返回值无法序列化：{exc}"}

    if state.get("error"):
        return {"ok": False, "error": str(state["error"])}
    value = state.get("value")
    if len(json.dumps(value, ensure_ascii=False).encode("utf-8")) > MAX_RESULT_BYTES:
        return {"ok": False, "error": "插件返回数据超过 4 MB 限制"}
    return {"ok": True, "value": value}


def run_function(
    source: str,
    function: str,
    params: dict[str, Any] | None = None,
    proxy: str = "",
) -> Any:
    """在独立子进程的 QuickJS 沙箱里执行插件函数，返回其 JS 结果。"""
    if len((source or "").encode("utf-8")) > MAX_SOURCE_BYTES:
        raise PluginRuntimeError("插件源码超过 2 MB 限制")
    payload = json.dumps(
        {"source": source, "function": function, "params": params or {}, "proxy": proxy},
        ensure_ascii=False,
    ).encode("utf-8")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(config.BASE_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    if not _RUN_SLOTS.acquire(timeout=RUN_SLOT_TIMEOUT):
        raise PluginRuntimeError("插件执行任务过多，请稍后重试")
    try:
        completed = subprocess.run(
            [sys.executable, "-m", "app.rexhub.plugin_runtime", "--child"],
            input=payload,
            capture_output=True,
            cwd=str(config.BASE_DIR),
            env=env,
            timeout=RUN_TIMEOUT + 5,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise PluginRuntimeError("插件执行超时") from exc
    except OSError as exc:
        raise PluginRuntimeError("无法启动插件运行时") from exc
    finally:
        _RUN_SLOTS.release()

    stdout = completed.stdout.decode("utf-8", "replace").strip()
    if not stdout:
        stderr = completed.stderr.decode("utf-8", "replace").strip()
        raise PluginRuntimeError(stderr[-500:] or "插件运行时没有返回结果")
    try:
        result = json.loads(stdout.splitlines()[-1])
    except ValueError as exc:
        raise PluginRuntimeError("插件运行时返回了无效数据") from exc
    if not result.get("ok"):
        raise PluginRuntimeError(str(result.get("error") or "插件执行失败"))
    return result.get("value")


def analysis_of(row: dict[str, Any], source: str) -> dict[str, Any]:
    """优先用入库时的解析结果，缺失时现场解析。"""
    cached = row.get("analysis")
    if isinstance(cached, dict) and cached.get("ok"):
        return cached
    return plugin_analyzer.analyze(source)


def module_kind(module: dict[str, Any]) -> str:
    kind = str(module.get("type") or "").lower()
    if kind in {"stream", "play", "video"}:
        return "stream"
    if kind in {"meta", "detail"}:
        return "meta"
    name = f"{module.get('id') or ''} {module.get('function') or ''}".lower()
    if any(key in name for key in ("stream", "resource", "play")):
        return "stream"
    if "meta" in name or "detail" in name:
        return "meta"
    return "catalog"


def modules_of(analysis: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [item for item in analysis.get("modules") or [] if isinstance(item, dict)]
    return rows


def module_media_type(module: dict[str, Any]) -> str:
    """目录条目属于电影还是剧集：模块声明 mediaType 时优先采用。"""
    declared = str(module.get("mediaType") or "").strip().lower()
    if declared in {"movie", "series", "tv"}:
        return declared
    return "tv"


def build_manifest(plugin_id: str, row: dict[str, Any], analysis: dict[str, Any]) -> dict[str, Any]:
    meta = analysis.get("metadata") or {}
    modules = modules_of(analysis)
    catalog_modules = [module for module in modules if module_kind(module) == "catalog"]
    catalog_types = sorted({module_media_type(module) for module in catalog_modules}) or ["tv"]
    catalogs = [
        {
            "type": module_media_type(module),
            "id": str(module.get("id") or module.get("function")),
            "name": str(module.get("title") or module.get("id") or ""),
            "extra": [
                {"name": "search", "isRequired": False},
                {"name": "skip", "isRequired": False},
            ],
        }
        for module in catalog_modules
    ]
    search = analysis.get("search") or {}
    if search.get("function"):
        # 搜索函数同时返回电影与剧集时，按类型各挂一个搜索目录
        for media_type in catalog_types:
            catalogs.append(
                {
                    "type": media_type,
                    "id": "search",
                    "name": str(search.get("title") or "搜索"),
                    "extra": [{"name": "search", "isRequired": True}],
                }
            )
    resources = [{"name": "catalog", "types": catalog_types}]
    types = list(catalog_types)
    if any(module_kind(module) == "meta" for module in modules):
        types = sorted(set(types) | {"movie", "series"})
        resources.append({"name": "meta", "types": types})
    if any(module_kind(module) == "stream" for module in modules):
        resources.append({"name": "stream", "types": ["tv"]})
    manifest = {
        "id": plugin_id,
        "version": str(row.get("version") or meta.get("version") or "1.0.0"),
        "name": str(row.get("title_override") or row.get("title") or meta.get("title") or plugin_id),
        "description": str(
            row.get("description_override") or row.get("description") or meta.get("description") or ""
        ),
        "types": types,
        "resources": resources,
        "catalogs": catalogs,
        "behaviorHints": {"configurable": True},
    }
    for key in ("logo", "background", "contactEmail"):
        value = str(row.get(key) or meta.get(key) or "").strip()
        if value:
            manifest[key] = value
    return manifest


def _api_param_name(names: list[str]) -> str:
    """在插件声明的全局参数里找最像「接口地址」的那一个。"""
    exact = {"apibase", "apiurl", "baseurl", "base", "server", "serverurl", "host"}
    for name in names:
        if name.lower() in exact:
            return name
    for name in names:
        low = name.lower()
        if "api" in low or (low.endswith("url") and "play" not in low and "stream" not in low):
            return name
    return ""


def build_params(row: dict[str, Any], analysis: dict[str, Any], extra: dict[str, Any]) -> dict[str, Any]:
    """合并插件默认参数、管理台填写的接口地址和本次请求参数。"""
    meta = analysis.get("metadata") or {}
    params: dict[str, Any] = {}
    names: list[str] = []
    for item in meta.get("global_params") or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "")
        if not name:
            continue
        names.append(name)
        params[name] = item.get("default")
    api_url = str(row.get("api_url") or "").strip()
    if api_url:
        # 只覆盖接口地址类的参数，避免把 playBase 等其它全局参数冲掉
        target = _api_param_name(names)
        if target:
            params[target] = api_url
        elif not names:
            params["apiBase"] = api_url
    api_key = str(row.get("api_key") or "").strip()
    if api_key:
        # 管理台单独填写的 Key / Token 覆盖插件里同名的全局参数
        target = next(
            (name for name in names if name.lower() in {"apikey", "api_key", "key", "token"}),
            "",
        )
        if target:
            params[target] = api_key
    for key, value in (extra or {}).items():
        if value in (None, "") or key in params:
            continue
        params[key] = value
    return params


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def to_metas(value: Any, default_type: str = "tv") -> list[dict[str, Any]]:
    """把插件返回的条目转成 Stremio meta，保留插件的其余字段（视频列表等）。"""
    if not isinstance(value, list):
        return []
    metas: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        meta = dict(item)
        cover = _text(item.get("coverUrl") or item.get("cover") or item.get("posterPath"))
        meta["id"] = _text(item.get("id"))
        meta["type"] = _text(item.get("mediaType")) or _text(default_type) or "tv"
        meta["name"] = _text(item.get("title") or item.get("name"))
        if cover:
            meta["poster"] = cover
        if not meta.get("description"):
            meta["description"] = _text(item.get("description"))
        if not meta.get("releaseInfo") and _text(item.get("remark")):
            meta["releaseInfo"] = _text(item.get("remark"))
        if not meta.get("url") and _text(item.get("link")):
            meta["url"] = _text(item.get("link"))
        metas.append(meta)
    return metas


def to_streams(value: Any) -> list[dict[str, Any]]:
    """把插件返回的播放地址转成 Stremio stream，只放行 http(s) 地址。"""
    if not isinstance(value, list):
        return []
    streams: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        url = _text(item.get("url"))
        if not re.match(r"^https?://", url, re.I):
            continue
        stream = dict(item)
        name = _text(item.get("name")) or "播放"
        stream["name"] = name
        stream["title"] = _text(item.get("title")) or name
        stream["url"] = url
        streams.append(stream)
    return streams


def _main() -> None:
    raw = sys.stdin.buffer.read()
    try:
        payload = json.loads(raw.decode("utf-8"))
    except ValueError:
        print(json.dumps({"ok": False, "error": "运行时参数无效"}, ensure_ascii=False))
        return
    print(json.dumps(_execute_payload(payload), ensure_ascii=False))


if __name__ == "__main__" and "--child" in sys.argv:
    _main()
