"""插件运行时：HTTP / Shared / Isolated 三种模式。

- ``http``：外部已运行的 HTTP 插件，框架只登记地址、健康检查与调度；
  Docker 部署的插件也统一用这一模式，服务生命周期交给「服务管理」。
- ``shared``：所有 shared 插件由同一个 Node 宿主进程托管，按
  ``/<插件ID>/`` 前缀分流，适合大量轻量插件。
- ``isolated``：每个插件一个 Node 子进程，监听独立端口（默认，隔离性最好）。

本地运行模式都输出同一种 ``REXHUB_MODULE_READY`` 就绪行，Python 侧统一管理
端口、日志、崩溃自动重启与状态查询。
"""


import atexit
import json
import os
import shutil
import socket
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any
from urllib.parse import quote

from app.rexhub import network_store
from app.rexhub.plugin_framework import store

READY_TIMEOUT = 20.0
LOG_LIMIT = 400
READY_PREFIX = "REXHUB_MODULE_READY"
HOST = "127.0.0.1"
_ISOLATED_HOST = Path(__file__).resolve().parents[1] / "runtime" / "module_host.mjs"
_WIDGET_HOST = Path(__file__).resolve().parent / "widget_runtime" / "host.mjs"
_SHARED_HOST = Path(__file__).resolve().parent / "runtime" / "shared_host.mjs"
_SHARED_CONFIG = store.BASE_DIR / "shared.json"

_LOCK = threading.RLock()
_PROCS: dict[str, dict[str, Any]] = {}
_LOGS: dict[str, deque[str]] = {}
_ERRORS: dict[str, str] = {}
_WANTED: set[str] = set()
_RESTARTS: dict[str, int] = {}
_FAILS: dict[str, int] = {}
_NEXT_TRY: dict[str, float] = {}
_LAST_EXIT: dict[str, dict[str, int]] = {}
_SHARED: dict[str, Any] = {"proc": None, "port": 0, "plugins": []}
_NODE: str | None = None
_WATCHDOG: threading.Thread | None = None

atexit.register(lambda: stop_all())


def node_binary() -> str | None:
    global _NODE
    if _NODE:
        return _NODE
    candidates = [
        os.environ.get("NODE_BIN"),
        shutil.which("node"),
        str(Path.home() / ".local" / "node" / "bin" / "node"),
        "/usr/local/bin/node",
        "/opt/homebrew/bin/node",
        "/usr/bin/node",
    ]
    for item in candidates:
        if not item:
            continue
        path = Path(item)
        if path.is_file() and os.access(path, os.X_OK):
            _NODE = str(path)
            return _NODE
    return None


def python_binary() -> str | None:
    candidates = [
        os.environ.get("PYTHON_BIN"),
        shutil.which("python3"),
        shutil.which("python"),
        "/usr/bin/python3",
    ]
    for item in candidates:
        if not item:
            continue
        path = Path(item)
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def _pick_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])
    finally:
        sock.close()


def _port_open(port: int) -> bool:
    if not port:
        return False
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.4):
            return True
    except OSError:
        return False


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def _log(plugin_id: str, line: str) -> None:
    text = line.rstrip("\n")
    if text:
        _LOGS.setdefault(plugin_id, deque(maxlen=LOG_LIMIT)).append(text)


def logs(plugin_id: str, limit: int = 120) -> list[str]:
    with _LOCK:
        items = list(_LOGS.get(plugin_id) or ())
    return items[-max(1, min(limit, LOG_LIMIT)) :]


def _pid_file(row: dict[str, Any]) -> Path:
    return store.install_path(row) / "plugin.pid"


def _read_pid(row: dict[str, Any]) -> int:
    for name in ("plugin.pid", "module.pid"):
        try:
            value = int((store.install_path(row) / name).read_text("utf-8").strip())
            if value:
                return value
        except (OSError, ValueError):
            continue
    return 0


def _runtime(row: dict[str, Any]) -> dict[str, Any]:
    value = row.get("runtime")
    return value if isinstance(value, dict) else {}


