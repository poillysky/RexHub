"""资源检索：把各资源库统一成「资源名称 + 资源链接」的结果。

检索逻辑按服务的 label（notes / database / name）自动匹配，
新增同类型的数据库服务时无需改代码即可参与搜索。
"""

from __future__ import annotations

import asyncio
import html
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from time import monotonic

import asyncpg

RESULT_LIMIT = 50  # 每页条数
CANDIDATES = 500  # 每个库参与相关性排序的固定候选池，翻页时保持不变以保证顺序稳定
MAX_TOKENS = 4  # 关键词最多拆几个词参与匹配
CONNECT_TIMEOUT = 3.0
STATEMENT_TIMEOUT_MS = 8000
CACHE_TTL = 300  # 候选池缓存秒数：翻页与重复搜索直接复用
CACHE_MAX = 64

CLOUDSAVER_TIMEOUT = 20.0
CLOUDSAVER_TOKEN_TTL = 1800
CLOUD_ROUNDS = 3  # 单次「加载更多」最多翻几轮分页（每轮并发请求所有频道）
CLOUD_POOL_MAX = 400  # 单个关键词累计结果上限
CLOUD_STATE_MAX = 32

_candidates: dict[tuple[str, str], tuple[float, list[dict]]] = {}
_cloud_tokens: dict[str, tuple[float, str]] = {}
_cloud_pools: dict[tuple[str, str], tuple[float, dict]] = {}


def _cache_get(key: tuple[str, str]) -> list[dict] | None:
    entry = _candidates.get(key)
    if entry is None:
        return None
    if monotonic() - entry[0] > CACHE_TTL:
        _candidates.pop(key, None)
        return None
    return entry[1]


def _cache_put(key: tuple[str, str], rows: list[dict]) -> None:
    if len(_candidates) >= CACHE_MAX:
        oldest = min(_candidates, key=lambda item: _candidates[item][0])
        _candidates.pop(oldest, None)
    _candidates[key] = (monotonic(), rows)


def _dsn(item: dict) -> str:
    user = urllib.parse.quote(str(item.get("username") or ""), safe="")
    password = urllib.parse.quote(str(item.get("password") or ""), safe="")
    return (
        f"postgresql://{user}:{password}"
        f"@{item.get('host')}:{item.get('port')}/{item.get('database')}"
    )


async def _fetch(item: dict, sql: str, *args):
    conn = await asyncpg.connect(dsn=_dsn(item), timeout=CONNECT_TIMEOUT)
    try:
        await conn.execute(f"SET statement_timeout = {STATEMENT_TIMEOUT_MS}")
        return await conn.fetch(sql, *args)
    finally:
        await conn.close()


def _pattern(token: str) -> str:
    escaped = token.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def _tokens(keyword: str) -> list[str]:
    """参与匹配的词，最多 MAX_TOKENS 个。"""

    return [token for token in keyword.split() if token][:MAX_TOKENS]


def _is_letter(char: str) -> bool:
    """ASCII 字母。数字不算：SSIS002、484SSIS-568 都是合法番号写法。"""

    return bool(char) and char.isascii() and char.isalpha()


def _is_ascii_phrase(token: str) -> bool:
    """纯 ASCII 字母数字词（SSIS、4k、h265）才需要词边界，中文关键词不受影响。"""

    return (
        bool(token)
        and token.isascii()
        and token.isalnum()
        and any(char.isalpha() for char in token)
    )


def _like_query(column: str, keyword: str) -> tuple[str, list[str]]:
    """把关键词按空格拆词，全部命中才算匹配。

    ASCII 词额外要求前后不是字母，避免 SSIS 命中 Assistant 这类更长的英文单词；
    数字、横杠、中文都算合法边界，所以 SSIS002、484SSIS-568、番号SSIS 仍能命中。
    """

    tokens = _tokens(keyword)
    if not tokens:
        return f"{column} ILIKE $1", [_pattern(keyword)]

    args: list[str] = []
    clauses: list[str] = []
    for token in tokens:
        args.append(_pattern(token))
        clauses.append(f"{column} ILIKE ${len(args)}")
    for token in tokens:
        if _is_ascii_phrase(token):
            args.append(f"(^|[^a-z]){token.lower()}([^a-z]|$)")
            clauses.append(f"{column} ~* ${len(args)}")
    return " AND ".join(clauses), args


