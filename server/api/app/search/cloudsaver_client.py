"""CloudSaver 网盘搜索客户端（外挂 Docker 实例）。"""


import html
import logging
import re
import time
from typing import Any
from urllib.parse import urlparse

import httpx

import app.core.settings_store as settings_store
from app.core.service_config import normalize_base, read_service

log = logging.getLogger("app.cloudsaver")

CLOUDSAVER_KEY = "cloudsaver"
DEFAULT_BASE_URL = ""
DEFAULT_TIMEOUT_S = 60.0

CLOUD_TYPE_LABELS: dict[str, str] = {
    "baidu": "百度",
    "aliyun": "阿里",
    "quark": "夸克",
    "uc": "UC",
    "xunlei": "迅雷",
    "tianyi": "天翼",
    "mobile": "移动",
    "115": "115",
    "123": "123",
    "pikpak": "PikPak",
    "guangya": "光鸭",
    "magnet": "磁力",
    "ed2k": "ED2K",
}


def cloud_label(type_key: str) -> str:
    k = str(type_key or "").strip().lower()
    return CLOUD_TYPE_LABELS.get(k) or (type_key or "其他")


# 游标翻页：单次「加载更多」最多翻几轮、单关键词累计上限、缓存条目与 TTL
_POOL_ROUNDS = 3
_POOL_ITEMS_MAX = 200
_POOL_MAX = 32
_POOL_TTL_S = 120.0

_cloud_pools: dict[str, tuple[float, dict[str, Any]]] = {}

_TAG_RE = re.compile(r"<[^>]+>")
_AMP_RE = re.compile(r"&amp;", re.I)


class CloudSaverError(Exception):
    pass


def get_config(*, include_secrets: bool = False) -> dict[str, Any]:
    raw, cfg = read_service(
        CLOUDSAVER_KEY,
        default_timeout=DEFAULT_TIMEOUT_S,
        timeout_min=8.0,
        timeout_max=180.0,
    )
    cfg["baseUrl"] = normalize_base(cfg["baseUrl"])
    password = str(raw.get("password") or "")
    cfg["username"] = str(raw.get("username") or "").strip()
    cfg["hasPassword"] = bool(password)
    if include_secrets:
        cfg["password"] = password
        cfg["token"] = str(raw.get("token") or "").strip()
    return cfg


def _save_token(token: str) -> None:
    # 与「保存配置」共用一把读-改-写锁：登录期间管理员刚存的新地址/密码不能被旧快照覆盖
    settings_store.update_setting(
        CLOUDSAVER_KEY,
        lambda prev: {**prev, "token": str(token or "").strip()},
    )


def _strip_html(s: str) -> str:
    t = _TAG_RE.sub("", str(s or ""))
    return html.unescape(t).strip()


def _normalize_cloud_type(type_key: str, url: str = "") -> str:
    t = str(type_key or "").strip().lower()
    u = str(url or "").strip().lower()
    aliases = {
        "quark": "quark",
        "baidu": "baidu",
        "aliyun": "aliyun",
        "ali": "aliyun",
        "alipan": "aliyun",
        "uc": "uc",
        "xunlei": "xunlei",
        "tianyi": "tianyi",
        "cloud189": "tianyi",
        "115": "115",
        "pan115": "115",
        "share115": "115",
        "123": "123",
        "pikpak": "pikpak",
        "magnet": "magnet",
        "ed2k": "ed2k",
    }
    if t in aliases:
        return aliases[t]
    if u.startswith("magnet:"):
        return "magnet"
    if u.startswith("ed2k:"):
        return "ed2k"
    if "pan.quark.cn" in u:
        return "quark"
    if "pan.baidu.com" in u:
        return "baidu"
    if "alipan.com" in u or "aliyundrive.com" in u:
        return "aliyun"
    if "drive.uc.cn" in u:
        return "uc"
    if "115.com" in u or "anxia.com" in u:
        return "115"
    if "cloud.189.cn" in u:
        return "tianyi"
    return t or "other"