def _urls(port: int) -> list[dict[str, str]]:
    if not port:
        return []
    return [{"label": "本机", "url": f"http://127.0.0.1:{port}"}]


def _entry(plugin_id: str) -> dict[str, Any] | None:
    entry = _PROCS.get(plugin_id)
    if entry and entry["proc"].poll() is None:
        return entry
    return None


def _adopted(row: dict[str, Any], port: int) -> int:
    pid = _read_pid(row)
    if pid and _pid_alive(pid) and (not port or _port_open(port)):
        return pid
    return 0


def status(row: dict[str, Any]) -> dict[str, Any]:
    plugin_id = str(row.get("id") or "")
    runtime = _runtime(row)
    mode = str(runtime.get("type") or "isolated")
    with _LOCK:
        restarts = _RESTARTS.get(plugin_id, 0)
        last_exit = _LAST_EXIT.get(plugin_id) or None
        error = _ERRORS.get(plugin_id, "")
        entry = _entry(plugin_id)
    if mode == "http":
        base = str(runtime.get("base_url") or "").rstrip("/")
        running = bool(base and row.get("enabled"))
        return {
            **row,
            "running": running,
            "pid": 0,
            "port": 0,
            "base_url": base if running else "",
            "started_at": None,
            "uptime": 0,
            "restarts": restarts,
            "last_exit": last_exit,
            "adopted": False,
            "urls": [{"label": "外部", "url": base}] if running else [],
            "error": "",
        }
    if mode == "shared":
        shared = _SHARED.get("proc")
        running = shared is not None and shared.poll() is None
        info = shared_plugin_base(row)
        return {
            **row,
            "running": bool(running),
            "pid": shared.pid if running else 0,
            "port": int(_SHARED.get("port") or 0),
            "base_url": info["base"] if running else "",
            "started_at": _SHARED.get("started_at"),
            "uptime": 0,
            "restarts": restarts,
            "last_exit": last_exit,
            "adopted": False,
            "urls": _urls(int(_SHARED.get("port") or 0)) if running else [],
            "error": "" if running else (error or "共享运行时未启动"),
        }
    if entry is not None:
        port = int(entry.get("port") or 0)
        started_at = entry.get("started_at")
        return {
            **row,
            "running": True,
            "pid": entry["proc"].pid,
            "port": port,
            "base_url": f"http://127.0.0.1:{port}" if port else "",
            "started_at": started_at,
            "uptime": max(0, int(time.time()) - int(started_at or 0)),
            "restarts": restarts,
            "last_exit": last_exit,
            "adopted": False,
            "urls": _urls(port),
            "error": "",
        }
    port = int(runtime.get("port") or 0)
    pid = _adopted(row, port)
    if pid:
        return {
            **row,
            "running": True,
            "pid": pid,
            "port": port,
            "base_url": f"http://127.0.0.1:{port}" if port else "",
            "started_at": None,
            "uptime": 0,
            "restarts": restarts,
            "last_exit": last_exit,
            "adopted": True,
            "urls": _urls(port) if port else [],
            "error": "",
        }
    return {
        **row,
        "running": False,
        "pid": 0,
        "port": port,
        "base_url": "",
        "started_at": None,
        "uptime": 0,
        "restarts": restarts,
        "last_exit": last_exit,
        "adopted": False,
        "urls": _urls(port) if port else [],
        "error": error,
    }


def shared_plugin_base(row: dict[str, Any]) -> dict[str, str]:
    port = int(_SHARED.get("port") or 0)
    if not port:
        return {"base": "", "root": ""}
    return {
        "root": f"http://127.0.0.1:{port}",
        "base": f"http://127.0.0.1:{port}/p/{quote(str(row['id']), safe='')}",
    }


# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------


