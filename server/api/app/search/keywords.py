"""Keyword extraction + WHERE / ORDER builders — Bitmagnet-style match + optional enrich."""


import math
import re
from typing import Any, Literal

from app.search.jieba_cut import jieba_cut
from app.search.av import (
    build_av_code_ilike_patterns,
    is_av_code_keyword,
)
from app.search.constants import (
    FUZZY_STOPWORDS,
    QUOTED_KEYWORD_REGEX,
    SEARCH_KEYWORD_SPLIT_REGEX,
    SEARCH_KEYWORD_SPLIT_REGEX_EXACT,
    escape_ilike,
)
from app.search.prefer import SEARCH_NAME_EXPR

# PostgreSQL: ESCAPE '\' — backslash quotes % / _
_ILIKE_ESC = "ESCAPE '\\'"

# 影视多片名 / 中英别名：强分隔 → 各词整串匹配后 OR（勿空格拼成 AND）
_ALIAS_QUERY_SEP = re.compile(r"[,;，、；|｜/\n\r]+")

# 纯字母厂牌/前缀（SONS、SSIS…）：避免 `%SONS%` 全表扫
_MAKER_PREFIX_RE = re.compile(r"^[A-Za-z]{2,8}$")
_CJK_RE = re.compile(r"[\u4e00-\u9fff]")

MatchField = Literal["both", "filename", "title", "search"]


def split_alias_query_terms(q: str, *, limit: int = 2) -> list[str]:
    """逗号/顿号等拆成多个完整片名；不含强分隔时整段保留。

    默认最多 2 词（中+英）：过多 OR ILIKE 易拖垮色花/BT 库超时。
    """
    s = (q or "").strip()
    if not s:
        return []
    if not _ALIAS_QUERY_SEP.search(s):
        t = s.strip().strip(".,;:!?，、；")
        return [t] if t else []
    out: list[str] = []
    seen: set[str] = set()
    for part in _ALIAS_QUERY_SEP.split(s):
        t = str(part or "").strip().strip(".,;:!?，、；")
        if len(t) < 2:
            continue
        key = t.casefold()
        if key in seen:
            continue
        seen.add(key)
        out.append(t)
        if len(out) >= limit:
            break
    return out


def split_chinese_bigrams(text: str) -> list[dict[str, Any]]:
    """按连续中文片段取二元组；跨空格/标点会拼出「文字」这类假 token。"""
    out: list[dict[str, Any]] = []
    for run in re.findall(r"[\u4e00-\u9fff]+", text):
        for i in range(len(run) - 1):
            out.append({"keyword": run[i : i + 2], "required": False})
    return out


