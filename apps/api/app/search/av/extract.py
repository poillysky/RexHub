"""文本抽码：从文件名/标题 blob 按前缀形态抽取规范番号。

按 resolve_maker_shape 分派 FC2 / date6 / alnum / 欧美 / std 抽取器；
std 抽取用 code_read profile 做数字段截断（_clamp_std_code_digits）。
"""


import re
from typing import Any

from app.search.av.parse import _western_yyyy
from app.search.av.prefixes import (
    DATE6_PREFIX_LABEL,
    _china_prefix_set,
    _escape_re,
    _prefix_key,
    _western_key,
    resolve_maker_shape,
)


def _extract_fc2(upper: str, want_ppv: bool, out: set[str]) -> None:
    if want_ppv:
        for m in re.finditer(r"FC2[-_\s]?PPV[-_\s]?(\d{5,10})", upper, re.I):
            out.add(f"FC2-PPV-{m.group(1)}")
        return
    if re.search(r"FC2[-_\s]?PPV", upper, re.I):
        return
    for m in re.finditer(
        r"(?:^|[^A-Z0-9])FC2(?![-_\s]?PPV)[-_\s]?(\d{5,10})(?![A-Z0-9])",
        upper,
        re.I,
    ):
        out.add(f"FC2-{m.group(1)}")


def _extract_date6(upper: str, prefix: str, out: set[str]) -> None:
    label = (
        DATE6_PREFIX_LABEL.get(_prefix_key(prefix))
        or DATE6_PREFIX_LABEL.get(_western_key(prefix))
        or _prefix_key(prefix)
    )
    if (
        _prefix_key(prefix) in upper
        or _western_key(prefix) in upper
        or label in upper
    ):
        for m in re.finditer(
            r"(?:^|[^A-Z0-9])(\d{6})[-_](\d{2,3})(?![A-Z0-9])", upper, re.I
        ):
            out.add(f"{label}-{m.group(1)}-{m.group(2)}")
    esc = _escape_re(_prefix_key(prefix))
    for m in re.finditer(
        rf"{esc}[-_\s]?(\d{{6}})[-_](\d{{2,3}})(?![A-Z0-9])", upper, re.I
    ):
        out.add(f"{label}-{m.group(1)}-{m.group(2)}")


def _extract_alnum_id(upper: str, prefix: str, out: set[str]) -> None:
    p = _prefix_key(prefix)
    esc = _escape_re(p)
    for m in re.finditer(
        rf"{esc}[-_\s]?([A-Z]{{0,12}}\d[A-Z0-9]{{0,20}})(?![A-Z0-9])",
        upper,
        re.I,
    ):
        ident = m.group(1).upper()
        if not re.search(r"\d", ident) or len(ident) < 3:
            continue
        out.add(f"{p}-{ident}")


def _extract_western(upper: str, prefix: str, out: set[str]) -> None:
    """欧美抽码：规范键 PREFIX.YYYY.MM.DD / PREFIX.YYYY.MM / PREFIX.YYYY。"""
    key = _western_key(prefix)
    esc = _escape_re(key)
    # 1) KEY.YYYY.MM.DD
    for m in re.finditer(
        rf"{esc}[._\-\s]?(19\d{{2}}|20\d{{2}})[._\-](\d{{2}})[._\-](\d{{2}})(?!\d)",
        upper,
        re.I,
    ):
        out.add(f"{key}.{m.group(1)}.{m.group(2)}.{m.group(3)}")
    # 2) KEY.YY.MM.DD → KEY.20YY.MM.DD
    for m in re.finditer(
        rf"{esc}[._\-\s]?(\d{{2}})[._\-](\d{{2}})[._\-](\d{{2}})(?!\d)",
        upper,
        re.I,
    ):
        if m.group(1) in ("19", "20"):
            continue
        yyyy = _western_yyyy(m.group(1))
        out.add(f"{key}.{yyyy}.{m.group(2)}.{m.group(3)}")
    # 3) KEY.YYYY.MM 合集月（后面不能再跟 .日）
    for m in re.finditer(
        rf"{esc}[._\-\s]?(19\d{{2}}|20\d{{2}})[._\-](\d{{2}})(?![._\-]?\d)",
        upper,
        re.I,
    ):
        out.add(f"{key}.{m.group(1)}.{m.group(2)}")
    # 4) KEY.YYYY 纯年（后面不能再跟 .月）
    for m in re.finditer(
        rf"{esc}[._\-\s]?(19\d{{2}}|20\d{{2}})(?![._\-]?\d)",
        upper,
        re.I,
    ):
        out.add(f"{key}.{m.group(1)}")
    # 5) 六位紧凑日戳 KEY.260513 → KEY.2026.05.13（不要裸 2160 等伪集数）
    for m in re.finditer(
        rf"{esc}[._\-\s]?(\d{{6}})(?![A-Z0-9])", upper, re.I
    ):
        num = m.group(1)
        if re.fullmatch(r"19\d{2}|20\d{2}", num[:4]) and int(num[4:6]) <= 12:
            # 误把 YYYYMM 当 YYMMDD 的少见情况：若前四位是年且后两位像月，跳过交给上面
            pass
        yyyy = _western_yyyy(num[:2])
        mo, d = num[2:4], num[4:6]
        if 1 <= int(mo) <= 12 and 1 <= int(d) <= 31:
            out.add(f"{key}.{yyyy}.{mo}.{d}")