def _tmdb_api_key() -> str:
    try:
        from app.core import settings_store

        raw = settings_store.get_setting(settings_store.TMDB_KEY) or {}
        if isinstance(raw, dict):
            return str(raw.get("apiKey") or raw.get("api_key") or raw.get("key") or "").strip()
    except (ImportError, RuntimeError, ValueError, AttributeError, TypeError):
        pass
    return ""


def _plugin_env(row: dict[str, Any], port: int) -> dict[str, str]:
    config = row.get("config") if isinstance(row.get("config"), dict) else {}
    runtime = _runtime(row)
    # 只给插件最小宿主环境，避免把数据库密码、令牌等进程环境泄漏给插件
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "TZ": os.environ.get("TZ", ""),
        "TMPDIR": os.environ.get("TMPDIR", ""),
    }
    env["REXHUB_PLUGIN_ID"] = str(row["id"])
    env["REXHUB_PLUGIN_PORT"] = str(port)
    env["REXHUB_PLUGIN_HOST"] = HOST
    env["REXHUB_PLUGIN_ENV"] = json.dumps(config, ensure_ascii=False)
    env["REXHUB_PLUGIN_PERMISSIONS"] = json.dumps(row.get("permissions") or [], ensure_ascii=False)
    env["REXHUB_PLUGIN_DATA_DIR"] = str(store.data_dir(str(row["id"])))
    env["REXHUB_PLUGIN_SHARED_CACHE"] = str(store.PLUGIN_DATA_DIR / "_shared_cache.json")
    if str(runtime.get("engine") or "") == "widget-js":
        tmdb_key = _tmdb_api_key()
        if tmdb_key:
            env["REXHUB_TMDB_API_KEY"] = tmdb_key
    # 兼容旧模块宿主契约
    env["REXHUB_MODULE_ID"] = str(row["id"])
    env["REXHUB_MODULE_PORT"] = str(port)
    env["REXHUB_MODULE_HOST"] = HOST
    env["REXHUB_MODULE_ENV"] = env["REXHUB_PLUGIN_ENV"]
    for key, value in (runtime.get("env") or {}).items():
        env[str(key)] = str(value)
    proxy = network_store.proxy_url() if row.get("proxy") else ""
    if proxy:
        env["REXHUB_PLUGIN_PROXY"] = proxy
        env["HTTP_PROXY"] = proxy
        env["HTTPS_PROXY"] = proxy
        env["ALL_PROXY"] = proxy
        env["NO_PROXY"] = "localhost,127.0.0.1,::1"
    return env


def _spawn(plugin_id: str, command: list[str], cwd: Path, env: dict[str, str]) -> subprocess.Popen:
    kwargs: dict[str, Any] = {}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    return subprocess.Popen(
        command,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        **kwargs,
    )


def _reader(plugin_id: str, entry: dict[str, Any]) -> None:
    proc: subprocess.Popen = entry["proc"]
    ready: threading.Event = entry["ready"]
    assert proc.stdout is not None
    for line in proc.stdout:
        _log(plugin_id, line)
        if line.startswith(READY_PREFIX):
            try:
                payload = json.loads(line[len(READY_PREFIX) :].strip())
                entry["port"] = int(payload.get("port") or entry.get("port") or 0)
            except (ValueError, TypeError):
                pass
            ready.set()
    code = proc.wait()
    ready.set()
    with _LOCK:
        current = _PROCS.get(plugin_id)
        if current is entry:
            _PROCS.pop(plugin_id, None)
            _pid_file(entry["row"]).unlink(missing_ok=True)
            _LAST_EXIT[plugin_id] = {"code": int(code), "at": int(time.time())}
            wanted = plugin_id in _WANTED
        else:
            wanted = False
    if wanted:
        _log(plugin_id, f"[运行时] 进程退出（code={code}），准备重启")
        threading.Thread(
            target=_restart_later,
            args=(plugin_id,),
            name=f"plugin-restart-{plugin_id}",
            daemon=True,
        ).start()


