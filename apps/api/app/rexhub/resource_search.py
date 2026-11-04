"""资源检索：把各资源库统一成「资源名称 + 资源链接」的结果。

检索逻辑按服务的 label（notes / database / name）自动匹配，
新增同类型的数据库服务时无需改代码即可参与搜索。
"""

from __future__ import annotations

import asyncio
import base64
import html
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from time import monotonic

import asyncpg

from app.rexhub import network_store

RESULT_LIMIT = 50  # 每页条数
PAGE_CANDIDATES = 500  # 单个库单次检索的初始候选池
MAX_CANDIDATES = 3000  # 单个库单关键词最多保留的候选，再多的部分标记为未取全
CANDIDATE_GROWTH = 2  # 翻页超出候选池时按倍数扩容
MAX_TOKENS = 4  # 关键词最多拆几个词参与匹配
CONNECT_TIMEOUT = 3.0
# 结果页会在超时后静默续搜，服务端给足一次扫描的时间，尽量一次跑完
STATEMENT_TIMEOUT_MS = 20000
# bitmagnet 库有数百万条英文标题，中文关键词只能全表扫描，给更长的超时并允许退化返回
BITMAGNET_TIMEOUT_MS = 20000
CACHE_TTL = 300  # 候选池缓存秒数：翻页与重复搜索直接复用
CACHE_MAX = 64

CLOUDSAVER_TIMEOUT = 20.0
CLOUDSAVER_TOKEN_TTL = 1800
CLOUD_ROUNDS = 3  # 单次「加载更多」最多翻几轮分页（每轮并发请求所有频道）
CLOUD_POOL_MAX = 400  # 单个关键词累计结果上限
CLOUD_STATE_MAX = 32

_candidates: dict[tuple[str, str], tuple[float, list[dict]]] = {}
# 数据库候选池：(时间, 原始候选行, 已请求条数, 是否已取全)
# complete 为 None 表示查询超时降级，只拿到了部分结果，再扩容也没有意义
_db_pools: dict[tuple[str, str], tuple[float, list[dict], int, bool | None]] = {}
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


def _db_pool_get(
    key: tuple[str, str],
) -> tuple[float, list[dict], int, bool | None] | None:
    entry = _db_pools.get(key)
    if entry is None:
        return None
    if monotonic() - entry[0] > CACHE_TTL:
        _db_pools.pop(key, None)
        return None
    return entry


def _db_pool_put(
    key: tuple[str, str],
    rows: list[dict],
    requested: int,
    complete: bool | None,
) -> None:
    if len(_db_pools) >= CACHE_MAX:
        oldest = min(_db_pools, key=lambda name: _db_pools[name][0])
        _db_pools.pop(oldest, None)
    _db_pools[key] = (monotonic(), rows, requested, complete)


def _dsn(item: dict) -> str:
    user = urllib.parse.quote(str(item.get("username") or ""), safe="")
    password = urllib.parse.quote(str(item.get("password") or ""), safe="")
    return (
        f"postgresql://{user}:{password}"
        f"@{item.get('host')}:{item.get('port')}/{item.get('database')}"
    )


async def _fetch(
    item: dict, sql: str, *args, timeout_ms: int = STATEMENT_TIMEOUT_MS
):
    conn = await asyncpg.connect(dsn=_dsn(item), timeout=CONNECT_TIMEOUT)
    try:
        await conn.execute(f"SET statement_timeout = {timeout_ms}")
        return await conn.fetch(sql, *args)
    finally:
        await conn.close()


def _pattern(token: str) -> str:
    escaped = token.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


_QUOTED_RE = re.compile(r'"([^"]*)"')

# 番号形态：字母开头 + 可含数字的字母段 + 横杠 + 数字，如 SSIS-001、ABP-123、FC2-1234567
_CODE_RE = re.compile(r"^[a-z][a-z0-9]{1,9}-(\d{2,7})$")


def _code_digits(token: str) -> int:
    """番号数字部分位数；不是番号形态返回 0。"""
    match = _CODE_RE.match(token.lower())
    return len(match.group(1)) if match else 0