def extract_keywords(
    keyword: str, match_mode: str = "exact"
) -> list[dict[str, Any]]:
    # 番号整串保留：切成 SSIS / 001 后 fuzzy 会把 XWJ-0013 之类糊进来
    if is_av_code_keyword(keyword):
        return [{"keyword": keyword.strip(), "required": True}]

    alias_terms = split_alias_query_terms(keyword)
    if len(alias_terms) > 1:
        return [{"keyword": t, "required": False} for t in alias_terms]

    keywords: list[dict[str, Any]] = []
    for m in QUOTED_KEYWORD_REGEX.finditer(keyword):
        keywords.append({"keyword": m.group(1), "required": True})

    remaining = QUOTED_KEYWORD_REGEX.sub("", keyword)
    plain = remaining.strip()
    split_re = (
        SEARCH_KEYWORD_SPLIT_REGEX_EXACT
        if match_mode == "exact"
        else SEARCH_KEYWORD_SPLIT_REGEX
    )
    keywords.extend(
        {"keyword": k, "required": match_mode == "exact"}
        for k in split_re.split(plain)
        if k
    )

    if match_mode == "fuzzy" and len(plain) >= 2:
        keywords.extend(jieba_cut(plain))
    elif match_mode == "smart" and len(keywords) == 1 and len(plain) >= 4:
        keywords.extend(jieba_cut(plain))

    if match_mode == "fuzzy" and len(plain) >= 4:
        keywords.extend(split_chinese_bigrams(plain))

    min_len = 1 if match_mode == "fuzzy" else 2
    seen: dict[str, dict[str, Any]] = {}
    for item in keywords:
        kw = str(item["keyword"]).strip()
        if len(kw) < min_len:
            continue
        if kw.lower() in FUZZY_STOPWORDS:
            continue
        seen[kw] = {"keyword": kw, "required": bool(item["required"])}
    keywords = list(seen.values())

    if match_mode == "fuzzy":
        # 去掉被更长 token 包含的词（三浦/歩/美/浦歩/歩美 ⊂ 三浦歩美）：
        # 既避免「歩」「美」这类单字把无关结果带进来，也少扫几遍库
        keywords = _prune_subsumed(keywords)
        return keywords or [{"keyword": plain or keyword, "required": False}]

    if match_mode == "exact":
        if not keywords:
            return [{"keyword": plain or keyword, "required": True}]
        return [{"keyword": x["keyword"], "required": True} for x in keywords]

    if keywords and not any(x["required"] for x in keywords):
        n = max(1, math.ceil(len(keywords) / 3))
        for k in sorted(keywords, key=lambda x: len(x["keyword"]), reverse=True)[
            :n
        ]:
            k["required"] = True

    full = keyword.replace('"', "")
    if not any(x["keyword"] == full for x in keywords):
        keywords.insert(0, {"keyword": full, "required": False})
    return keywords


def _token_match_clause(field: MatchField = "both") -> str:
    """Bitmagnet: single-column ILIKE；勿 COALESCE(title)，否则吃不到 gin_trgm。"""
    if field == "filename":
        return f"(r.filename ILIKE %s {_ILIKE_ESC})"
    if field == "title":
        return f"(rs.title ILIKE %s {_ILIKE_ESC})"
    # search_string 已含文件名+帖子标题+正文，单表即可覆盖两字段（免 JOIN 74 万行）
    if field == "search":
        return f"(r.search_string ILIKE %s {_ILIKE_ESC})"
    return (
        f"(r.filename ILIKE %s {_ILIKE_ESC} "
        f"OR rs.title ILIKE %s {_ILIKE_ESC})"
    )


def _params_for_like(like: str, field: MatchField) -> list[str]:
    return [like, like] if field == "both" else [like]


def has_cjk(text: str) -> bool:
    """含中日韩字符时 pg_trgm 在本库提取不到三元组（similarity 恒 0），别走 trigram。"""
    return bool(_CJK_RE.search(text or ""))


def trgm_usable(keyword: str) -> bool:
    return not has_cjk(keyword)


def _like_contains(keyword: str) -> str:
    return f"%{escape_ilike(keyword)}%"


# 汉字区间（参数里拼，SQL 文本保持 ASCII）
_CJK_LO = chr(0x4E00)
_CJK_HI = chr(0x9FFF)
# 罗马数字 Ⅰ–Ⅻ、全角数字：续集标记（流浪地球Ⅱ）属于标题内容，不能当分隔符
_TITLE_NUM = f"{chr(0x2160)}-{chr(0x217F)}{chr(0xFF10)}-{chr(0xFF19)}"
# 相关性归一化：去掉空白/标点，使《流浪地球》与流浪地球同档
_NAME_STRIP_RE = f"[^0-9a-z{_TITLE_NUM}{_CJK_LO}-{_CJK_HI}]"


# 扩展名：相关性判定时忽略，`流浪地球.mkv` 应与 `流浪地球` 同档
_EXT_TAIL_RE = re.compile(r"\.[a-z0-9]{1,6}$", re.I)


def _normalize_name(text: str) -> str:
    return re.sub(_NAME_STRIP_RE, "", (text or "").lower())


def _stem_name(text: str) -> str:
    """去掉扩展名（仅用于相关性档位，不影响匹配）。"""
    return _EXT_TAIL_RE.sub("", (text or "").lower())