def _restart_later(plugin_id: str, delay: float = 3.0) -> None:
    if delay:
        time.sleep(delay)
    with _LOCK:
        if plugin_id not in _WANTED or _entry(plugin_id) is not None:
            return
        if _NEXT_TRY.get(plugin_id, 0) > time.time():
            return
        fails = _FAILS.get(plugin_id, 0)
    try:
        row = store.get_plugin(plugin_id)
    except ValueError:
        with _LOCK:
            _WANTED.discard(plugin_id)
        return
    if not row.get("enabled"):
        with _LOCK:
            _WANTED.discard(plugin_id)
        return
    try:
        start(row)
    except (RuntimeError, ValueError) as exc:
        with _LOCK:
            fails += 1
            _FAILS[plugin_id] = fails
            _NEXT_TRY[plugin_id] = time.time() + min(300, 10 * 2 ** min(fails - 1, 5))
        _log(plugin_id, f"[运行时] 重启失败：{exc}")
        return
    with _LOCK:
        _RESTARTS[plugin_id] = _RESTARTS.get(plugin_id, 0) + 1
        _FAILS.pop(plugin_id, None)
        _NEXT_TRY.pop(plugin_id, None)


def _ensure_watchdog() -> None:
    global _WATCHDOG
    with _LOCK:
        if _WATCHDOG is not None and _WATCHDOG.is_alive():
            return
        _WATCHDOG = threading.Thread(target=_watchdog, name="plugins-watchdog", daemon=True)
    _WATCHDOG.start()


def _watchdog() -> None:
    while True:
        time.sleep(10)
        with _LOCK:
            wanted = [pid for pid in _WANTED if _entry(pid) is None]
        for plugin_id in wanted:
            if _NEXT_TRY.get(plugin_id, 0) > time.time():
                continue
            try:
                row = store.get_plugin(plugin_id)
            except ValueError:
                with _LOCK:
                    _WANTED.discard(plugin_id)
                continue
            if not row.get("enabled"):
                with _LOCK:
                    _WANTED.discard(plugin_id)
                continue
            info = status(row)
            if info.get("running"):
                continue
            threading.Thread(
                target=_restart_later,
                args=(plugin_id,),
                name=f"plugin-watchdog-{plugin_id}",
                daemon=True,
            ).start()


def _wait_ready(proc: subprocess.Popen, ready: threading.Event) -> None:
    deadline = time.time() + READY_TIMEOUT
    while time.time() < deadline:
        if ready.wait(0.2) or proc.poll() is not None:
            break


def _register_process(row: dict[str, Any], proc: subprocess.Popen, port: int, label: str) -> dict[str, Any]:
    plugin_id = str(row["id"])
    entry = {
        "proc": proc,
        "port": port,
        "started_at": int(time.time()),
        "ready": threading.Event(),
        "row": row,
    }
    with _LOCK:
        _PROCS[plugin_id] = entry
        _ERRORS.pop(plugin_id, None)
    _pid_file(row).parent.mkdir(parents=True, exist_ok=True)
    _pid_file(row).write_text(str(proc.pid), "utf-8")
    threading.Thread(
        target=_reader, args=(plugin_id, entry), name=f"plugin-{plugin_id}", daemon=True
    ).start()
    _wait_ready(proc, entry["ready"])
    if proc.poll() is not None:
        with _LOCK:
            _PROCS.pop(plugin_id, None)
            _ERRORS[plugin_id] = f"启动失败：{' | '.join(logs(plugin_id, 4)) or '进程已退出'}"
        raise RuntimeError(_ERRORS[plugin_id])
    if not entry["ready"].is_set() and not _port_open(int(entry["port"])):
        _stop_locked(plugin_id)
        message = f"插件在 {int(READY_TIMEOUT)} 秒内未就绪"
        _ERRORS[plugin_id] = message
        raise RuntimeError(message)
    _log(plugin_id, f"[运行时] 已启动（{label}），端口 {entry['port']}")
    _FAILS.pop(plugin_id, None)
    _NEXT_TRY.pop(plugin_id, None)
    return status(row)