def _is_full_code(token: str) -> bool:
    """数字 ≥ 3 位视为完整番号，需要尾部数字边界，避免 SSIS-001 命中 SSIS-0010。"""
    return _code_digits(token) >= 3


def _split_keyword(keyword: str) -> tuple[list[str], list[str]]:
    """拆成 (引号内的精确短语, 其余按空格分隔的词)。"""

    phrases = [part.strip() for part in _QUOTED_RE.findall(keyword)]
    rest = _QUOTED_RE.sub(" ", keyword)
    return [part for part in phrases if part], [word for word in rest.split() if word]


def _terms(keyword: str) -> list[tuple[str, bool]]:
    """参与匹配的词：(词, 是否引号精确短语)，最多 MAX_TOKENS 个。"""

    phrases, words = _split_keyword(keyword)
    terms = [(phrase, True) for phrase in phrases] + [
        (word, False) for word in words
    ]
    if not terms:
        # 只有引号或全是分隔符时退回原始关键词，避免退化成「匹配一切」
        fallback = keyword.strip()
        return [(fallback, False)] if fallback else []
    return terms[:MAX_TOKENS]


def _joined(keyword: str) -> str:
    """去掉引号后按词拼回的关键词，用于相关性打分与层级判断。"""

    return " ".join(text for text, _ in _terms(keyword)) or keyword.strip()


def _levels(keyword: str) -> list[list[tuple[str, bool]]]:
    """先严后宽：先要求全部词命中，不足一页时再去掉最短的词重查一次。

    引号短语是用户明确要求「必须整体出现」的，任何一层都不能丢。
    只放宽一层，避免中文关键词在 bitmagnet 上反复全表扫描。
    """

    terms = _terms(keyword)
    levels = [terms]
    words = [text for text, exact in terms if not exact]
    if len(words) > 1:
        drop = min(words, key=len)
        levels.append([term for term in terms if term[1] or term[0] != drop])
    return levels


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


def _where(
    column: str, terms: list[tuple[str, bool]], alt_column: str = ""
) -> tuple[str, list[str]]:
    """按词生成 SQL 条件，同一层的词全部命中才算匹配。

    ASCII 词额外要求前后不是字母，避免 SSIS 命中 Assistant 这类更长的英文单词；
    数字、横杠、中文都算合法边界，所以 SSIS002、484SSIS-568、番号SSIS 仍能命中。
    引号短语是用户指定的整体，只做整段匹配，不再拆词或加边界。

    alt_column 用于「文件名 + 帖子正文」同查：两个字段各自满足全部词才算命中，
    任一字段命中即可。色花堂的帖子标题也包含在正文 search_string 里，不用再单独查。
    """

    targets = [column] + ([alt_column] if alt_column else [])

    if not terms:
        pattern = _pattern("")
        if len(targets) > 1:
            return (
                "(" + " OR ".join(f"{target} ILIKE $1" for target in targets) + ")",
                [pattern],
            )
        return f"{column} ILIKE $1", [pattern]

    args: list[str] = []
    fields: list[str] = []
    for target in targets:
        clauses: list[str] = []
        for token, exact in terms:
            args.append(_pattern(token))
            clauses.append(f"{target} ILIKE ${len(args)}")
            if not exact and _is_ascii_phrase(token):
                args.append(f"(^|[^a-z]){token.lower()}([^a-z]|$)")
                clauses.append(f"{target} ~* ${len(args)}")
            elif not exact and _is_full_code(token):
                # 完整番号要求「后面不再接数字」：SSIS-001 不再命中 SSIS-0010，
                # 但 SSIS-001-C、SSIS-001 4K 等版本/后缀写法仍然保留。
                args.append(f"(^|[^a-z0-9]){token.lower()}([^0-9]|$)")
                clauses.append(f"{target} ~* ${len(args)}")
        fields.append("(" + " AND ".join(clauses) + ")")
    return " OR ".join(fields), args