def _anchor(keyword: str) -> str:
    """排序用的核心词：优先中文词里最长的，否则取最长的词。

    只用参与 SQL 匹配的词，避免核心词根本不在 WHERE 里导致结果被全部过滤。
    """

    tokens = _tokens(keyword)
    if not tokens:
        return keyword
    cjk = [token for token in tokens if any(_is_cjk(char) for char in token)]
    return max(cjk or tokens, key=len)


def _rank(column: str, param: int) -> str:
    """SQL 侧粗排，先挑出关键词靠前、标题较短的候选集。"""

    return (
        f"CASE WHEN strpos(lower({column}), lower(${param})) <= 6 THEN 0 ELSE 1 END, "
        f"length({column})"
    )


MIN_SCORE = 0.12


def _is_cjk(char: str) -> bool:
    return "\u3400" <= char <= "\u9fff" or "\uf900" <= char <= "\ufaff"


def _bounded(text: str, token: str, start: int) -> bool:
    """关键词两侧不是同类字符，说明它本身就是标题主题，而不是更长词组的一部分。

    例：「流浪地球2」「《流浪地球》」「4k.流浪地球2」算主题；
    「流浪地球之火种计划」是另一个标题，不算。
    英文词用字母/数字边界判断，避免 SSIS 被 Assistant 里的子串骗过。
    """

    before = text[start - 1] if start > 0 else ""
    end = start + len(token)
    after = text[end] if end < len(text) else ""
    if _is_ascii_phrase(token):
        return not _is_letter(before) and not _is_letter(after)
    return not _is_cjk(before) and not _is_cjk(after)


def _score(title: str, keyword: str) -> float:
    """0~1 相关性：关键词覆盖率 + 出现位置 + 词边界。

    中文标题被堆砌到几百字时覆盖率极低、位置靠后，分数会自然掉下来。
    """

    text = title.lower()
    anchor = _anchor(keyword).lower()
    if not text or not anchor:
        return 0.0

    position = text.find(anchor)
    coverage = min(1.0, len(keyword) / len(title))
    placement = max(0.0, 1.0 - position / 60)  # 越靠前越高，60 字以后记 0
    boundary = 1.0 if _bounded(text, anchor, position) else 0.0
    return 0.55 * coverage + 0.25 * placement + 0.20 * boundary


def _relevant(title: str, keyword: str) -> bool:
    """硬性过滤：长标题里被埋很深的关键词、以及更长词组里顺带出现的关键词。"""

    text = title.lower()
    anchor = _anchor(keyword).lower()
    position = text.find(anchor)
    if position < 0:
        return False
    if len(title) > 120 and position > 60:
        return False
    if not _bounded(text, anchor, position):
        # 英文词被字母包围（assistant 里的 ssis）一定是子串误命中，直接丢弃
        if _is_ascii_phrase(anchor):
            return False
        coverage = len(keyword) / len(title)
        if coverage < 0.08:
            return False
    return True


def _tail_kind(text: str, end: int) -> int:
    """关键词之后第一个字符决定语义强弱。

    0 = 分隔符/版本信息（.1080p、-国语4K、空格），说明标题就是这部作品；
    1 = 续集编号（流浪地球2），是另一部作品但强相关；
    2 = 中文续词（流浪地球之火种计划），语义已经变了。
    """

    if end >= len(text):
        return 0
    char = text[end]
    if _is_cjk(char):
        return 2
    if char.isdigit():
        # 「流浪地球2」是续集；「流浪地球1080」「流浪地球2019」是分辨率/年份
        run = end
        while run < len(text) and text[run].isdigit():
            run += 1
        return 1 if run - end <= 2 else 0
    return 0