def _resolve_port(row: dict[str, Any], runtime: dict[str, Any]) -> int | None:
    """分配端口：显式端口被占用时尝试接管，接管成功返回 None（调用方直接返回状态）。"""
    requested = int(runtime.get("port") or 0)
    port = requested or _pick_port()
    if requested and _port_open(port):
        if _adopted(row, port):
            return None
        raise RuntimeError(f"端口 {port} 已被占用")
    return port


def _start_isolated(row: dict[str, Any]) -> dict[str, Any]:
    plugin_id = str(row["id"])
    binary = node_binary()
    if not binary:
        raise RuntimeError("未找到 Node（可通过 NODE_BIN 指定路径）")
    runtime = _runtime(row)
    entrypoint = str(row.get("entrypoint") or runtime.get("entrypoint") or "module.mjs")
    base = store.install_path(row)
    source = base / entrypoint
    if not source.is_file():
        raise RuntimeError(f"插件入口文件不存在：{entrypoint}")
    port = _resolve_port(row, runtime)
    if port is None:
        return status(row)
    env = _plugin_env(row, port)
    proc = _spawn(plugin_id, [binary, str(_ISOLATED_HOST), str(source)], base, env)
    return _register_process(row, proc, port, "isolated")


def _start_widget(row: dict[str, Any]) -> dict[str, Any]:
    plugin_id = str(row["id"])
    binary = node_binary()
    if not binary:
        raise RuntimeError("未找到 Node（可通过 NODE_BIN 指定路径）")
    runtime = _runtime(row)
    base = store.install_path(row)
    source = base / str(row.get("entrypoint") or runtime.get("entrypoint") or "plugin.js")
    if not source.is_file():
        raise RuntimeError(f"插件 JS 入口不存在：{source.name}")
    port = _resolve_port(row, runtime)
    if port is None:
        return status(row)
    env = _plugin_env(row, port)
    env["REXHUB_PLUGIN_FILE"] = str(source)
    proc = _spawn(plugin_id, [binary, str(_WIDGET_HOST)], base, env)
    return _register_process(row, proc, port, "widget-js")


def _start_process(row: dict[str, Any]) -> dict[str, Any]:
    plugin_id = str(row["id"])
    runtime = _runtime(row)
    engine = str(runtime.get("engine") or "process")
    base = store.install_path(row)
    entrypoint = str(row.get("entrypoint") or runtime.get("entrypoint") or "")
    command = runtime.get("command")
    if isinstance(command, list) and command:
        args = [str(item) for item in command]
    elif engine == "python":
        binary = python_binary()
        if not binary:
            raise RuntimeError("未找到 python3（可通过 PYTHON_BIN 指定路径）")
        args = [binary, entrypoint]
    else:
        binary = node_binary()
        if not binary:
            raise RuntimeError("未找到 Node（可通过 NODE_BIN 指定路径）")
        args = [binary, entrypoint]
    if entrypoint and not (base / entrypoint).is_file():
        raise RuntimeError(f"插件入口文件不存在：{entrypoint}")
    port = _resolve_port(row, runtime)
    if port is None:
        return status(row)
    env = _plugin_env(row, port)
    proc = _spawn(plugin_id, args, base, env)
    return _register_process(row, proc, port, f"process/{engine}")


def _shared_config(exclude: str = "") -> list[dict[str, Any]]:
    plugins = []
    for row in store.list_plugins():
        runtime = _runtime(row)
        if str(runtime.get("type") or "isolated") != "shared" or not row.get("enabled"):
            continue
        if exclude and str(row.get("id")) == exclude:
            continue
        path = store.install_path(row) / str(row.get("entrypoint") or runtime.get("entrypoint") or "module.mjs")
        if path.is_file():
            plugins.append({"id": row["id"], "entrypoint": str(path)})
    return plugins