def _anchor(keyword: str) -> str:
    """排序用的核心词：优先中文词里最长的，否则取最长的词。

    只用参与 SQL 匹配的词，避免核心词根本不在 WHERE 里导致排序失去意义。
    """

    texts = [text for text, _ in _terms(keyword)]
    if not texts:
        return keyword.strip()
    exact = [text for text, is_exact in _terms(keyword) if is_exact]
    if exact:
        # 引号短语是用户明确指定的主题，优先当核心词
        return max(exact, key=len)
    cjk = [text for text in texts if any(_is_cjk(char) for char in text)]
    return max(cjk or texts, key=len)


def _rank(column: str, param: int) -> str:
    """SQL 侧粗排，先挑出关键词靠前、标题较短的候选集。"""

    return (
        f"CASE WHEN strpos(lower({column}), lower(${param})) <= 6 THEN 0 ELSE 1 END, "
        f"length({column})"
    )


def _match_rank(columns: tuple[str, ...], param: int, prefix: str = "") -> str:
    """按命中位置粗排：`columns` 里越靠前的字段命中越优先。

    色花堂大量帖子正文里堆着同一个标签（例如「自提征用」有上万条），
    只按文件名的长度排序会把真正以该标签命名的资源挤出候选池；
    这里让文件名命中的行直接排在最前，仅正文命中的垫底。
    """

    names = [f"{prefix}{column}" for column in columns]
    branches = " ".join(
        f"WHEN strpos(lower({name}), lower(${param})) > 0 THEN {index}"
        for index, name in enumerate(names)
    )
    return f"CASE {branches} ELSE {len(names)} END, length({names[0]})"


def _ranks(
    column: str, param: int, rank_columns: tuple[str, ...]
) -> tuple[str, str]:
    """返回 (内层排序表达式, 派生表 rex 外层排序表达式)。"""

    if rank_columns:
        return (
            _match_rank(rank_columns, param),
            _match_rank(rank_columns, param, "rex."),
        )
    return _rank(column, param), _rank(f"rex.{column}", param)


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
    if _is_full_code(token):
        # 完整番号按数字判边界：SSIS-001 在 SSIS-0010 里不算独立命中。
        return not (before.isascii() and before.isalnum()) and not after.isdigit()
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
    if position < 0:
        # 放宽后命中其它词、完全不含核心词的行直接垫底，不能借用位置分
        return 0.0
    coverage = min(1.0, len(_joined(keyword)) / len(title))
    placement = max(0.0, 1.0 - position / 60)  # 越靠前越高，60 字以后记 0
    boundary = 1.0 if _bounded(text, anchor, position) else 0.0
    return 0.55 * coverage + 0.25 * placement + 0.20 * boundary


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
    full = _joined(keyword).lower()
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
    """按相关性重排并去重，不丢弃任何已匹配的行。

    先按「命中了几个词」分层，保证放宽后补进来的行永远排在整词命中之后；
    同层内再按语义层级和覆盖率/位置/词边界细分。
    """

    seen: set[str] = set()
    terms = _terms(keyword)
    scored: list[tuple[int, tuple[int, int, int], float, dict]] = []
    for row in rows:
        title = str(row.get("title") or "")
        # 只按链接里的文件哈希去重：拿不到哈希（网盘分享/一条记录挂多条链）的行一律保留，
        # 同名但不同文件也不能合并，避免像「7GB 磁力 + 12.6GB 蓝光 ed2k 同标题」被误杀。
        identity = _link_identity(str(row.get("link") or ""))
        if identity is not None:
            if identity in seen:
                continue
            seen.add(identity)
        lowered = title.lower()
        hits = sum(1 for text, _ in terms if text.lower() in lowered)
        scored.append((hits, _tier_key(title, keyword), _score(title, keyword), row))
    scored.sort(key=lambda entry: (-entry[0], entry[1], -entry[2]))
    return [entry[3] for entry in scored]


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


# MARK: 元数据整理

_SIZE_UNITS = ("B", "KB", "MB", "GB", "TB", "PB")

# 帖子正文里的信息块：每行形如「【影片名称】：xxx」
_INFO_RE = re.compile(r"【([^】\n]{1,10})】\s*[：:]\s*([^【\n]+)")
_INFO_LABELS = {
    "影片名称": "title",
    "出演女优": "actresses",
    "影片容量": "size",
    "是否有码": "censored",
    "影片时间": "runtime",
    "资源来源": "origin",
}

