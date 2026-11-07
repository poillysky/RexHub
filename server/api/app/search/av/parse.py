"""番号解析：FC2 / date6 / 欧美日戳 / 固定前缀 / std 番号 → ParsedMakerCode。

入口 parse_maker_code 按优先级尝试各形态解析器；normalize_maker_code
做全角归一。is_uncensored_maker_code / is_av_code_keyword 为判定快捷方式。
"""


import re
from dataclasses import dataclass

# 无码 N 系列番号（N1234 等）；FC2/date6 等天然无码形态在 is_uncensored_maker_code 里单独判定
UNCENSORED_PREFIX_RE = re.compile(r"^N\d{2,}")

from app.search.av.prefixes import (
    DATE6_PREFIX_LABEL,
    PREFIX_SHAPE,
    _china_prefix_set,
    _prefix_key,
    _western_key,
    is_western_studio_prefix,
    resolve_maker_shape,
)


@dataclass(frozen=True)
class ParsedMakerCode:
    shape: str
    canonical: str
    parts: list[str]
    prefix: str


def normalize_maker_code(keyword: str) -> str:
    s = str(keyword or "").strip()
    s = re.sub(r"[－—–﹣]", "-", s)

    def half(ch: str) -> str:
        o = ord(ch)
        if 0xFF10 <= o <= 0xFF19 or 0xFF21 <= o <= 0xFF3A or 0xFF41 <= o <= 0xFF5A:
            return chr(o - 0xFEE0)
        return ch

    return "".join(half(c) for c in s)


def maker_code_parts(code: str) -> list[str]:
    raw = normalize_maker_code(code).upper()
    spaced = [p for p in re.split(r"[-_\s.]+", raw) if p]
    if len(spaced) >= 2:
        return spaced
    piece = spaced[0] if spaced else raw
    if not piece:
        return []
    if re.fullmatch(r"\d+", piece):
        return [piece]
    glued = re.fullmatch(r"([A-Z]{2,20})(\d{2,10})", piece)
    if glued:
        return [glued.group(1), glued.group(2)]
    return [piece]


def _parse_fc2(raw: str) -> ParsedMakerCode | None:
    u = normalize_maker_code(raw).upper()
    m = re.fullmatch(r"FC2[-_\s.]?PPV[-_\s.]?(\d{5,10})", u, re.I)
    if m:
        return ParsedMakerCode(
            "fc2ppv", f"FC2-PPV-{m.group(1)}", ["FC2", "PPV", m.group(1)], "FC2PPV"
        )
    m = re.fullmatch(r"FC2(?![-_\s.]?PPV)[-_\s.]?(\d{5,10})", u, re.I)
    if m:
        return ParsedMakerCode(
            "fc2", f"FC2-{m.group(1)}", ["FC2", m.group(1)], "FC2"
        )
    return None


def _parse_date6(raw: str) -> ParsedMakerCode | None:
    u = normalize_maker_code(raw).upper()
    m = re.fullmatch(
        r"([A-Z0-9]{2,20})[-_\s.]?(\d{6})[-_\s.](\d{2,3})(?:[-_\s.]?[A-Z]{0,2})?",
        u,
        re.I,
    )
    if not m:
        return None
    label = (
        DATE6_PREFIX_LABEL.get(_prefix_key(m.group(1)))
        or DATE6_PREFIX_LABEL.get(_western_key(m.group(1)))
        or _prefix_key(m.group(1))
    )
    if PREFIX_SHAPE.get(_prefix_key(m.group(1))) == "date6" or label in DATE6_PREFIX_LABEL.values():
        return ParsedMakerCode(
            "date6",
            f"{label}-{m.group(2)}-{m.group(3)}",
            [label, m.group(2), m.group(3)],
            label,
        )
    return None


