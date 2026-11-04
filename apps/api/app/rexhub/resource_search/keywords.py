"""关键词解析：拆词分级放宽与 SQL 匹配条件构造。"""


import re

from .constants import MAX_TOKENS


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


def _is_cjk(char: str) -> bool:
    return "\u3400" <= char <= "\u9fff" or "\uf900" <= char <= "\ufaff"