# 标题开头的番号，如 DASS-211 / FC2PPV-1234567
_HEAD_CODE_RE = re.compile(r"^([a-z][a-z0-9]{1,11}-\d{2,7})", re.IGNORECASE)

# 出演女优分隔符：顿号 / 斜杠 / 逗号 / 分号 / 竖线
_ACTRESS_SPLIT_RE = re.compile(r"[、,，/／;；|｜]+")


def _size_text(value) -> str:
    """字节数转人类可读容量：1024 进制，GB 保留两位小数。"""

    try:
        size = float(value or 0)
    except (TypeError, ValueError):
        return ""
    if size <= 0:
        return ""
    index = 0
    while size >= 1024 and index < len(_SIZE_UNITS) - 1:
        size /= 1024
        index += 1
    unit = _SIZE_UNITS[index]
    if unit in ("B", "KB"):
        return f"{size:.0f} {unit}"
    return f"{size:.2f} {unit}"


def _iso(value) -> str:
    """datetime 转 ISO 字符串；已经缓存的字符串原样返回。"""

    if not value:
        return ""
    try:
        return value.isoformat()
    except AttributeError:
        return str(value)


def _head_code(text: str) -> str:
    match = _HEAD_CODE_RE.match((text or "").strip())
    return match.group(1).upper() if match else ""


def _info_fields(text: str) -> dict:
    """从色花堂帖子正文里取结构化字段，正文比数据库列更全。"""

    if not text:
        return {}
    fields: dict[str, str] = {}
    for label, value in _INFO_RE.findall(text):
        key = _INFO_LABELS.get(label.strip())
        if key and key not in fields:
            fields[key] = value.strip(" \t\r，,；;/")
    return fields


def _actresses(value: str) -> list[str]:
    names = [
        part.strip()
        for part in _ACTRESS_SPLIT_RE.split(value or "")
        if part.strip()
    ]
    # 名字太长基本是描述文本，不是演员名
    return [name for name in names if len(name) <= 24][:8]


def _resolution(value) -> str:
    """bitmagnet 的分辨率枚举 V1080p / V2160p，统一成 1080p / 2160p。"""

    text = str(value or "").strip()
    if not text:
        return ""
    if text.lower().startswith("v") and len(text) > 1:
        text = text[1:]
    if text.lower() in ("other", "unknown"):
        return ""
    return text


def _bitmagnet_items(rows, meta: dict | None = None) -> list[dict]:
    meta = meta or {}
    items: list[dict] = []
    for row in rows:
        name = row["name"]
        extra = meta.get(str(row["info_hash"]).lower(), {})
        items.append(
            {
                "title": name,
                "link": (
                    "magnet:?xt=urn:btih:"
                    + row["info_hash"]
                    + "&dn="
                    + urllib.parse.quote(name)
                ),
                "kind": "磁力",
                "password": _password_from_text(name),
                "size": int(row["size"] or 0),
                "sizeText": _size_text(row["size"]),
                "filesCount": int(row["files_count"] or 0),
                "createdAt": _iso(row["created_at"]),
                "seeders": extra.get("seeders"),
                "leechers": extra.get("leechers"),
                "resolution": _resolution(extra.get("video_resolution")),
                "codec": str(extra.get("video_codec") or ""),
                "releaseGroup": str(extra.get("release_group") or ""),
                "code": _head_code(name),
            }
        )
    return items


