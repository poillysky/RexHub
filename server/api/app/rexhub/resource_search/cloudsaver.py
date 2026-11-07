"""CloudSaver 外部搜索源：登录鉴权、游标翻页与结果摊平。"""


import asyncio
import html
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from time import monotonic

from app.rexhub import network_store

from .constants import CACHE_TTL


CLOUDSAVER_TIMEOUT = 20.0
CLOUDSAVER_TOKEN_TTL = 1800
CLOUD_ROUNDS = 3  # 单次「加载更多」最多翻几轮分页（每轮并发请求所有频道）
CLOUD_POOL_MAX = 400  # 单个关键词累计结果上限
CLOUD_STATE_MAX = 32

_cloud_tokens: dict[str, tuple[float, str]] = {}
_cloud_pools: dict[tuple[str, str], tuple[float, dict]] = {}


class _CloudSaverAuthError(RuntimeError):
    """缺少凭据或 token 失效，需要用户去服务管理里补配置。"""


_TAG_RE = re.compile(r"<[^>]+>")

PAN115_TYPES = {"pan115", "115"}


def _cloudsaver_base(item: dict) -> str:
    url = str(item.get("url") or "").strip().rstrip("/")
    if url:
        return url
    host = str(item.get("host") or "").strip()
    port = item.get("port")
    if not host:
        return ""
    return f"http://{host}:{port}" if port else f"http://{host}"


def _http_json(
    url: str,
    payload: dict | None = None,
    token: str = "",
    timeout: float = CLOUDSAVER_TIMEOUT,
) -> dict:
    """标准库 HTTP：项目没有安装 httpx/requests，用 urllib + to_thread。"""

    headers = {"Accept": "application/json"}
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        url, data=data, headers=headers, method="POST" if data else "GET"
    )
    try:
        with network_store.open_url(request, timeout, "search") as response:
            raw = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        message = str(body.get("message") or f"HTTP {exc.code}")
        if exc.code == 401 or body.get("code") == 40100:
            raise _CloudSaverAuthError(message) from exc
        raise RuntimeError(message) from exc
    try:
        body = json.loads(raw)
    except ValueError as exc:
        raise RuntimeError("CloudSaver 返回内容不是 JSON") from exc
    if not isinstance(body, dict):
        raise RuntimeError("CloudSaver 返回结构异常")
    return body


async def _cloudsaver_token(item: dict, base: str) -> str:
    """优先用服务里填的 API Key（JWT），否则用账号密码换 token 并缓存。"""

    api_key = str(item.get("api_key") or "").strip()
    if api_key:
        return api_key

    username = str(item.get("username") or "").strip()
    password = str(item.get("password") or "")
    if not username or not password:
        raise _CloudSaverAuthError("未配置凭据")

    key = f"{base}|{username}"
    entry = _cloud_tokens.get(key)
    if entry and monotonic() - entry[0] < CLOUDSAVER_TOKEN_TTL:
        return entry[1]

    body = await asyncio.to_thread(
        _http_json,
        f"{base}/api/user/login",
        {"username": username, "password": password},
        "",
    )
    data = body.get("data") if isinstance(body.get("data"), dict) else {}
    token = str(data.get("token") or "").strip()
    if not token:
        raise _CloudSaverAuthError(str(body.get("message") or "登录失败"))
    _cloud_tokens[key] = (monotonic(), token)
    return token


def _clean_title(value) -> str:
    text = html.unescape(str(value or ""))
    return _TAG_RE.sub("", text).strip()


def _link_password(link: str) -> str:
    """从链接的查询参数里取提取码（115 常见 ?password=xxxx）。"""

    try:
        query = urllib.parse.urlparse(link).query
    except ValueError:
        return ""
    params = urllib.parse.parse_qs(query)
    for key in ("password", "pwd", "code"):
        value = params.get(key)
        if value:
            return str(value[0]).strip()
    return ""


def _cloudsaver_items(payload: dict) -> list[dict]:
    """data[*].list[*] 摊平，只保留 115 网盘和磁力链接，其余网盘直接丢弃。"""

    results: list[dict] = []
    groups = payload.get("data")
    if not isinstance(groups, list):
        return results
    for group in groups:
        if not isinstance(group, dict):
            continue
        rows = group.get("list")
        if not isinstance(rows, list):
            continue
        for row in rows:
            if not isinstance(row, dict):
                continue
            title = _clean_title(row.get("title"))
            if not title:
                continue
            link = ""
            for cloud in row.get("cloudLinks") or []:
                if not isinstance(cloud, dict):
                    continue
                if str(cloud.get("cloudType") or "").lower() in PAN115_TYPES:
                    link = str(cloud.get("link") or "").strip()
                    if link:
                        break
            if link:
                results.append(
                    {
                        "title": title,
                        "link": link,
                        "kind": "115",
                        "password": _link_password(link),
                    }
                )
                continue
            link = str(row.get("magnetLink") or "").strip()
            if link:
                results.append({"title": title, "link": link, "kind": "磁力"})
    return results