def _extract_std(upper: str, prefix: str, out: set[str]) -> None:
    p = _prefix_key(prefix)
    if p in {"GACHI", "GACHINCO"}:
        for m in re.finditer(r"GACHI(?:NCO)?[-_\s]?GACHI?(\d{3,5})", upper, re.I):
            out.add(f"GACHI-{m.group(1)}")
        if out:
            return
    esc = _escape_re(p)
    china = p in _china_prefix_set()
    if china:
        # 按帖题原样保留位数：JD-150 / MDSR-0002 / YCM086，不强制四位
        for m in re.finditer(
            rf"(?:^|[^A-Z0-9\-_])(?:\d{{2,3}})?{esc}[-_\s]?(\d{{1,6}})"
            rf"(?:[-_\s]?(?:EP|E)[-_\s]?\d{{1,2}}|[-_]\d{{1,2}})?(?![A-Z0-9])",
            upper,
            re.I,
        ):
            raw_num = m.group(1)
            if not re.fullmatch(r"\d{1,6}", raw_num):
                continue
            n = int(raw_num)
            if n <= 0:
                continue
            out.add(f"{p}-{raw_num}")
        return
    # 数字与可选分集后缀分开：避免 EBWH-061100cm 把 CM 吃进番号
    # 左侧边界不含 -/_ ：避免 jukujo-club-983 → CLUB-983
    for m in re.finditer(
        rf"(?:^|[^A-Z0-9\-_])(?:\d{{2,3}})?{esc}[-_\s]?(\d{{2,6}})([A-Z]{{1,2}})?(?![A-Z0-9])",
        upper,
        re.I,
    ):
        raw_num = m.group(1)
        suf = str(m.group(2) or "").upper()
        unit = bool(suf and _CODE_UNIT_SUFFIX_RE.fullmatch(suf))
        # 单位后缀（cm）并入 following，便于 061100+CM → 截成 061
        following = ((suf if unit else "") + upper[m.end() : m.end() + 12])
        # Start 720p / 1080p（含抽成 START-720P）
        if int(raw_num) in {360, 480, 720, 1080, 1440, 2160} and (
            re.match(r"^P(?:[^A-Z]|$)", following, re.I)
            or suf.upper() == "P"
        ):
            continue
        clamped = _clamp_std_code_digits(p, raw_num, following=following)
        if not clamped:
            continue
        # 合法分集后缀（如 ABC-123AB）保留；单位后缀丢掉
        if suf and not unit and len(clamped) == len(raw_num):
            out.add(f"{p}-{clamped}{suf}")
        else:
            out.add(f"{p}-{clamped}")


_CODE_UNIT_SUFFIX_RE = re.compile(r"^(CM|MM|KG|MIN|FPS|MS)$", re.I)
_MEASURE_AFTER_CODE_RE = re.compile(
    r"^(?:\d{0,4})?(?:CM|MM|KG|MIN|FPS|秒|分|歳|才|P\b|K\b)",
    re.I,
)