def _ed2k_items(rows, meta: dict | None = None) -> list[dict]:
    meta = meta or {}
    items: list[dict] = []
    for row in rows:
        filename = str(row["filename"] or "")
        source = meta.get(str(row["hash"] or "").upper(), {})
        # 色花堂有两种叫法：帖子标题（resource_sources.title）当展示标题，
        # 文件名留作详情页里的「资源名称」；没抓到帖子标题时两者都退回文件名。
        post_title = str(source.get("title") or "").strip()
        title = post_title or filename
        description = str(source.get("description") or "")
        info = _info_fields(description)
        images = [
            str(url).strip()
            for url in (source.get("preview_images") or [])
            if str(url).strip().lower().startswith(("http://", "https://"))
        ][:4]
        link = row["ed2k_link"] or ""
        items.append(
            {
                "title": title,
                "resourceName": filename if post_title and post_title != filename else "",
                "link": link,
                "kind": "磁力" if link.lower().startswith("magnet:") else "ed2k",
                # 密码优先取帖子里的结构化字段，其次从正文 / 文件名兜底
                "password": str(source.get("extract_password") or "").strip()
                or _password_from_text(str(row["search_string"] or ""))
                or _password_from_text(title),
                "size": int(row["size"] or 0),
                "sizeText": _size_text(row["size"]),
                "createdAt": _iso(row["created_at"]),
                "boardName": str(source.get("board_name") or ""),
                "sourceUrl": str(source.get("source_url") or ""),
                "description": description,
                "previewImages": images,
                "actresses": _actresses(info.get("actresses", "")),
                "code": _head_code(filename) or _head_code(info.get("title", "")),
                "censored": info.get("censored", ""),
            }
        )
    return items


def _prefix_pattern(keyword: str) -> str | None:
    """单关键词才能走前缀索引；多词查询没有可用的前缀。"""

    terms = _terms(keyword)
    if len(terms) != 1:
        return None
    return _pattern(terms[0][0])[1:]  # 去掉开头的 %，变成「关键词%」


async def _search_db(
    item: dict,
    keyword: str,
    limit: int,
    *,
    table: str,
    columns: str,
    column: str,
    title_key: str,
    extra: str = "",
    tie: str = "",
    dedupe: bool = False,
    dedupe_column: str = "",
    alt_column: str = "",
    rank_columns: tuple[str, ...] = (),
    timeout_ms: int = STATEMENT_TIMEOUT_MS,
) -> tuple[list, bool]:
    """先严后宽的数据库查询，返回 (合并去重后的原始行, 是否已取全)。

    每层都带 LIMIT，只有上一层不足一页时才放宽一层，
    避免多词中文关键词在 bitmagnet 上反复全表扫描。

    dedupe 用窗口函数按标题去重，让一页候选都对应不同的资源；
    只给同名行大量重复的库打开，几百万行的大表上排序整批命中会明显拖慢。

    rank_columns 指定粗排的字段顺序：排在前面的字段命中更优先，
    用于「文件名命中 > 帖子标题命中 > 只有正文命中」这类分层排序。
    """

    tail = f", {tie}" if tie else ""
    rows: list = []
    seen: set[str] = set()
    for terms in _levels(keyword):
        where, args = _where(column, terms, alt_column)
        anchor_at = len(args) + 1
        limit_at = len(args) + 2
        if dedupe:
            # 去重分支要按时间倒序取每组最新一条；`columns` 已包含 created_at 时不再重复投影，
            # 否则派生表里会出现同名列，外层 ORDER BY 会变成歧义引用。
            # 默认按标题去重；色花堂这类「标题当文件名」的库按链接去重，
            # 避免同一部片子的不同清晰度/版本被误合并成一条。
            key_column = dedupe_column or column
            partition = f"lower({key_column})"
            created = "" if "created_at" in columns else ", created_at"
            rank_inner, rank_outer = _ranks(column, anchor_at, rank_columns)
            sql = f"""
            SELECT {columns} FROM (
                SELECT {columns}{created},
                       row_number() OVER (
                           PARTITION BY {partition}
                           ORDER BY {rank_inner}, created_at DESC
                       ) AS rex_rn
                FROM {table}
                WHERE {where}{extra}
            ) rex
            WHERE rex_rn = 1
            ORDER BY {rank_outer}, created_at DESC{tail}
            LIMIT ${limit_at}
            """
        else:
            rank_inner, _ = _ranks(column, anchor_at, rank_columns)
            sql = f"""
            SELECT {columns}
            FROM {table}
            WHERE {where}{extra}
            ORDER BY {rank_inner}, created_at DESC{tail}
            LIMIT ${limit_at}
            """
        got = await _fetch(
            item, sql, *args, _anchor(keyword), limit, timeout_ms=timeout_ms
        )
        key_column = dedupe_column or title_key
        for row in got:
            raw = row[key_column]
            # 链接列优先按链接里的文件哈希去重（改名但同文件的记录也能合并）；
            # 拿不到哈希就退回原始链接，避免把不同文件当成重复误杀。
            key = (_link_identity(str(raw or "")) or str(raw or "")).strip().lower()
            if key in seen:
                continue
            seen.add(key)
            rows.append(row)
        if len(got) >= limit:
            return rows, False
    return rows, True


