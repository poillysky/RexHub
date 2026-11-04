"""NAS Docker 服务聚合。

通过 Docker Engine API 读取宿主机容器列表并支持启停，不引入额外依赖。
默认连接 unix:///var/run/docker.sock，可用 REXHUB_DOCKER_HOST 覆盖
（支持 unix:///path/to/docker.sock 与 tcp://host:2375）。
"""

from __future__ import annotations

import http.client
import json
import os
import re
import socket
import time
from typing import Any

DOCKER_HOST = os.environ.get("REXHUB_DOCKER_HOST", "unix:///var/run/docker.sock")

REQ_TIMEOUT = 8
ACTION_TIMEOUT = 30
CACHE_TTL = 3

# 容器 ID 只允许 Docker 认可的字符集，避免拼进请求路径时被注入其他路径段。
CONTAINER_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")

_cache: dict[str, Any] = {"at": 0.0, "data": None}

ACTIONS = ("start", "stop", "restart", "pause", "unpause")


class DockerError(RuntimeError):
    pass


class _UnixHTTPConnection(http.client.HTTPConnection):
    """通过 unix socket 发送 HTTP 请求。"""

    def __init__(self, socket_path: str, timeout: float = REQ_TIMEOUT) -> None:
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:  # type: ignore[override]
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect(self.socket_path)
        except OSError as exc:
            sock.close()
            raise DockerError("未检测到 Docker 服务，请确认已挂载 /var/run/docker.sock") from exc
        self.sock = sock


def _connection(timeout: float) -> http.client.HTTPConnection:
    if DOCKER_HOST.startswith("unix://"):
        return _UnixHTTPConnection(DOCKER_HOST[len("unix://"):], timeout)
    raw = DOCKER_HOST.split("://", 1)[-1]
    host, _, port = raw.partition(":")
    return http.client.HTTPConnection(host, int(port or 2375), timeout=timeout)


def _error_text(raw: bytes) -> str:
    try:
        data = json.loads(raw)
    except ValueError:
        return raw.decode("utf-8", "replace").strip()
    if isinstance(data, dict):
        return str(data.get("message") or "")
    return ""


def _request(method: str, path: str, timeout: float = REQ_TIMEOUT) -> Any:
    conn = _connection(timeout)
    try:
        conn.request(method, path, body=b"" if method == "POST" else None)
        resp = conn.getresponse()
        raw = resp.read()
        if resp.status >= 400:
            detail = _error_text(raw) or f"HTTP {resp.status}"
            raise DockerError(detail)
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return raw.decode("utf-8", "replace")
    except DockerError:
        raise
    except (OSError, socket.timeout) as exc:
        raise DockerError("连接 Docker 服务超时") from exc
    finally:
        conn.close()


def _ports(items: list[dict]) -> list[str]:
    seen: list[str] = []
    for item in items:
        public = item.get("PublicPort")
        private = item.get("PrivatePort")
        proto = item.get("Type") or "tcp"
        if public and private:
            text = f"{public}→{private}/{proto}"
        elif private:
            text = f"{private}/{proto}"
        else:
            continue
        if text not in seen:
            seen.append(text)
    return seen


def _normalize(item: dict) -> dict[str, Any]:
    names = [str(n).lstrip("/") for n in (item.get("Names") or [])]
    labels = item.get("Labels") or {}
    state = str(item.get("State") or "unknown")
    return {
        "id": str(item.get("Id") or "")[:12],
        "name": names[0] if names else str(item.get("Id") or "")[:12],
        "image": str(item.get("Image") or ""),
        "state": state,
        "status": str(item.get("Status") or ""),
        "ports": _ports(item.get("Ports") or []),
        "project": str(labels.get("com.docker.compose.project") or ""),
        "service": str(labels.get("com.docker.compose.service") or ""),
        "created": int(item.get("Created") or 0),
    }


def containers(force: bool = False) -> dict[str, Any]:
    """返回容器列表与汇总，失败时 ok=False 并带可读提示。"""
    now = time.time()
    if not force and _cache["data"] is not None and now - _cache["at"] < CACHE_TTL:
        return _cache["data"]

    try:
        items = _request("GET", "/containers/json?all=1")
        if not isinstance(items, list):
            raise DockerError("Docker 返回数据格式异常")
    except DockerError as exc:
        result = {"ok": False, "message": str(exc), "containers": [], "summary": {}}
        _cache.update({"at": now, "data": result})
        return result

    rows = sorted(
        (_normalize(item) for item in items),
        key=lambda row: (row["state"] != "running", row["name"].lower()),
    )
    running = sum(1 for row in rows if row["state"] == "running")
    projects = {row["project"] for row in rows if row["project"]}
    result = {
        "ok": True,
        "message": "",
        "containers": [row | {"running": row["state"] == "running"} for row in rows],
        "summary": {
            "total": len(rows),
            "running": running,
            "stopped": len(rows) - running,
            "projects": len(projects),
            "host": DOCKER_HOST,
        },
    }
    _cache.update({"at": now, "data": result})
    return result


def act(container_id: str, action: str) -> dict[str, Any]:
    if action not in ACTIONS:
        raise DockerError("不支持的操作")
    if not container_id:
        raise DockerError("缺少容器 ID")
    if not CONTAINER_ID_PATTERN.match(container_id):
        raise DockerError("容器 ID 格式不正确")
    _request("POST", f"/containers/{container_id}/{action}", timeout=ACTION_TIMEOUT)
    _cache.update({"at": 0.0, "data": None})
    return containers(force=True)