def _login_request(base: str, username: str, password: str, timeout: float) -> str:
    """用给定凭据换 token；不写库，供登录与「测试登录」共用。"""
    url = f"{base}/api/user/login"
    try:
        with httpx.Client(timeout=min(timeout, 20.0), trust_env=False) as client:
            resp = client.post(
                url,
                json={"username": username, "password": password},
            )
    except httpx.TimeoutException as e:
        raise CloudSaverError("CloudSaver 登录超时") from e
    except httpx.HTTPError as e:
        raise CloudSaverError(f"无法连接 CloudSaver: {e}") from e

    if resp.status_code >= 400:
        raise CloudSaverError(f"CloudSaver 登录 HTTP {resp.status_code}")
    try:
        body = resp.json()
    except Exception as e:
        raise CloudSaverError("CloudSaver 登录返回非 JSON") from e
    if not body.get("success"):
        raise CloudSaverError(str(body.get("message") or "CloudSaver 登录失败"))
    token = str((body.get("data") or {}).get("token") or "").strip()
    if not token:
        raise CloudSaverError("CloudSaver 未返回 token")
    return token


def login(*, force: bool = False) -> str:
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise CloudSaverError("CloudSaver 未启用")
    if not cfg["baseUrl"]:
        raise CloudSaverError("未配置 CloudSaver 地址")
    if not cfg["username"] or not cfg["password"]:
        raise CloudSaverError("未配置 CloudSaver 账号密码")

    token = "" if force else str(cfg.get("token") or "").strip()
    if token and not force:
        return token

    token = _login_request(
        cfg["baseUrl"], cfg["username"], cfg["password"], cfg["timeoutSec"]
    )
    try:
        _save_token(token)
    except Exception:
        log.debug("persist cloudsaver token failed", exc_info=True)
    return token


def test_login(
    *,
    base_url: str = "",
    username: str = "",
    password: str = "",
    timeout_sec: float | None = None,
) -> None:
    """用表单里未保存的凭据试登录；密码留空时沿用已存密码。不写库。"""
    cfg = get_config(include_secrets=True)
    base = normalize_base(base_url) or cfg["baseUrl"]
    user = str(username or "").strip() or cfg["username"]
    pwd = password if password.strip() else str(cfg.get("password") or "")
    if not base:
        raise CloudSaverError("未配置 CloudSaver 地址")
    if not user or not pwd:
        raise CloudSaverError("未配置 CloudSaver 账号密码")
    _login_request(base, user, pwd, float(timeout_sec or cfg["timeoutSec"]))


def _request_search(
    keyword: str,
    token: str,
    timeout: float,
    base: str,
    channel_id: str = "",
    last_message_id: str = "",
) -> tuple[dict[str, Any], int]:
    params: dict[str, str] = {"keyword": keyword}
    if channel_id:
        params["channelId"] = channel_id
    if last_message_id:
        params["lastMessageId"] = last_message_id
    url = f"{base}/api/search"
    with httpx.Client(timeout=timeout, trust_env=False, follow_redirects=True) as client:
        resp = client.get(
            url,
            params=params,
            headers={"Authorization": f"Bearer {token}"},
        )
    try:
        body = resp.json() if resp.content else {}
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {"success": False, "message": "CloudSaver 返回非 JSON"}
    return body, int(resp.status_code)


def _auth_failed(body: dict[str, Any], status_code: int = 200) -> bool:
    if status_code in (401, 403):
        return True
    msg = str(body.get("message") or "")
    code = body.get("code")
    low = msg.lower()
    return (
        code in (401, 40100, "401", "40100")
        or "无效的 token" in msg
        or "未提供 token" in msg
        or "未登录" in msg
        or ("token" in low and ("无效" in msg or "过期" in msg or "未提供" in msg))
    )


class _AuthExpired(CloudSaverError):
    """登录态失效，需要重新登录。"""