def _start_shared_host() -> None:
    binary = node_binary()
    if not binary:
        raise RuntimeError("未找到 Node（可通过 NODE_BIN 指定路径）")
    with _LOCK:
        proc = _SHARED.get("proc")
        if proc is not None and proc.poll() is None:
            return
    plugins = _shared_config()
    port = int(_SHARED.get("port") or 0) or _pick_port()
    _SHARED_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    _SHARED_CONFIG.write_text(
        json.dumps({"port": port, "plugins": plugins}, ensure_ascii=False, indent=2),
        "utf-8",
    )
    # 共享宿主会承载第三方插件，只透传运行必需的最小环境，避免泄露数据库密码等密钥
    env = {
        key: value
        for key in ("PATH", "HOME", "LANG", "LC_ALL", "TZ", "TMPDIR", "NODE_PATH")
        if (value := os.environ.get(key)) is not None
    }
    env["REXHUB_SHARED_CONFIG"] = str(_SHARED_CONFIG)
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "REXHUB_PLUGIN_PROXY", "NO_PROXY"):
        env.pop(key, None)
    shared_proxy = any(
        row.get("proxy")
        for row in store.list_plugins()
        if str((_runtime(row)).get("type") or "isolated") == "shared"
    )
    proxy = network_store.proxy_url() if shared_proxy else ""
    if proxy:
        env["REXHUB_PLUGIN_PROXY"] = proxy
        env["HTTP_PROXY"] = proxy
        env["HTTPS_PROXY"] = proxy
        env["ALL_PROXY"] = proxy
        env["NO_PROXY"] = "localhost,127.0.0.1,::1"
    proc = _spawn("__shared__", [binary, str(_SHARED_HOST)], _SHARED_CONFIG.parent, env)
    entry = {"proc": proc, "port": port, "ready": threading.Event()}
    with _LOCK:
        _SHARED.update({"proc": proc, "port": port, "plugins": plugins, "started_at": int(time.time())})
    threading.Thread(
        target=_shared_reader, args=(entry,), name="plugin-shared-host", daemon=True
    ).start()
    _wait_ready(proc, entry["ready"])
    if proc.poll() is not None:
        raise RuntimeError("共享运行时启动失败")


def _shared_reader(entry: dict[str, Any]) -> None:
    proc: subprocess.Popen = entry["proc"]
    assert proc.stdout is not None
    for line in proc.stdout:
        _log("__shared__", line)
        if line.startswith(READY_PREFIX):
            try:
                payload = json.loads(line[len(READY_PREFIX) :].strip())
                entry["port"] = int(payload.get("port") or entry.get("port") or 0)
                with _LOCK:
                    _SHARED["port"] = entry["port"]
            except (ValueError, TypeError):
                pass
            entry["ready"].set()
    proc.wait()
    with _LOCK:
        if _SHARED.get("proc") is proc:
            _SHARED.update({"proc": None, "port": 0})


def _start_shared(row: dict[str, Any]) -> dict[str, Any]:
    binary = node_binary()
    if not binary:
        raise RuntimeError("未找到 Node（可通过 NODE_BIN 指定路径）")
    plugins = _shared_config()
    with _LOCK:
        running = list(_SHARED.get("plugins") or [])
    if _SHARED.get("proc") is None or _SHARED["proc"].poll() is not None:
        _start_shared_host()
    elif [item["id"] for item in running] != [item["id"] for item in plugins]:
        _stop_shared_host()
        _start_shared_host()
    _log(str(row["id"]), "[运行时] 已挂载到共享运行时")
    _FAILS.pop(str(row["id"]), None)
    _NEXT_TRY.pop(str(row["id"]), None)
    return status(row)


def _stop_shared_host() -> None:
    with _LOCK:
        proc = _SHARED.get("proc")
        _SHARED.update({"proc": None, "port": 0, "plugins": []})
    if proc is not None and proc.poll() is None:
        _terminate(proc)


def start(row: dict[str, Any]) -> dict[str, Any]:
    plugin_id = str(row["id"])
    runtime = _runtime(row)
    with _LOCK:
        _WANTED.add(plugin_id)
    mode = str(runtime.get("type") or "isolated")
    engine = str(runtime.get("engine") or "node")
    if mode == "http":
        return status(row)
    if engine == "widget-js":
        return _start_widget(row)
    if engine in ("python", "process") or runtime.get("command"):
        return _start_process(row)
    if mode == "shared":
        return _start_shared(row)
    return _start_isolated(row)