def _parse_alnum(raw: str) -> ParsedMakerCode | None:
    u = normalize_maker_code(raw).upper()
    m = re.fullmatch(r"([HC]0930|H4610)[-_\s.]?([A-Z0-9]{3,24})", u, re.I)
    if not m:
        return None
    prefix = m.group(1).upper()
    ident = m.group(2).upper()
    return ParsedMakerCode("alnum_id", f"{prefix}-{ident}", [prefix, ident], prefix)


def _parse_tokyohot(raw: str) -> ParsedMakerCode | None:
    """TOKYOHOT-n1234 / TOKYO-HOT-1234 → TOKYOHOT-N1234。"""
    u = normalize_maker_code(raw).upper()
    m = re.fullmatch(r"TOKYO[-_\s]?HOT[-_\s.]?N?(\d{3,5})", u, re.I)
    if not m:
        return None
    body = f"N{m.group(1)}"
    return ParsedMakerCode(
        "fixed_std", f"TOKYOHOT-{body}", ["TOKYOHOT", body], "TOKYOHOT"
    )


def _parse_mesubuta(raw: str) -> ParsedMakerCode | None:
    """MESUBUTA-123456-001（勿被 std 剥成两段）。"""
    u = normalize_maker_code(raw).upper()
    m = re.fullmatch(r"MESUBUTA[-_\s.]?(\d{6})[-_\s.](\d{2,3})", u, re.I)
    if not m:
        return None
    can = f"MESUBUTA-{m.group(1)}-{m.group(2)}"
    return ParsedMakerCode(
        "fixed_std", can, ["MESUBUTA", m.group(1), m.group(2)], "MESUBUTA"
    )


def _parse_gachi(raw: str) -> ParsedMakerCode | None:
    """GACHI-123 / GACHINCO-123 → GACHI-123。"""
    u = normalize_maker_code(raw).upper()
    m = re.fullmatch(r"GACHI(?:NCO)?[-_\s.]?(\d{3,5})", u, re.I)
    if not m:
        return None
    can = f"GACHI-{m.group(1)}"
    return ParsedMakerCode("std", can, ["GACHI", m.group(1)], "GACHI")


def _western_yyyy(yy_or_yyyy: str) -> str:
    """两位年 → 四位年（26 → 2026）；已是 19xx/20xx 则原样。"""
    s = str(yy_or_yyyy or "").strip()
    if re.fullmatch(r"19\d{2}|20\d{2}", s):
        return s
    if re.fullmatch(r"\d{2}", s):
        return f"20{s}"
    return s


def _parse_western(raw: str) -> ParsedMakerCode | None:
    u = normalize_maker_code(raw).upper()
    # KEY.YYYY.MM.DD（四位年完整日）
    m = re.fullmatch(
        r"([A-Z]{2,24})[._\-\s]?(19\d{2}|20\d{2})[._\-](\d{2})[._\-](\d{2})",
        u,
        re.I,
    )
    if m and is_western_studio_prefix(m.group(1)):
        key = _western_key(m.group(1))
        yyyy, mo, d = m.group(2), m.group(3), m.group(4)
        can = f"{key}.{yyyy}.{mo}.{d}"
        return ParsedMakerCode("western_date", can, [key, yyyy, mo, d], key)
    # KEY.YY.MM.DD / KEY-YY-MM-DD（两位年 → 四位）
    m = re.fullmatch(
        r"([A-Z]{2,24})[._\-\s]?(\d{2})[._\-](\d{2})[._\-](\d{2})", u, re.I
    )
    if m and is_western_studio_prefix(m.group(1)):
        key = _western_key(m.group(1))
        y, mo, d = m.group(2), m.group(3), m.group(4)
        # 避免把 2023.06.24 误拆成 20.23.06
        if y in ("19", "20"):
            return None
        yyyy = _western_yyyy(y)
        can = f"{key}.{yyyy}.{mo}.{d}"
        return ParsedMakerCode(
            "western_date", can, [key, yyyy, mo, d], key
        )
    # KEY-260513 / KEY.260513 紧凑六位 → KEY.2026.05.13
    m = re.fullmatch(r"([A-Z]{2,24})[-_\s.](\d{6})", u, re.I)
    if m and is_western_studio_prefix(m.group(1)):
        key = _western_key(m.group(1))
        ymd = m.group(2)
        y, mo, d = ymd[:2], ymd[2:4], ymd[4:6]
        yyyy = _western_yyyy(y)
        can = f"{key}.{yyyy}.{mo}.{d}"
        return ParsedMakerCode(
            "western_date", can, [key, yyyy, mo, d], key
        )
    # KEY.YYYY.MM 合集月号
    m = re.fullmatch(
        r"([A-Z]{2,24})[._\-\s]?(19\d{2}|20\d{2})[._\-](\d{2})", u, re.I
    )
    if m and is_western_studio_prefix(m.group(1)):
        key = _western_key(m.group(1))
        return ParsedMakerCode(
            "western_ym",
            f"{key}.{m.group(2)}.{m.group(3)}",
            [key, m.group(2), m.group(3)],
            key,
        )
    # KEY.YYYY / KEY-YYYY 年份
    m = re.fullmatch(
        r"([A-Z]{2,24})[._\-\s]?(19\d{2}|20\d{2})", u, re.I
    )
    if m and is_western_studio_prefix(m.group(1)):
        key = _western_key(m.group(1))
        return ParsedMakerCode(
            "western_year",
            f"{key}.{m.group(2)}",
            [key, m.group(2)],
            key,
        )
    # 不再把裸数字当成欧美集数键（易误吃 2160/4K 等）
    return None