def _flatten(raw_data: Any) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    channels = raw_data if isinstance(raw_data, list) else []
    for ch in channels:
        if not isinstance(ch, dict):
            continue
        rows = ch.get("list") if isinstance(ch.get("list"), list) else []
        for row in rows:
            if not isinstance(row, dict):
                continue
            title = _strip_html(str(row.get("title") or ""))
            links: list[dict[str, str]] = []
            seen_urls: set[str] = set()
            for lk in row.get("cloudLinks") or []:
                if not isinstance(lk, dict):
                    continue
                url = _AMP_RE.sub("&", str(lk.get("link") or lk.get("url") or "").strip())
                if not url or url in seen_urls:
                    continue
                seen_urls.add(url)
                t = _normalize_cloud_type(
                    str(lk.get("cloudType") or lk.get("type") or ""),
                    url,
                )
                links.append(
                    {
                        "type": t or "other",
                        "url": url,
                        "password": str(lk.get("password") or lk.get("code") or "").strip(),
                        "workTitle": "",
                        "label": cloud_label(t),
                    }
                )
            magnet = _AMP_RE.sub("&", str(row.get("magnetLink") or "").strip())
            if magnet.startswith("magnet:") and magnet not in seen_urls:
                seen_urls.add(magnet)
                links.append(
                    {
                        "type": "magnet",
                        "url": magnet,
                        "password": "",
                        "workTitle": "",
                        "label": cloud_label("magnet"),
                    }
                )
            # 无可用链接的条目跳过，避免弹窗噪声
            if not links:
                continue
            uid = str(row.get("messageId") or "").strip() or f"{title}|{links[0]['url']}"
            if uid in seen:
                continue
            seen.add(uid)
            channel = str(row.get("channel") or row.get("channelId") or ch.get("name") or "").strip()
            tags = []
            if isinstance(row.get("tags"), list):
                tags = [_strip_html(str(t)) for t in row["tags"] if str(t).strip()]
            items.append(
                {
                    "id": uid,
                    "title": title or "未命名资源",
                    "content": _strip_html(str(row.get("content") or "")),
                    "channel": channel,
                    "datetime": str(row.get("pubDate") or "").strip(),
                    "tags": tags[:8],
                    "links": links,
                }
            )
    return items


def _fetch_page(
    keyword: str,
    token: str,
    timeout: float,
    base: str,
    channel_id: str = "",
    last_message_id: str = "",
) -> dict[str, Any]:
    try:
        body, status = _request_search(
            keyword, token, timeout, base, channel_id, last_message_id
        )
    except httpx.TimeoutException as e:
        raise CloudSaverError("CloudSaver 搜索超时") from e
    except httpx.HTTPError as e:
        raise CloudSaverError(f"无法连接 CloudSaver: {e}") from e
    if (not body.get("success") or status >= 400) and _auth_failed(body, status):
        raise _AuthExpired(str(body.get("message") or "CloudSaver 登录已失效"))
    if status >= 400 and not body.get("success"):
        raise CloudSaverError(str(body.get("message") or f"CloudSaver HTTP {status}"))
    if not body.get("success"):
        raise CloudSaverError(str(body.get("message") or "CloudSaver 搜索失败"))
    return body


def _absorb(raw_data: Any, state: dict[str, Any]) -> int:
    """吸收一页结果，并记下各频道的下一页游标（channelId + lastMessageId）。"""
    added = 0
    channels = raw_data if isinstance(raw_data, list) else []
    for group in channels:
        if not isinstance(group, dict):
            continue
        info = group.get("channelInfo") if isinstance(group.get("channelInfo"), dict) else {}
        channel_id = str(info.get("id") or group.get("id") or "").strip()
        for item in _flatten([group]):
            if item["id"] in state["ids"]:
                continue
            state["ids"].add(item["id"])
            state["items"].append(item)
            added += 1
        cursor = str(group.get("nextMessageId") or "").strip()
        if channel_id and group.get("hasMore") and cursor:
            state["cursors"][channel_id] = cursor
        elif channel_id:
            state["cursors"].pop(channel_id, None)
    return added


