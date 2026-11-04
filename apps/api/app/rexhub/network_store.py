"""出站网络配置：代理与 GitHub 加速镜像。

代理开启后服务端所有 urllib 出站请求都走该代理；GitHub 加速镜像用于把
github.com / raw.githubusercontent.com 资源地址改写到镜像前缀。
配置保存在 data/network.json（0600），保存后立即生效，无需重启。
"""

from __future__ import annotations

import json
import os
import time
from typing import Any
from urllib.parse import urlparse
from urllib.request import ProxyHandler, Request, build_opener, urlopen

from app.rexhub import config

NETWORK_PATH = config.DATA_DIR / "network.json"

# GitHub 加速镜像预设：管理台以下拉框选择，不在这里的地址不接受
GITHUB_MIRROR_PRESETS = [
    ("", "不使用镜像（直连 GitHub）"),
    ("https://ghfast.top", "ghfast.top"),
    ("https://gh-proxy.com", "gh-proxy.com"),
    ("https://ghproxy.net", "ghproxy.net"),
    ("https://github.moeyy.xyz", "github.moeyy.xyz"),
    ("https://gh.llkk.cc", "gh.llkk.cc"),
]
GITHUB_MIRROR_URLS = {url for url, _ in GITHUB_MIRROR_PRESETS}

# 可按服务开关代理的出站任务
PROXY_TARGETS = {
    "plugins": "插件订阅",
    "search": "资源搜索",
    "115": "115 网盘",
    "shortdrama": "短剧聚合上游",
}

DEFAULT_PROXY_TARGETS = {"plugins"}

GITHUB_HOSTS = {
    "github.com",
    "raw.githubusercontent.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
}

# 管理台「测试连接」使用的探测地址
TEST_PROXY_URL = "https://www.gstatic.com/generate_204"
TEST_GITHUB_URL = "https://raw.githubusercontent.com/octocat/Hello-World/master/README"
TEST_TIMEOUT = 8
TEST_USER_AGENT = "RexHub-NetworkTest/1.0"


def _read() -> dict[str, Any]:
    try:
        data = json.loads(NETWORK_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    proxy = data.get("proxy")
    mirror = str(data.get("github_mirror") or "").strip().rstrip("/")
    if mirror not in GITHUB_MIRROR_URLS:
        mirror = ""
    return {
        "proxy": proxy if isinstance(proxy, dict) else {},
        "github_mirror": mirror,
    }


def _write(data: dict[str, Any]) -> None:
    config.ensure_data_dir()
    tmp = NETWORK_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(NETWORK_PATH)


def _http_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("请填写 http(s) 开头的完整地址")
    return value.rstrip("/")


def proxy_settings() -> dict[str, Any]:
    data = _read()["proxy"]
    saved = data.get("targets") if isinstance(data.get("targets"), dict) else {}
    targets = {
        key: bool(saved.get(key, key in DEFAULT_PROXY_TARGETS))
        for key in PROXY_TARGETS
    }
    return {
        "enabled": bool(data.get("enabled")),
        "url": str(data.get("url") or "").strip()[:300],
        "targets": targets,
    }


def save_proxy(enabled: bool, url: str, targets: list[str]) -> dict[str, Any]:
    target = (url or "").strip()[:300]
    if target:
        target = _http_url(target)
    if enabled and not target:
        raise ValueError("启用代理前请填写代理地址")
    picked = {key: key in targets for key in PROXY_TARGETS}
    data = _read()
    data["proxy"] = {
        "enabled": bool(enabled),
        "url": target,
        "targets": picked,
        "updated_at": int(time.time()),
    }
    _write(data)
    return proxy_settings()


def github_mirror() -> str:
    return _read()["github_mirror"]


def save_github_mirror(url: str) -> str:
    target = (url or "").strip().rstrip("/")
    if target not in GITHUB_MIRROR_URLS:
        raise ValueError("请从预设列表中选择 GitHub 加速地址")
    data = _read()
    data["github_mirror"] = target
    _write(data)
    return target


def rewrite_github(url: str) -> str:
    """把 GitHub 资源地址改写到选中的镜像；非 GitHub 地址原样返回。"""
    mirror = github_mirror()
    if not mirror:
        return url
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or parsed.netloc.lower() not in GITHUB_HOSTS:
        return url
    return f"{mirror}/{url}"


def proxy_in_use(target: str) -> bool:
    """当前配置下该服务是否真的走代理。"""
    settings = proxy_settings()
    return bool(settings["enabled"] and settings["url"] and settings["targets"].get(target))


def open_direct(request: Request, timeout: float):
    """不走代理直连，用于代理握手失败时的回退。"""
    return urlopen(request, timeout=timeout)


def open_url(request: Request, timeout: float, target: str):
    """按当前配置打开出站请求：该服务勾选了代理且代理已启用时走代理。"""
    settings = proxy_settings()
    if proxy_in_use(target):
        proxy_url = settings["url"]
        opener = build_opener(ProxyHandler({"http": proxy_url, "https": proxy_url}))
        return opener.open(request, timeout=timeout)
    return urlopen(request, timeout=timeout)


def _probe(request: Request, opener=None) -> dict[str, Any]:
    started = time.monotonic()
    if opener is None:
        with urlopen(request, timeout=TEST_TIMEOUT) as resp:
            code = getattr(resp, "status", None) or resp.getcode()
    else:
        with opener.open(request, timeout=TEST_TIMEOUT) as resp:
            code = getattr(resp, "status", None) or resp.getcode()
    return {
        "status": int(code or 0),
        "elapsed": int((time.monotonic() - started) * 1000),
    }


def test_proxy(url: str) -> dict[str, Any]:
    """经指定代理访问一个轻量地址，验证代理是否可用。"""
    target = (url or "").strip()[:300]
    if not target:
        raise ValueError("请先填写代理地址")
    target = _http_url(target)
    opener = build_opener(ProxyHandler({"http": target, "https": target}))
    request = Request(TEST_PROXY_URL, headers={"User-Agent": TEST_USER_AGENT})
    return _probe(request, opener)


def test_github_mirror(url: str) -> dict[str, Any]:
    """访问加速后的 GitHub 原始文件地址，验证镜像是否可用。"""
    mirror = (url or "").strip().rstrip("/")
    if mirror and mirror not in GITHUB_MIRROR_URLS:
        raise ValueError("请从预设列表中选择 GitHub 加速地址")
    target = f"{mirror}/{TEST_GITHUB_URL}" if mirror else TEST_GITHUB_URL
    request = Request(target, headers={"User-Agent": TEST_USER_AGENT})
    return _probe(request)