# 参与「词元」判定的字符：字母/数字/汉字/罗马数字；其余都算分隔符
_NAME_CHAR_RE = re.compile(f"^[0-9a-z{_TITLE_NUM}{_CJK_LO}-{_CJK_HI}]$")


def _token_boundary_res(keyword: str) -> tuple[str, str]:
    """返回 (词元在开头, 词元在任意位置) 两条正则：词元两侧都必须是分隔符。"""
    esc = re.escape(keyword)
    return (
        f"^{esc}({_NAME_STRIP_RE}|$)",
        f"(^|{_NAME_STRIP_RE}){esc}({_NAME_STRIP_RE}|$)",
    )


def name_rank(name: str, keyword: str) -> int:
    """与 SQL `_name_rank_case` 同口径（0–6 档），供 Python 侧合并排序用。

    0 同名（忽略扩展名）→ 1 去符号同名（《流浪地球》）→ 2 词元在开头且后接分隔符
    → 3 词元独立出现在中间/结尾 → 4 粘连前缀（流浪地球2）→ 5 仅包含 → 6 其它。
    """
    n = (name or "").lower()
    k = (keyword or "").strip().lower()
    if not k:
        return 6
    if n == k or _stem_name(n) == k:
        return 0
    if _normalize_name(_stem_name(n)) == _normalize_name(k):
        return 1
    idx = n.find(k)
    while idx != -1:
        end = idx + len(k)
        left_ok = idx == 0 or not _NAME_CHAR_RE.match(n[idx - 1])
        right_ok = end >= len(n) or not _NAME_CHAR_RE.match(n[end])
        if left_ok and right_ok:
            return 2 if idx == 0 else 3
        idx = n.find(k, idx + 1)
    if n.startswith(k):
        return 4
    if k in n:
        return 5
    return 6



def _is_maker_prefix_token(keyword: str) -> bool:
    """厂牌前缀多为全大写短码（SONS/SSIS）；Title Case 片名不走此分支。"""
    s = keyword.strip()
    return bool(_MAKER_PREFIX_RE.fullmatch(s) and s.isupper())


def _maker_prefix_like_patterns(keyword: str) -> list[str]:
    """2 字母厂牌码：只枚举分隔形态，避免裸 `%SS%` 全表扫（实测 1.7s）。

    3 字母以上能走 gin_trgm（SONE 0.04s），用全包含匹配，别在这里漏
    `-SONE`/`_SONE`/`《SONE》` 这类形态。
    """
    esc = escape_ilike(keyword.strip())
    return [
        f"{esc}%",
        f"%{esc}-%",
        f"%{esc} %",
        f"%[{esc}%",
        f"%({esc}%",
        f"%.{esc}%",
    ]


def _token_or_clause(
    keyword: str,
    field: MatchField,
) -> tuple[str, list[str]]:
    """单 token → (sql片段, params)。

    一律只做包含匹配（召回优先）：词元边界/完整度只影响相关性档位
    （见 ``_name_rank_case``），不再在 WHERE 里剔除结果。
    """
    kw = (keyword or "").strip().strip(".,;:!?，、；")
    clause = _token_match_clause(field)
    # 仅 2 字母全大写（SS）在单表路径会失去 trigram 加速，才退化为分隔形态；
    # 其余一律全包含，否则 `-SONE`/`_SONE` 之类会被漏掉（实测 SONE 少 434 条）
    if _is_maker_prefix_token(kw) and field == "search" and len(kw) < 3:
        parts: list[str] = []
        params: list[str] = []
        for pat in _maker_prefix_like_patterns(kw):
            parts.append(clause)
            params.extend(_params_for_like(pat, field))
        return "(" + " OR ".join(parts) + ")", params
    like = _like_contains(kw)
    return clause, _params_for_like(like, field)