def _stop_locked(plugin_id: str) -> None:
    """停止单个插件进程（不改变期望状态），用于启动失败后的清理。"""
    with _LOCK:
        entry = _PROCS.pop(plugin_id, None)
    if entry is not None:
        _terminate(entry["proc"])
        _pid_file(entry.get("row") or {"id": plugin_id}).unlink(missing_ok=True)


def _terminate(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        if os.name == "nt":
            proc.terminate()
        else:
            os.killpg(os.getpgid(proc.pid), 15)
    except (ProcessLookupError, PermissionError, OSError):
        proc.terminate()
    try:
        proc.wait(timeout=6)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "nt":
                proc.kill()
            else:
                os.killpg(os.getpgid(proc.pid), 9)
        except (ProcessLookupError, PermissionError, OSError):
            proc.kill()


def stop(plugin_id: str) -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    mode = str(_runtime(row).get("type") or "isolated")
    with _LOCK:
        _WANTED.discard(plugin_id)
        _FAILS.pop(plugin_id, None)
        _NEXT_TRY.pop(plugin_id, None)
        entry = _PROCS.pop(plugin_id, None)
    if mode == "http":
        return status(row)
    if entry is not None:
        _terminate(entry["proc"])
        _pid_file(row).unlink(missing_ok=True)
    else:
        pid = _read_pid(row)
        if pid and _pid_alive(pid):
            try:
                if os.name == "nt":
                    os.kill(pid, 15)
                else:
                    os.killpg(os.getpgid(pid), 15)
            except (ProcessLookupError, PermissionError, OSError):
                pass
        _pid_file(row).unlink(missing_ok=True)
    mode = str(_runtime(row).get("type") or "isolated")
    if mode == "shared":
        # 只重启共享宿主，避免停用一个插件把其他 shared 插件一起带停
        if _shared_config(exclude=plugin_id):
            _stop_shared_host()
            try:
                _start_shared_host()
            except (RuntimeError, ValueError) as exc:
                _log(plugin_id, f"[运行时] 共享宿主重启失败：{exc}")
    _ERRORS.pop(plugin_id, None)
    _log(plugin_id, "[运行时] 已停止")
    return status(store.get_plugin(plugin_id))


def restart(row: dict[str, Any]) -> dict[str, Any]:
    stop(str(row["id"]))
    return start(row)


def base_url(row: dict[str, Any]) -> str:
    """返回插件 HTTP 根地址；未运行则按需启动。"""
    info = status(row)
    if not info.get("running"):
        info = start(row)
    base = str(info.get("base_url") or "")
    if not base:
        raise RuntimeError("插件未运行")
    return base.rstrip("/")


def stop_all() -> None:
    with _LOCK:
        _WANTED.clear()
        ids = list(_PROCS.keys())
        shared = _SHARED.get("proc")
    for plugin_id in ids:
        try:
            stop(plugin_id)
        except (OSError, RuntimeError, ValueError):
            pass
    if shared is not None:
        _stop_shared_host()
    for row in store.list_plugins():
        pid = _read_pid(row)
        if pid and _pid_alive(pid):
            try:
                stop(str(row["id"]))
            except (OSError, RuntimeError, ValueError):
                pass


def autostart() -> None:
    """后台启动所有已启用插件。"""
    def runner() -> None:
        _ensure_watchdog()
        for row in store.list_plugins():
            if not row.get("enabled"):
                continue
            with _LOCK:
                _WANTED.add(str(row["id"]))
            try:
                start(row)
            except (RuntimeError, ValueError) as exc:
                _log(str(row["id"]), f"[运行时] 自动启动失败：{exc}")

    threading.Thread(target=runner, name="plugins-autostart", daemon=True).start()