_LINK_TOKEN_RE = re.compile(r"magnet:\?\S+|ed2k://\S+|(?:https?|115)://\S+", re.I)
_BTIH_RE = re.compile(r"urn:btih:([A-Za-z0-9]+)", re.I)
_ED2K_HASH_RE = re.compile(r"ed2k://\|file\|[^|]*\|\d+\|([0-9A-Fa-f]{32})\|")


def _link_identity(link: str) -> str | None:
    """取资源链接里的文件哈希，用于跨库去重。

    磁力取 `urn:btih:` 那段（40 位十六进制或 32 位 base32），ed2k 取 `|file|名|大小|哈希|`
    里的哈希；两者都归一化成大写十六进制。一个记录里挂了多条链接（合集/多文件帖）
    不参与去重，返回 None，避免误删整组资源。
    """

    tokens = _LINK_TOKEN_RE.findall(link or "")
    if len(tokens) != 1:
        return None

    token = tokens[0]

    match = _BTIH_RE.search(token)
    if match:
        raw = match.group(1).strip()
        if len(raw) == 32:
            try:
                return base64.b32decode(raw.upper()).hex().upper()
            except Exception:  # noqa: BLE001
                return raw.upper()
        return raw.upper()

    match = _ED2K_HASH_RE.match(token)
    if match:
        return match.group(1).upper()

    return None


_METADATA_FIELDS = ("boardName", "sourceUrl", "description", "previewImages")
_TORRENT_FIELDS = (
    "seeders",
    "leechers",
    "resolution",
    "codec",
    "releaseGroup",
    "filesCount",
)


def _metadata_rich(row: dict) -> bool:
    """帖子类来源（色花堂）带板块、来源帖、正文或预览图，信息比纯种子库更全。"""

    return any(bool(row.get(key)) for key in _METADATA_FIELDS)


def _merge_metadata(target: dict, donor: dict) -> None:
    """同一条链在两个库都有时，把对方缺的做种数、画质等字段补进来。

    只填空值，不覆盖已有内容：信息更全的那条保持原样，另一条只做补充。
    """

    for key in _TORRENT_FIELDS:
        value = donor.get(key)
        if value is None or value == "":
            continue
        # 0 和空字符串都算「这条没带」，但做种 0 本身是有效数据，要能带过来
        if target.get(key) in (None, ""):
            target[key] = value


async def _bitmagnet_meta(item: dict, rows) -> dict:
    """批量补充分辨率 / 编码 / 发布组与做种数，查不到时静默跳过。"""

    hashes = []
    for row in rows:
        try:
            hashes.append(bytes.fromhex(str(row["info_hash"])))
        except ValueError:
            continue
    if not hashes:
        return {}

    meta: dict[str, dict] = {}
    try:
        got = await _fetch(
            item,
            "SELECT encode(info_hash, 'hex') AS info_hash, video_resolution,"
            " video_codec, release_group"
            " FROM torrent_contents WHERE info_hash = ANY($1::bytea[])",
            hashes,
            timeout_ms=BITMAGNET_TIMEOUT_MS,
        )
        for row in got:
            meta[str(row["info_hash"]).lower()] = {
                "video_resolution": row["video_resolution"],
                "video_codec": row["video_codec"],
                "release_group": row["release_group"],
            }
    except Exception:  # noqa: BLE001 - 元数据缺失不影响检索
        meta = {}

    try:
        got = await _fetch(
            item,
            "SELECT encode(info_hash, 'hex') AS info_hash, seeders, leechers"
            " FROM torrents_torrent_sources WHERE info_hash = ANY($1::bytea[])",
            hashes,
            timeout_ms=BITMAGNET_TIMEOUT_MS,
        )
        for row in got:
            entry = meta.setdefault(str(row["info_hash"]).lower(), {})
            entry.setdefault("seeders", row["seeders"])
            entry.setdefault("leechers", row["leechers"])
    except Exception:  # noqa: BLE001
        pass

    return meta


