"""出站网络配置：代理、GitHub API 与加速镜像。

代理开启后服务端所有 urllib 出站请求都走该代理；GitHub 加速镜像用于把
github.com / raw.githubusercontent.com 资源地址改写到镜像前缀；GitHub API
地址与 Token 用于图标库预览等 GitHub 接口调用。
配置保存在 data/network.json（0600），保存后立即生效，无需重启。
"""


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

DEFAULT_GITHUB_API = "https://api.github.com"

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
    api = str(data.get("github_api") or "").strip().rstrip("/")
    parsed_api = urlparse(api)
    if api and (parsed_api.scheme not in {"http", "https"} or not parsed_api.netloc):
        api = ""
    return {
        "proxy": proxy if isinstance(proxy, dict) else {},
        "github_mirror": mirror,
        "github_api": api or DEFAULT_GITHUB_API,
        "github_token": str(data.get("github_token") or "").strip()[:500],
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


def github_mirror() -> str:
    return _read()["github_mirror"]


def github_api() -> str:
    """GitHub API 基址，默认官方地址。"""
    return _read()["github_api"]


def github_token() -> str:
    return _read()["github_token"]


def github_headers() -> dict[str, str]:
    """GitHub 接口鉴权头；Token 只发给该 API 主机，不要用于镜像/CDN。"""
    token = github_token()
    return {"Authorization": f"Bearer {token}"} if token else {}


def github_settings() -> dict[str, Any]:
    """管理台展示用：Token 只返回是否已配置与脱敏提示。"""
    data = _read()
    token = data["github_token"]
    hint = ""
    if token:
        hint = f"{token[:4]}…{token[-4:]}" if len(token) > 10 else "****"
    return {
        "api_url": data["github_api"],
        "token_set": bool(token),
        "token_hint": hint,
        "mirror": data["github_mirror"],
        "mirror_presets": [
            {"url": url, "label": label} for url, label in GITHUB_MIRROR_PRESETS
        ],
    }


def save_github(
    *,
    api_url: str | None = None,
    token: str | None = None,
    mirror: str | None = None,
) -> dict[str, Any]:
    """保存 GitHub 配置；None 表示不修改，空 Token 保留原值。"""
    data = _read()
    if api_url is not None:
        raw = api_url.strip()
        data["github_api"] = _http_url(raw) if raw else ""
    if token is not None and token.strip():
        data["github_token"] = token.strip()[:500]
    if mirror is not None:
        next_mirror = mirror.strip().rstrip("/")
        if next_mirror not in GITHUB_MIRROR_URLS:
            raise ValueError("请选择列表中的 GitHub 加速镜像")
        data["github_mirror"] = next_mirror
    _write(data)
    return github_settings()


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


def _app_proxy_url() -> str:
    """面板「网络代理」里保存的全局代理（与抓取模块共用同一份配置）。"""
    try:
        from app.core.outbound_http import resolve_scrape_proxy_url

        return resolve_scrape_proxy_url()
    except (ImportError, RuntimeError, ValueError, AttributeError):
        return ""


def proxy_url_for(target: str) -> str:
    """该服务应使用的代理地址（供插件运行时等非 urllib 通道使用）。"""

    if target == "plugins":
        return _app_proxy_url()
    if not proxy_in_use(target):
        return ""
    url = proxy_settings()["url"]
    return url if url.startswith(("http://", "https://")) else ""


def proxy_url() -> str:
    """全局代理地址（不看服务开关），供插件运行时按单插件开关取用。"""
    return _app_proxy_url()


def open_direct(request: Request, timeout: float):
    """不走代理直连，用于代理握手失败时的回退。"""
    return urlopen(request, timeout=timeout)


def open_plugin_url(request: Request, timeout: float):
    """插件仓库索引与安装文件：只要全局代理开启就走代理。"""
    url = proxy_url()
    if url:
        opener = build_opener(ProxyHandler({"http": url, "https": url}))
        return opener.open(request, timeout=timeout)
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