async def _cloud_fetch(
    base: str,
    token: str,
    keyword: str,
    channel_id: str = "",
    last_message_id: str = "",
) -> dict:
    params = {"keyword": keyword}
    if channel_id:
        params["channelId"] = channel_id
    if last_message_id:
        params["lastMessageId"] = last_message_id
    url = f"{base}/api/search?{urllib.parse.urlencode(params)}"
    body = await asyncio.to_thread(_http_json, url, None, token)
    code = body.get("code")
    if code not in (None, 0, 200):
        raise RuntimeError(str(body.get("message") or f"检索失败（{code}）"))
    return body


def _cloud_absorb(payload: dict, state: dict) -> int:
    """吸收一页结果，并记下各频道的下一页游标（channelId + lastMessageId）。"""

    added = 0
    groups = payload.get("data")
    if not isinstance(groups, list):
        return 0
    for group in groups:
        if not isinstance(group, dict):
            continue
        info = group.get("channelInfo") if isinstance(group.get("channelInfo"), dict) else {}
        channel_id = str(info.get("id") or group.get("id") or "").strip()
        for row in _cloudsaver_items({"data": [group]}):
            key = row["title"].lower()
            if key in state["titles"]:
                continue
            state["titles"].add(key)
            state["rows"].append(row)
            added += 1
        cursor = str(group.get("nextMessageId") or "").strip()
        if channel_id and group.get("hasMore") and cursor:
            state["cursors"][channel_id] = cursor
    return added


def _cloud_pool_get(key: tuple[str, str]) -> dict | None:
    entry = _cloud_pools.get(key)
    if entry is None:
        return None
    if monotonic() - entry[0] > CACHE_TTL:
        _cloud_pools.pop(key, None)
        return None
    return entry[1]


def _cloud_pool_put(key: tuple[str, str], state: dict) -> None:
    if len(_cloud_pools) >= CLOUD_STATE_MAX:
        oldest = min(_cloud_pools, key=lambda name: _cloud_pools[name][0])
        _cloud_pools.pop(oldest, None)
    _cloud_pools[key] = (monotonic(), state)


async def _search_cloudsaver(
    item: dict, keyword: str, need: int
) -> tuple[list[dict], bool]:
    """CloudSaver 自带搜索。

    首屏只发一次请求（多频道分组），之后按 channelId + lastMessageId 游标翻页，
    由「加载更多」驱动；结果既有的频道里只保留 115 网盘和磁力链接。
    """

    base = _cloudsaver_base(item)
    if not base:
        raise RuntimeError("CloudSaver 未配置访问地址")

    key = (str(item.get("id") or ""), keyword.lower().strip())
    for attempt in (0, 1):
        token = await _cloudsaver_token(item, base)
        state = _cloud_pool_get(key)
        first = state is None
        if first:
            state = {"rows": [], "titles": set(), "cursors": {}, "seeded": False}
        before = len(state["rows"])
        try:
            if not state["seeded"]:
                _cloud_absorb(await _cloud_fetch(base, token, keyword), state)
                state["seeded"] = True
            rounds = 0
            while (
                not first
                and state["cursors"]
                and rounds < CLOUD_ROUNDS
                and len(state["rows"]) < min(need, CLOUD_POOL_MAX)
            ):
                rounds += 1
                targets = list(state["cursors"].items())
                state["cursors"] = {}
                bodies = await asyncio.gather(
                    *(
                        _cloud_fetch(base, token, keyword, channel_id, cursor)
                        for channel_id, cursor in targets
                    ),
                    return_exceptions=True,
                )
                added = 0
                for body in bodies:
                    if isinstance(body, dict):
                        added += _cloud_absorb(body, state)
                if added == 0:
                    # 游标翻页没带来新内容（部分频道 hasMore 不可靠），就此收尾
                    state["cursors"] = {}
                    break
        except _CloudSaverAuthError:
            # 账号密码换来的 token 可能过期：清缓存后重登一次
            _cloud_pools.pop(key, None)
            if attempt or str(item.get("api_key") or "").strip():
                raise
            _cloud_tokens.pop(f"{base}|{str(item.get('username') or '').strip()}", None)
            continue
        _cloud_pool_put(key, state)
        rows = state["rows"]
        # 本轮有新内容且游标还在，或者后面还压着没展示的，才算「还有更多」
        progressed = len(rows) > before
        has_more = len(rows) > need or (
            progressed and bool(state["cursors"]) and len(rows) < CLOUD_POOL_MAX
        )
        return rows, has_more
    raise RuntimeError("CloudSaver 鉴权失败")