async def _search_bitmagnet(
    item: dict, keyword: str, limit: int
) -> tuple[list[dict], bool | None]:
    """返回 (结果, 是否已取全)。complete=None 表示超时降级，只有部分结果。

    prefix 命中只作为超时兜底，不再提前返回。
    """

    columns = (
        "name, size, files_count, extension, created_at,"
        " encode(info_hash, 'hex') AS info_hash"
    )
    prefix = _prefix_pattern(keyword)
    seeded: list = []
    try:
        if prefix:
            seeded = await _fetch(
                item,
                f"SELECT {columns} FROM torrents WHERE name ILIKE $1"
                " ORDER BY created_at DESC, info_hash LIMIT $2",
                prefix,
                limit,
            )
        rows, complete = await _search_db(
            item,
            keyword,
            limit,
            table="torrents",
            columns=columns,
            column="name",
            title_key="name",
            tie="info_hash",
            dedupe_column="info_hash",
            timeout_ms=BITMAGNET_TIMEOUT_MS,
        )
    except asyncpg.exceptions.QueryCanceledError:
        # 中文关键词在英文库上只能全表扫描，超时时先返回前缀命中的结果，避免整组搜索失败；
        # 这批结果一定不全，返回 None 标记降级：不再扩容重试，前端会提示结果可能不完整
        if seeded:
            return _bitmagnet_items(seeded, await _bitmagnet_meta(item, seeded)), None
        raise
    return _bitmagnet_items(rows, await _bitmagnet_meta(item, rows)), complete


async def _sehuatang_meta(item: dict, rows) -> dict:
    """按 hash 批量取帖子信息：帖子标题、板块、来源帖、正文、预览图与提取码。

    ed2k_resources 与 resource_sources 是 1:1（哈希唯一索引），
    一次性批量读回比逐条回表快得多，也避免用无索引的链接数组做匹配。
    """

    hashes = [str(row["hash"] or "").upper() for row in rows if row["hash"]]
    if not hashes:
        return {}
    try:
        got = await _fetch(
            item,
            "SELECT hash, title, board_name, source_url, description, preview_images,"
            " extract_password"
            " FROM resource_sources WHERE hash = ANY($1::text[])",
            hashes,
        )
    except Exception:  # noqa: BLE001 - 元数据缺失不影响检索
        return {}
    return {str(row["hash"]).upper(): row for row in got}


async def _search_sehuatang(
    item: dict, keyword: str, limit: int
) -> tuple[list[dict], bool]:
    """返回 (结果, 是否已取全)。前缀命中只是全量匹配的子集，不能短路。"""

    rows, complete = await _search_db(
        item,
        keyword,
        limit,
        table="ed2k_resources",
        columns="filename, ed2k_link, search_string, size, created_at, hash",
        column="filename",
        title_key="filename",
        extra="\n          AND ed2k_link NOT LIKE 'unavailable://%'",
        tie="ed2k_link",
        dedupe=True,
        dedupe_column="ed2k_link",
        alt_column="search_string",
        # 文件名命中的行排在最前：色花堂大量帖子正文里堆着同一个标签，
        # 只按长度排序会把真正以该标签命名的资源挤出候选池。
        rank_columns=("filename",),
    )
    return _ed2k_items(rows, await _sehuatang_meta(item, rows)), complete


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


PROVIDERS = (
    ("bitmagnet", _search_bitmagnet),
    ("sehuatang", _search_sehuatang),
    ("ed2k", _search_sehuatang),
    ("cloudsaver", _search_cloudsaver),
    ("cloud-saver", _search_cloudsaver),
)