def _pool_get(key: str) -> dict[str, Any] | None:
    entry = _cloud_pools.get(key)
    if entry is None:
        return None
    if time.monotonic() - entry[0] > _POOL_TTL_S:
        _cloud_pools.pop(key, None)
        return None
    return entry[1]


def _pool_put(key: str, state: dict[str, Any]) -> None:
    if len(_cloud_pools) >= _POOL_MAX:
        oldest = min(_cloud_pools, key=lambda name: _cloud_pools[name][0])
        _cloud_pools.pop(oldest, None)
    _cloud_pools[key] = (time.monotonic(), state)


def search(keyword: str, *, min_items: int = 0) -> dict[str, Any]:
    cfg = get_config(include_secrets=True)
    if not cfg["enabled"]:
        raise CloudSaverError("CloudSaver 未启用")
    base = cfg["baseUrl"]
    if not base:
        raise CloudSaverError("未配置 CloudSaver 地址")
    kw = str(keyword or "").strip()
    if not kw:
        raise CloudSaverError("关键词为空")

    # 首屏一次请求；随后按频道游标翻页，直到够 min_items 条或上游没有更多
    want = 0 if min_items <= 0 else min(int(min_items), _POOL_ITEMS_MAX)
    key = f"{base}|{kw.lower()}"
    token = login(force=False)
    for attempt in (0, 1):
        state = _pool_get(key)
        if state is None:
            state = {"items": [], "ids": set(), "cursors": {}, "seeded": False}
        try:
            if not state["seeded"]:
                _absorb(_fetch_page(kw, token, cfg["timeoutSec"], base).get("data"), state)
                state["seeded"] = True
            rounds = 0
            while (
                state["cursors"]
                and rounds < _POOL_ROUNDS
                and len(state["items"]) < want
            ):
                rounds += 1
                targets = list(state["cursors"].items())
                state["cursors"] = {}
                added = 0
                for channel_id, cursor in targets:
                    try:
                        body = _fetch_page(
                            kw, token, cfg["timeoutSec"], base, channel_id, cursor
                        )
                    except _AuthExpired:
                        raise
                    except CloudSaverError:
                        continue  # 单频道失败不影响其他频道
                    added += _absorb(body.get("data"), state)
                if added == 0:
                    # 游标翻页没带来新内容（部分频道 hasMore 不可靠），就此收尾
                    state["cursors"] = {}
                    break
        except _AuthExpired as e:
            _cloud_pools.pop(key, None)
            if attempt:
                raise CloudSaverError(str(e)) from e
            token = login(force=True)
            continue
        _pool_put(key, state)
        items = state["items"][:_POOL_ITEMS_MAX]
        host = urlparse(base).netloc or base
        return {
            "keyword": kw,
            "source": "cloudsaver",
            "baseUrl": base,
            "host": host,
            "total": len(items),
            "items": items,
        }
    raise CloudSaverError("CloudSaver 鉴权失败")


def health() -> dict[str, Any]:
    cfg = get_config(include_secrets=True)
    base = cfg["baseUrl"]
    if not cfg["enabled"] or not base:
        return {"ok": False, "configured": False, "baseUrl": base, "message": "未配置"}
    if not cfg["username"] or not cfg["password"]:
        return {
            "ok": False,
            "configured": False,
            "baseUrl": base,
            "message": "未配置账号密码",
        }
    try:
        login(force=False)
        return {
            "ok": True,
            "configured": True,
            "baseUrl": base,
            "username": cfg["username"],
            "message": "ok",
        }
    except Exception as e:
        return {
            "ok": False,
            "configured": True,
            "baseUrl": base,
            "username": cfg["username"],
            "message": str(e),
        }
