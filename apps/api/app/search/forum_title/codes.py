"""番号/FC2 代号剥除：按码缓存正则（含补零变体）+ 通用番号 token。"""


import re
from functools import lru_cache

from app.search.forum_title.patterns import _WS_RE

_CODE_NEEDLE_PARSE_RE = re.compile(r"([A-Z0-9]+)-0*(\d+)", re.I)
_NON_DIGIT_RE = re.compile(r"\D")
_GENERIC_CODE_TOKEN_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:FC2(?:[-_]?PPV)?[-_]?\d{4,10}|"
    r"[A-Z]{2,12}[-_\s]?\d{1,6})(?![A-Za-z0-9])"
)


@lru_cache(maxsize=4096)
def _code_specific_res(needle: str) -> tuple[re.Pattern[str] | None, re.Pattern[str] | None]:
    """按番号缓存剥码正则（含补零变体 / FC2）。"""
    n = str(needle or "").strip().upper()
    if not n:
        return None, None
    code_re: re.Pattern[str] | None = None
    fc2_re: re.Pattern[str] | None = None
    m = _CODE_NEEDLE_PARSE_RE.fullmatch(n)
    if m:
        pref, num_i = m.group(1), int(m.group(2))
        code_re = re.compile(
            rf"(?i)(?:[（(]\s*)?(?<![A-Za-z0-9])(?:\d{{2,3}})?{re.escape(pref)}"
            rf"[-_\s]?0*{num_i}(?!\d)(?:\s*[）)])?"
        )
    if n.startswith("FC2"):
        digits = _NON_DIGIT_RE.sub("", n)
        if digits:
            fc2_re = re.compile(
                rf"(?i)(?<![A-Za-z0-9])FC2(?:[-_]?PPV)?[-_]?{digits}(?!\d)"
            )
    return code_re, fc2_re


@lru_cache(maxsize=4096)
def _needle_clean_res(
    needle: str,
) -> tuple[re.Pattern[str], re.Pattern[str], re.Pattern[str], re.Pattern[str]]:
    """清洗阶段：题首/文中/括号内剥番号。"""
    esc = re.escape(str(needle or "").strip())
    return (
        re.compile(rf"^(?:[【\[]\s*)?{esc}(?:\s*[】\]])?[\s\-_:：.]*", re.I),
        re.compile(rf"(?:^|[\s\-–—]){esc}(?=[\s\-–—]|$)", re.I),
        re.compile(rf"(?<![A-Za-z0-9]){esc}(?![A-Za-z0-9])", re.I),
        re.compile(rf"\({esc}\)|（{esc}）", re.I),
    )


@lru_cache(maxsize=4096)
def _needle_ext_re(needle: str) -> re.Pattern[str]:
    esc = re.escape(str(needle or "").strip())
    return re.compile(rf"{esc}\.(?:mp4|mkv|avi|iso)", re.I)


def _strip_code_tokens(t: str, code: str = "") -> str:
    """剥题内番号/FC2 代号（含补零变体）；全区分共用。"""
    s = str(t or "").strip()
    if not s:
        return ""
    needle = str(code or "").strip().upper()
    if needle:
        code_re, fc2_re = _code_specific_res(needle)
        if code_re is not None:
            s = code_re.sub(" ", s)
        if fc2_re is not None:
            s = fc2_re.sub(" ", s)
    s = _GENERIC_CODE_TOKEN_RE.sub(" ", s)
    return _WS_RE.sub(" ", s).strip(" .·・-–—")