EXTERNAL_PROVIDERS = {_search_cloudsaver}



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
) -> list[tuple[dict, list[dict], str, bool, bool]]:
    """并发检索，返回 (服务, 本页结果, 错误信息, 是否还有更多, 是否已达候选上限)。"""

    offset = max(0, offset)

    async def run(item: dict):
        provider = resolve_provider(item)
        if provider is None:
            return item, [], "该服务尚未接入检索", False, False
        try:
            if provider in EXTERNAL_PROVIDERS:
                # 外部搜索源（CloudSaver）自带排序与游标分页，按需翻到 offset+limit 条
                rows, has_more = await provider(item, keyword, offset + limit)
                rows = _ensure_password(rows)
                return item, rows[offset : offset + limit], "", has_more, False

            key = (
                str(item.get("id") or item.get("database") or ""),
                keyword.lower().strip(),
            )
            needed = offset + limit
            entry = _db_pool_get(key)
            if entry is None:
                rows, requested, complete = [], 0, False
            else:
                rows, requested, complete = entry[1], entry[2], entry[3]

            while True:
                if requested == 0:
                    want = PAGE_CANDIDATES
                elif complete is not False or requested >= MAX_CANDIDATES:
                    break
                elif len(_rerank(keyword, rows)) > offset:
                    # 当前候选池还能覆盖这一页，先按需返回
                    break
                else:
                    want = min(
                        MAX_CANDIDATES,
                        max(needed, requested * CANDIDATE_GROWTH),
                    )
                    if want <= requested:
                        break

                # 候选池按需扩容：翻页超出当前池子（或被相关性过滤用尽）时重新取更大的 LIMIT，
                # SQL 排序固定，扩大后的结果一定包含原池子，翻页顺序保持稳定
                rows, complete = await provider(item, keyword, want)
                requested = want
                _db_pool_put(key, rows, requested, complete)

            full = _rerank(keyword, rows)
            truncated = complete is None or (
                complete is False and requested >= MAX_CANDIDATES
            )
            has_more = len(full) > needed or (
                complete is False and requested < MAX_CANDIDATES
            )
            return item, full[offset : offset + limit], "", has_more, truncated
        except _CloudSaverAuthError as exc:
            label = str(item.get("name") or "该服务")
            detail = str(exc)
            if detail and detail != "未配置凭据":
                return (
                    item,
                    [],
                    f"{label} 鉴权失败：{detail}，请更新 API Key 或账号密码",
                    False,
                    False,
                )
            return (
                item,
                [],
                f"需要在服务管理里填写 {label} 的账号密码或 API Key",
                False,
                False,
            )
        except RuntimeError as exc:
            return item, [], str(exc) or "检索失败", False, False
        except asyncio.TimeoutError:
            return item, [], "连接超时，请检查服务是否在线", False, False
        except asyncpg.exceptions.QueryCanceledError:
            return item, [], "检索超时，请换个更具体的关键词", False, False
        except Exception as exc:  # noqa: BLE001
            return item, [], f"检索失败：{type(exc).__name__}", False, False

    outcomes = list(await asyncio.gather(*(run(item) for item in items)))

    # 跨库去重：以链接里的文件哈希为准（磁力 btih / ed2k 文件哈希），
    # 同一条链在多个库出现时只输出一条；一条记录挂多条链则不参与去重。
    # 重复时保留信息更全的那条（色花堂带板块 / 来源帖 / 正文 / 预览图，
    # bitmagnet 只有种子字段），并把另一条的做种数、画质等字段补过去，
    # 避免为了去重把详情页里能展示的内容丢掉。
    picked: dict[str, dict] = {}
    identity_of: dict[int, str | None] = {}
    for _item, rows, _error, _more, _truncated in outcomes:
        for row in rows:
            identity = _link_identity(str(row.get("link") or ""))
            identity_of[id(row)] = identity
            if identity is None:
                continue
            current = picked.get(identity)
            if current is None:
                picked[identity] = row
            elif _metadata_rich(row) and not _metadata_rich(current):
                _merge_metadata(row, current)
                picked[identity] = row
            else:
                _merge_metadata(current, row)

    merged: list[tuple[dict, list[dict], str, bool, bool]] = []
    for item, rows, error, has_more, truncated in outcomes:
        kept: list[dict] = []
        for row in rows:
            identity = identity_of[id(row)]
            # 同一条链只输出选中的那条，另一条库里的副本直接丢弃
            if identity is None or picked.get(identity) is row:
                kept.append(row)
        merged.append((item, kept, error, has_more, truncated))
    return merged
