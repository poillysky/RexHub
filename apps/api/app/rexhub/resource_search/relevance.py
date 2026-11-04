"""相关性打分与重排：Python 侧的语义分层排序与去重。"""


from .keywords import (
    _is_ascii_phrase,
    _is_cjk,
    _is_full_code,
    _is_letter,
    _joined,
    _terms,
)
from .links import _link_identity


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