def _lead(text: str) -> int:
    """跳过标题开头的标点/空格，让《流浪地球》《[4k] 流浪地球》也能算「开头命中」。"""

    index = 0
    while index < len(text) and not text[index].isalnum() and not _is_cjk(text[index]):
        index += 1
    return index


def _tier_key(title: str, keyword: str) -> tuple[int, int, int]:
    """语义层级：0 完全命中 > 1 关键词开头+版本信息 > 2 续集编号 > 3 中文续词 > 4 关键词靠后。

    同层内按关键词出现位置、标题长度排序，越靠前越短越优先。
    """

    text = title.lower().strip()
    full = " ".join(keyword.lower().split())
    anchor = _anchor(keyword).lower().strip() or full
    if not text:
        return (9, 0, 0)

    body = text[_lead(text) :]
    if body == full or body == anchor:
        return (0, 0, len(text))

    for token in (full, anchor):
        if token and body.startswith(token):
            return (1 + _tail_kind(body, len(token)), 0, len(text))

    position = text.find(anchor)
    return (4, position if position >= 0 else 999, len(text))


def _rerank(keyword: str, rows: list[dict]) -> list[dict]:
    """按相关性重排、去重，并丢掉明显不相关的结果。

    先按语义层级分组，再在组内用覆盖率/位置/词边界细分，
    保证「完全命中」永远排在最前面。
    """

    seen: set[str] = set()
    scored: list[tuple[tuple[int, int, int], float, dict]] = []
    for row in rows:
        title = str(row.get("title") or "")
        key = title.lower().strip()
        if not key or key in seen:
            continue
        seen.add(key)
        if not _relevant(title, keyword):
            continue
        score = _score(title, keyword)
        if score >= MIN_SCORE:
            scored.append((_tier_key(title, keyword), score, row))
    scored.sort(key=lambda entry: (entry[0], -entry[1]))
    return [row for _, _, row in scored]


_PWD_RE = re.compile(
    r"(?:解压密码|解压码|压缩密码|提取码|提取密码|访问码|网盘密码|度盘密码)"
    r"[^:：=\n]{0,10}[:：=]\s*([^\s，,、;；|/\\]{2,40})"
)

_PWD_EMPTY = {"无", "无需", "无需解压", "无密码", "不需要", "none", "null", "-"}


def _password_from_text(text: str) -> str:
    """从资源描述里提取密码/提取码。

    色花堂的 ed2k 资源把帖子正文放在 search_string 里，常见形态：
    「【解压密码】：1998@www.98T.la」「度盘解压密码:asdfghjkl」「提取码：1grv」。
    只认带明确字段名的写法，避免把「密码房」「流量密码」这类标题当成密码。
    """

    if not text:
        return ""
    match = _PWD_RE.search(text)
    if not match:
        return ""
    value = match.group(1).strip().strip("。.,，;；")
    if not value or value.lower() in _PWD_EMPTY:
        return ""
    # 密码必然是 ASCII 串；带中文的说明是标题语义（如「爱情密码：玉儿怒张」）
    if any(_is_cjk(char) for char in value):
        return ""
    if not any(char.isalnum() for char in value):
        return ""
    return value


def _bitmagnet_items(rows) -> list[dict]:
    return [
        {
            "title": row["name"],
            "link": (
                "magnet:?xt=urn:btih:"
                + row["info_hash"]
                + "&dn="
                + urllib.parse.quote(row["name"])
            ),
            "password": _password_from_text(row["name"]),
        }
        for row in rows
    ]


def _ed2k_items(rows) -> list[dict]:
    return [
        {
            "title": row["filename"],
            "link": row["ed2k_link"],
            # 密码主要写在帖子正文（search_string）里，文件名基本不带
            "password": _password_from_text(row["search_string"] or "")
            or _password_from_text(row["filename"]),
        }
        for row in rows
    ]