def _pad_for_extract(prefix: str, profile: dict[str, Any] | None = None) -> int:
    if profile and int(profile.get("pad") or 0) > 0:
        return max(1, min(8, int(profile["pad"])))
    try:
        from app.prefix.code_read import resolve_code_read

        pad = int(resolve_code_read(prefix).get("pad") or 0)
        if pad > 0:
            return max(1, min(8, pad))
    except Exception:
        pass
    try:
        from app.prefix.ranges import get_range

        r = get_range(prefix)
        if r and int(r.get("pad") or 0) > 0:
            return max(1, min(8, int(r["pad"])))
    except Exception:
        pass
    return 3


def _clamp_std_code_digits(
    prefix: str,
    raw_num: str,
    *,
    following: str = "",
    profile: dict[str, Any] | None = None,
) -> str | None:
    """按前缀 code_read 处理数字段。

    - DMM 形前导零补位：club00127 → 127（绝不能左截成 001）
    - 粘连度量：EBWH-061100cm → 061（仅 measure_glue 开启时）
    """
    if not re.fullmatch(r"\d{2,6}", raw_num):
        return None
    n = int(raw_num)
    if n <= 0:
        return None
    prof = profile
    if prof is None:
        try:
            from app.prefix.code_read import resolve_code_read

            prof = resolve_code_read(prefix)
        except Exception:
            prof = {
                "pad": 3,
                "cid_width": 5,
                "leading_zero": "int",
                "measure_glue": True,
            }
    pad = _pad_for_extract(prefix, prof)
    cid_width = int(prof.get("cid_width") or 0)
    leading_zero = str(prof.get("leading_zero") or "int")
    measure_glue = bool(prof.get("measure_glue"))

    # 前导零补位（常见 5 位 cid）：优先还原整数值，除非尾部像身高/体重
    zero_pad_hit = raw_num.startswith("0") and (
        len(raw_num) > pad or (cid_width > 0 and len(raw_num) == cid_width)
    )
    if zero_pad_hit:
        head, tail = raw_num[:pad], raw_num[pad:]
        follow = f"{tail}{following or ''}"
        if measure_glue and _MEASURE_AFTER_CODE_RE.match(follow):
            return head
        if leading_zero == "head":
            return head
        return str(n)

    if len(raw_num) <= pad:
        return raw_num

    head, tail = raw_num[:pad], raw_num[pad:]
    follow = f"{tail}{following or ''}"
    if measure_glue and _MEASURE_AFTER_CODE_RE.match(follow):
        return head
    # 无前导零的超长粘连（pad+2 及以上）：多半把 100cm 等粘进数字
    if measure_glue and len(raw_num) >= pad + 2:
        try:
            from app.prefix.ranges import get_range

            r = get_range(prefix)
            to = int((r or {}).get("to") or 0)
            max_serial = prof.get("max_serial")
            if max_serial is not None:
                try:
                    to = int(max_serial) if to <= 0 else min(to, int(max_serial))
                except (TypeError, ValueError):
                    pass
            # 仅当「头段」本身像合法流水时才左截；否则保留原值交给离群过滤
            if to <= 0 or int(head) <= to:
                return head
        except Exception:
            return head
    return raw_num


def extract_maker_codes(text: str, prefix: str) -> list[str]:
    """Extract canonical codes for a maker prefix from filename/title blob."""
    src = str(text or "")
    p = str(prefix or "").strip()
    if not src or not p:
        return []
    upper = src.upper()
    shape = resolve_maker_shape(p)
    out: set[str] = set()
    if shape == "fc2":
        _extract_fc2(upper, False, out)
    elif shape == "fc2ppv":
        _extract_fc2(upper, True, out)
    elif shape == "date6":
        _extract_date6(upper, p, out)
    elif shape == "alnum_id":
        _extract_alnum_id(upper, p, out)
    elif shape in {"western_date", "western_ep"}:
        _extract_western(upper, p, out)
    else:
        _extract_std(upper, p, out)
    return list(out)