def _prune_subsumed(keywords: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """丢掉被更长 token 包含的 token；全被包含时保留原串。"""
    low = [str(i["keyword"]).lower() for i in keywords]
    keep = [
        item
        for i, item in enumerate(keywords)
        if not any(
            j != i and low[i] in low[j] and len(low[j]) > len(low[i])
            for j in range(len(low))
        )
    ]
    return keep or keywords


def build_candidate_clause(
    keywords: list[dict[str, Any]],
    full_keyword: str | None = None,
) -> tuple[str, list[Any]]:
    """宽松候选：search_string 命中任一 token 即可（OR，无词边界）。

    仅供两阶段查询的第一步缩小扫描范围；最终是否命中仍由
    ``build_keyword_filter`` 在 JOIN meta 之后判定，结果集不变。
    search_string 含文件名+帖子标题+正文，故是 filename/title 匹配的超集。
    """
    terms = split_alias_query_terms(full_keyword or "")
    raw = [str(i["keyword"]) for i in keywords]
    if len(terms) > 1:
        raw.extend(terms)
    parts: list[str] = []
    params: list[Any] = []
    for kw in dict.fromkeys(x for x in raw if x.strip()):
        parts.append(f"(r.search_string ILIKE %s {_ILIKE_ESC})")
        params.append(_like_contains(kw))
    if not parts:
        return "TRUE", []
    return "(" + " OR ".join(parts) + ")", params


def _cjk_run_bigrams(text: str) -> list[str]:
    """按空白/标点切出的连续中文片段取二元组，不跨段拼接（避免「美中」这类假 gram）。"""
    out: list[str] = []
    for run in re.findall(r"[\u4e00-\u9fff]+", text):
        out.extend(run[i : i + 2] for i in range(len(run) - 1))
    return out


def build_cjk_bigram_clause(
    keywords: list[dict[str, Any]],
    full_keyword: str | None = None,
) -> tuple[str, list[Any]]:
    """中文匹配：search_string 的 cjk_bigrams GIN（覆盖文件名/标题/正文）。

    search_string 已含文件名与帖子标题，所以这里一次命中就是最终结果，
    调用方（``search_resources``）无需再做 filename/title 精判。
    多个 token 按 AND（精确匹配语义），中英别名按 OR。
    无二元组的 token（纯 ASCII / 单字）退回 ILIKE，仍参与 AND。
    """
    terms = split_alias_query_terms(full_keyword or "")
    alias_mode = len(terms) > 1
    raw = terms if alias_mode else [str(i["keyword"]) for i in keywords]
    parts: list[str] = []
    params: list[Any] = []
    for kw in dict.fromkeys(x for x in raw if x.strip()):
        like = _like_contains(kw.strip().strip(".,;:!?，、；"))
        grams = list(dict.fromkeys(_cjk_run_bigrams(kw)))
        if grams:
            # 二元组 @> 只是子串的超集（「中文字幕」也会放行「字幕中文」），
            # 补一次 ILIKE 才能把候选压到命中量级（实测 1.2s → 5.8s 的差别）。
            parts.append(
                f"(r.search_string ILIKE %s {_ILIKE_ESC}"
                " AND cjk_bigrams(r.search_string) @> %s::text[])"
            )
            params.extend([like, grams])
        else:
            parts.append(f"(r.search_string ILIKE %s {_ILIKE_ESC})")
            params.append(like)
    if not parts:
        return "TRUE", []
    return "(" + (" OR " if alias_mode else " AND ").join(parts) + ")", params


def build_exact_keyword_clause(
    keywords: list[dict[str, Any]],
    *,
    field: MatchField = "both",
) -> tuple[str, list[Any], list[str]]:
    """Returns (sql, params, code_bound_keywords)."""
    if not keywords:
        return "FALSE", [], []
    parts: list[str] = []
    params: list[Any] = []
    code_bound: list[str] = []
    clause = _token_match_clause(field)
    for item in keywords:
        kw = str(item["keyword"])
        if is_av_code_keyword(kw) and field != "search":
            patterns = build_av_code_ilike_patterns(kw)
            or_parts = []
            for pat in patterns:
                or_parts.append(clause)
                params.extend(_params_for_like(pat, field))
            parts.append("(" + " OR ".join(or_parts) + ")")
            code_bound.append(kw)
        else:
            frag, frag_params = _token_or_clause(kw, field)
            parts.append(frag)
            params.extend(frag_params)
    return " AND ".join(parts), params, code_bound


def build_alias_or_clause(
    terms: list[str],
    *,
    field: MatchField = "both",
) -> tuple[str, list[Any], list[str]]:
    """每个片名整串匹配，片名之间 OR。"""
    if not terms:
        return "FALSE", [], []
    parts: list[str] = []
    params: list[Any] = []
    for t in terms:
        frag, frag_params = _token_or_clause(t, field)
        parts.append(frag)
        params.extend(frag_params)
    return "(" + " OR ".join(parts) + ")", params, []


def build_keyword_filter(
    keywords: list[dict[str, Any]],
    match_mode: str,
    *,
    full_keyword: str | None = None,
    field: MatchField = "both",
) -> tuple[str, list[Any], list[str]]:
    """Return (sql, params, code_bound_keywords)."""
    if not keywords:
        return "FALSE", [], []

    # 中英别名多片名：顿号/逗号分隔 → OR
    alias_terms = split_alias_query_terms(full_keyword or "")
    if len(alias_terms) > 1:
        return build_alias_or_clause(alias_terms, field=field)

    if match_mode == "exact":
        return build_exact_keyword_clause(keywords, field=field)

    if match_mode == "fuzzy":
        # 去掉被更长 token 包含的词（流浪/地球/浪地 ⊂ 流浪地球）：
        # 命中长 token 必然命中短的，留着只是多扫几遍 74 万行
        keywords = _prune_subsumed(keywords)
        clauses: list[str] = []
        params: list[Any] = []
        for item in keywords:
            frag, frag_params = _token_or_clause(str(item["keyword"]), field)
            clauses.append(frag)
            params.extend(frag_params)
        # 0.5 太松：中文只命中一半字也进结果；0.6 且至少 2 个 token 才放行
        ratio = math.ceil(len(keywords) * 0.6)
        min_matches = max(2, ratio) if len(keywords) >= 3 else max(1, ratio)
        if min_matches >= len(keywords):
            # 等价于全部命中：直接 AND，避免 CASE 表达式挡住索引
            return " AND ".join(f"({c})" for c in clauses), params, []
        case_parts = [f"(CASE WHEN {c} THEN 1 ELSE 0 END)" for c in clauses]
        token_match = f"(({' + '.join(case_parts)}) >= {min_matches})"
        # 不再用 trigram 兜底：word_similarity 会把 Reacher 命中 TEACHER 这类
        # 词形相近但无关的结果带进来（准确优先）
        return token_match, params, []

    # smart — Bitmagnet: required AND + optional OR
    required: list[str] = []
    optional: list[str] = []
    params: list[Any] = []
    for item in keywords:
        frag, frag_params = _token_or_clause(str(item["keyword"]), field)
        params.extend(frag_params)
        if item["required"]:
            required.append(frag)
        else:
            optional.append(frag)
    parts = list(required)
    if optional:
        optional.append("TRUE")
        parts.append("(" + " OR ".join(optional) + ")")
    return (" AND ".join(parts) if parts else "FALSE"), params, []


def _name_rank_case(expr: str) -> str:
    """同一检索名的命中档：0 同名（忽略扩展名）→ 1 去符号同名（《流浪地球》）
    → 2 词元在开头且后接分隔符（流浪地球 1080p / 流浪地球.The）
    → 3 词元独立出现在中间/结尾（2019.流浪地球.1080p / SDNM-188 三浦歩美）
    → 4 粘连前缀（流浪地球2 / 流浪地球特别版）→ 5 仅包含 → 6 其它。"""
    return (
        f"CASE WHEN lower({expr}) = lower(%s) THEN 0"
        f" WHEN regexp_replace(lower({expr}), %s, '') = lower(%s) THEN 0"
        f" WHEN regexp_replace(regexp_replace(lower({expr}), %s, ''), %s, '', 'g')"
        f" = %s THEN 1"
        f" WHEN {expr} ~* %s THEN 2"
        f" WHEN {expr} ~* %s THEN 3"
        f" WHEN {expr} ILIKE %s THEN 4"
        f" WHEN {expr} ILIKE %s THEN 5"
        f" ELSE 6 END"
    )


def _name_rank_params(term: str) -> list[Any]:
    """`_name_rank_case` 的占位符参数（顺序必须与 CASE 分支一致）。"""
    start_re, any_re = _token_boundary_res(term)
    esc = escape_ilike(term)
    return [
        term,
        _EXT_TAIL_RE.pattern,
        term,
        _EXT_TAIL_RE.pattern,
        _NAME_STRIP_RE,
        _normalize_name(term),
        start_re,
        any_re,
        f"{esc}%",
        f"%{esc}%",
    ]


def build_relevance_order_by(
    keywords: list[dict[str, Any]],
    full_keyword: str,
    *,
    use_trgm: bool,
) -> tuple[str, list[Any]]:
    """相关性：命中语义越高越前（档位优先，token 权重/相似度次之）。

    档位取 title / filename 里更好的一个（同一部作品任一侧命中即算），
    再按 filename 档位区分「文件名就是这部作品」与「只是帖子标题提到」；
    同档按 token 覆盖/相似度 → 名称长度（BM25 长度归一化）→ 体积 → 时间。
    """
    kw = (full_keyword or "").strip()
    terms = split_alias_query_terms(kw) or ([kw] if kw else [""])
    alias_mode = len(terms) > 1

    def _rank_expr(expr: str) -> tuple[str, list[Any]]:
        cases: list[str] = []
        ps: list[Any] = []
        for t in terms:
            cases.append(_name_rank_case(expr))
            ps.extend(_name_rank_params(t))
        sql = cases[0] if len(cases) == 1 else f"LEAST({', '.join(cases)})"
        return sql, ps

    title_rank, title_ps = _rank_expr("rs.title")
    file_rank, file_ps = _rank_expr("r.filename")
    score_ps: list[Any] = []

    if alias_mode:
        # 中英别名是同一部作品的不同写法：取匹配最好的那个，不做累加
        alias_parts: list[str] = []
        for t in terms:
            frag, frag_params = _token_or_clause(t, "both")
            alias_parts.append(f"(CASE WHEN {frag} THEN 10 ELSE 0 END)")
            score_ps.extend(frag_params)
        score = f"GREATEST({', '.join(alias_parts)})"
    else:
        token_parts: list[str] = []
        for i, item in enumerate(keywords):
            weight = 10 if i == 0 else (3 if item["required"] else 1)
            frag, frag_params = _token_or_clause(str(item["keyword"]), "both")
            token_parts.append(f"(CASE WHEN {frag} THEN {weight} ELSE 0 END)")
            score_ps.extend(frag_params)
        score = " + ".join(token_parts) if token_parts else "0"

    if use_trgm:
        if alias_mode:
            sims: list[str] = []
            for t in terms:
                sims.append(
                    f"(COALESCE(word_similarity(%s, {SEARCH_NAME_EXPR}), 0) * 20"
                    f" + COALESCE(similarity({SEARCH_NAME_EXPR}, %s), 0) * 10)"
                )
                score_ps.extend([t, t])
            score += f" + GREATEST({', '.join(sims)})"
        else:
            score += (
                f" + (COALESCE(word_similarity(%s, {SEARCH_NAME_EXPR}), 0) * 20"
                f" + COALESCE(similarity({SEARCH_NAME_EXPR}, %s), 0) * 10)"
            )
            score_ps.extend([kw, kw])

    tier = f"LEAST({title_rank}, {file_rank})"
    order = (
        f"{tier} ASC, {file_rank} ASC, ({score}) DESC,"
        " length(r.filename) ASC,"
        " r.size DESC NULLS LAST, r.created_at DESC, r.hash ASC"
    )
    # file_rank 在 tier 与字段权重中各出现一次，占位符要按文本顺序重复给参
    return order, [*title_ps, *file_ps, *file_ps, *score_ps]