def _prefix_pattern(keyword: str) -> str | None:
    """单关键词才能走前缀索引；多词查询没有可用的前缀。"""

    tokens = _tokens(keyword)
    if len(tokens) != 1:
        return None
    return _pattern(tokens[0])[1:]  # 去掉开头的 %，变成「关键词%」


async def _search_bitmagnet(item: dict, keyword: str, limit: int) -> list[dict]:
    select = "SELECT name, encode(info_hash, 'hex') AS info_hash FROM torrents"
    prefix = _prefix_pattern(keyword)
    if prefix:
        # 前缀命中够填满候选池时，走 btree 索引（毫秒级），不必全表扫描
        rows = await _fetch(
            item,
            f"{select} WHERE name ILIKE $1 ORDER BY created_at DESC, info_hash LIMIT $2",
            prefix,
            limit,
        )
        if len(rows) >= limit:
            return _bitmagnet_items(rows)

    where, args = _like_query("name", keyword)
    rows = await _fetch(
        item,
        f"""
        {select}
        WHERE {where}
        ORDER BY {_rank("name", len(args) + 1)}, created_at DESC, info_hash
        LIMIT ${len(args) + 2}
        """,
        *args,
        _anchor(keyword),
        limit,
    )
    return _bitmagnet_items(rows)


async def _search_sehuatang(item: dict, keyword: str, limit: int) -> list[dict]:
    select = "SELECT filename, ed2k_link, search_string FROM ed2k_resources"
    valid = "ed2k_link NOT LIKE 'unavailable://%'"
    prefix = _prefix_pattern(keyword)
    if prefix:
        rows = await _fetch(
            item,
            f"{select} WHERE filename ILIKE $1 AND {valid}"
            " ORDER BY created_at DESC, ed2k_link LIMIT $2",
            prefix,
            limit,
        )
        if len(rows) >= limit:
            return _ed2k_items(rows)

    where, args = _like_query("filename", keyword)
    rows = await _fetch(
        item,
        f"""
        {select}
        WHERE {where}
          AND {valid}
        ORDER BY {_rank("filename", len(args) + 1)}, created_at DESC, ed2k_link
        LIMIT ${len(args) + 2}
        """,
        *args,
        _anchor(keyword),
        limit,
    )
    return _ed2k_items(rows)


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
        with urllib.request.urlopen(request, timeout=timeout) as response:
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


PANSOU_TIMEOUT = 30.0
# PanSou 的 merged_by_type 键 → 展示标签；只保留 115 和磁力，其余网盘丢弃
PANSOU_TYPES = (("115", "115"), ("magnet", "磁力"))


def _pansou_link(url: str, password: str) -> str:
    """115 链接的提取码常单独返回，拼进链接里方便直接打开。"""

    link = url.strip()
    pwd = password.strip()
    if link and pwd and "password=" not in link:
        link += ("&" if "?" in link else "?") + "password=" + urllib.parse.quote(pwd)
    return link


def _pansou_items(payload: dict) -> list[dict]:
    """data.merged_by_type 里按云盘类型聚合，只取 115 与磁力。"""

    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
    merged = data.get("merged_by_type")
    results: list[dict] = []
    seen: set[str] = set()
    if not isinstance(merged, dict):
        return results
    for key, kind in PANSOU_TYPES:
        rows = merged.get(key)
        if not isinstance(rows, list):
            continue
        for row in rows:
            if not isinstance(row, dict):
                continue
            title = _clean_title(row.get("note") or row.get("title"))
            raw = str(row.get("url") or "").strip()
            password = str(row.get("password") or "").strip() or _link_password(raw)
            link = _pansou_link(raw, password)
            if not title or not link or link in seen:
                continue
            seen.add(link)
            results.append(
                {"title": title, "link": link, "kind": kind, "password": password}
            )
    return results