def _parse_std(raw: str) -> ParsedMakerCode | None:
    u = normalize_maker_code(raw).upper()
    # 先剥分集尾巴，番号键只要基号：MDSR-0002-EP3 / MDSR-0002-4 → MDSR-0002
    # 注意：(?:EP|E)? 不能写成可选，否则 SONE-15 会被整段剥成 SONE。
    u = re.sub(r"[-_\s.](?:EP|E)[-_\s.]?\d{1,2}$", "", u, flags=re.I)
    u = re.sub(
        r"^([A-Z0-9]+[-_\s.]\d{2,10})[-_\s.]\d{1,2}$",
        r"\1",
        u,
        flags=re.I,
    )
    m = re.fullmatch(
        r"(?:(\d{2,3}))?([A-Z]{2,20})[-_\s.]?(\d{2,10})(?:[-_\s.]?([A-Z0-9]{1,6}))?",
        u,
        re.I,
    )
    if not m:
        return None
    leading = (m.group(1) or "").strip()
    letters = m.group(2).upper()
    num = m.group(3)
    # 默认丢掉前缀数字板号（259LUXU → LUXU）；国产 91CM 等保留
    prefix = letters
    if leading:
        combined = f"{leading}{letters}"
        try:
            if combined in _china_prefix_set():
                prefix = combined
        except Exception:
            pass
    shape = resolve_maker_shape(prefix)
    if shape in {"fc2", "fc2ppv", "date6", "alnum_id"}:
        return None
    return ParsedMakerCode("std", f"{prefix}-{num}", [prefix, num], prefix)


def parse_maker_code(keyword: str) -> ParsedMakerCode | None:
    raw = normalize_maker_code(keyword)
    if not raw or len(raw) > 48:
        return None
    return (
        _parse_fc2(raw)
        or _parse_alnum(raw)
        or _parse_date6(raw)
        or _parse_tokyohot(raw)
        or _parse_mesubuta(raw)
        or _parse_gachi(raw)
        or _parse_western(raw)
        or _parse_std(raw)
    )


def is_av_code_keyword(keyword: str) -> bool:
    return parse_maker_code(keyword) is not None


def is_uncensored_maker_code(keyword: str) -> bool:
    parsed = parse_maker_code(keyword)
    if parsed and parsed.shape in {"fc2", "fc2ppv", "date6", "alnum_id"}:
        return True
    return bool(UNCENSORED_PREFIX_RE.match(normalize_maker_code(keyword)))