async def _search_pansou(
    item: dict, keyword: str, need: int
) -> tuple[list[dict], bool]:
    """PanSou 聚合搜索。

    自托管默认不鉴权；若服务里填了 api_key（开启了 AUTH_ENABLED），按 Bearer 发送。
    PanSou 的合并接口一次返回全部结果，没有游标，所以本地缓存后按 offset 切片。
    """

    base = _cloudsaver_base(item)
    if not base:
        raise RuntimeError("PanSou 未配置访问地址")

    key = (str(item.get("id") or ""), keyword.lower().strip())
    rows = _cache_get(key)
    if rows is None:
        body = await asyncio.to_thread(
            _http_json,
            f"{base}/api/search",
            {"kw": keyword, "res": "merge", "src": "all"},
            str(item.get("api_key") or "").strip(),
            PANSOU_TIMEOUT,
        )
        code = body.get("code")
        if code not in (None, 0, 200):
            raise RuntimeError(str(body.get("message") or f"检索失败（{code}）"))
        rows = _pansou_items(body)
        _cache_put(key, rows)
    return rows, len(rows) > need


PROVIDERS = (
    ("bitmagnet", _search_bitmagnet),
    ("sehuatang", _search_sehuatang),
    ("ed2k", _search_sehuatang),
    ("cloudsaver", _search_cloudsaver),
    ("cloud-saver", _search_cloudsaver),
    ("pansou", _search_pansou),
)

EXTERNAL_PROVIDERS = {_search_cloudsaver, _search_pansou}



def resolve_provider(item: dict):
    """按服务标签识别检索实现，便于同类数据库直接复用。"""

    label = " ".join(
        str(item.get(key) or "") for key in ("id", "notes", "database", "name")
    ).lower()
    for key, provider in PROVIDERS:
        if key in label:
            return provider
    return None


def _ensure_password(rows: list[dict]) -> list[dict]:
    """外部搜索源没给 password 时，从标题里再兜底提取一次。"""

    for row in rows:
        if not str(row.get("password") or "").strip():
            value = _password_from_text(str(row.get("title") or ""))
            if value:
                row["password"] = value
    return rows


async def search(
    items: list[dict],
    keyword: str,
    limit: int = RESULT_LIMIT,
    offset: int = 0,
) -> list[tuple[dict, list[dict], str, bool]]:
    """并发检索，返回 (服务, 本页结果, 错误信息, 是否还有更多)。"""

    offset = max(0, offset)

    async def run(item: dict):
        provider = resolve_provider(item)
        if provider is None:
            return item, [], "该服务尚未接入检索", False
        try:
            if provider in EXTERNAL_PROVIDERS:
                # 外部搜索源（CloudSaver）自带排序与游标分页，按需翻到 offset+limit 条
                rows, has_more = await provider(item, keyword, offset + limit)
                rows = _ensure_password(rows)
                return item, rows[offset : offset + limit], "", has_more
            key = (
                str(item.get("id") or item.get("database") or ""),
                keyword.lower().strip(),
            )
            rows = _cache_get(key)
            if rows is None:
                rows = await provider(item, keyword, CANDIDATES)
                _cache_put(key, rows)
            full = _rerank(keyword, rows)
            return item, full[offset : offset + limit], "", len(full) > offset + limit
        except _CloudSaverAuthError as exc:
            label = str(item.get("name") or "该服务")
            detail = str(exc)
            if detail and detail != "未配置凭据":
                return item, [], f"{label} 鉴权失败：{detail}，请更新 API Key 或账号密码", False
            return item, [], f"需要在服务管理里填写 {label} 的账号密码或 API Key", False
        except RuntimeError as exc:
            return item, [], str(exc) or "检索失败", False
        except asyncio.TimeoutError:
            return item, [], "连接超时，请检查服务是否在线", False
        except asyncpg.exceptions.QueryCanceledError:
            return item, [], "检索超时，请换个更具体的关键词", False
        except Exception as exc:  # noqa: BLE001
            return item, [], f"检索失败：{type(exc).__name__}", False

    return list(await asyncio.gather(*(run(item) for item in items)))
