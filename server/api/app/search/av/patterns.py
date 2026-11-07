"""查询构建：番号 ILIKE 模式 / 边界正则 / SQL 续写拒绝 / 行过滤。

基于解析结果展开前缀别名与补零变体，供 PostgreSQL ILIKE / ~* 使用。
"""


import re

from app.search.av.parse import maker_code_parts, normalize_maker_code, parse_maker_code
from app.search.av.prefixes import (
    _escape_re,
    _prefix_key,
    prefix_aliases,
    prefixes_equivalent,
)
from app.search.constants import escape_ilike


def _parts_for_patterns(canonical: str, shape: str) -> list[str]:
    if shape == "fc2ppv":
        m = re.fullmatch(r"FC2-PPV-(\d+)", canonical, re.I)
        if m:
            return ["FC2", "PPV", m.group(1)]
    if shape == "fc2":
        m = re.fullmatch(r"FC2-(\d+)", canonical, re.I)
        if m:
            return ["FC2", m.group(1)]
    if shape == "date6":
        m = re.fullmatch(r"([A-Z0-9]+)-(\d{6})-(\d{2,3})", canonical, re.I)
        if m:
            return [m.group(1), m.group(2), m.group(3)]
    if shape == "fixed_std":
        # TOKYOHOT-N1234 / MESUBUTA-123456-001
        m = re.fullmatch(r"TOKYOHOT[-_.\s]?N?(\d{3,5})", canonical, re.I)
        if m:
            return ["TOKYOHOT", f"N{m.group(1)}"]
        m = re.fullmatch(r"MESUBUTA[-_.\s]?(\d{6})[-_.\s](\d{2,3})", canonical, re.I)
        if m:
            return ["MESUBUTA", m.group(1), m.group(2)]
    if shape == "western_date":
        m = re.fullmatch(
            r"([A-Z]{2,24})[._\-](19\d{2}|20\d{2})[._\-](\d{2})[._\-](\d{2})",
            canonical,
            re.I,
        )
        if m:
            return [
                m.group(1).upper(),
                m.group(2),
                m.group(3),
                m.group(4),
            ]
        m = re.fullmatch(
            r"([A-Z]{2,24})[._\-](\d{2})[._\-](\d{2})[._\-](\d{2})",
            canonical,
            re.I,
        )
        if m:
            return [
                m.group(1).upper(),
                f"{m.group(2)}{m.group(3)}{m.group(4)}",
            ]
        m = re.fullmatch(r"([A-Z]{2,24})[-_.](\d{6})", canonical, re.I)
        if m:
            return [m.group(1).upper(), m.group(2)]
    if shape == "western_ym":
        m = re.fullmatch(
            r"([A-Z]{2,24})[._\-](19\d{2}|20\d{2})[._\-](\d{2})",
            canonical,
            re.I,
        )
        if m:
            return [m.group(1).upper(), m.group(2), m.group(3)]
    if shape == "western_year":
        m = re.fullmatch(
            r"([A-Z]{2,24})[._\-](19\d{2}|20\d{2})",
            canonical,
            re.I,
        )
        if m:
            return [m.group(1).upper(), m.group(2)]
    return maker_code_parts(canonical)


def _search_prefix_heads(keyword: str, head: str) -> list[str]:
    """精确搜索用的前缀写法：canonical 别名 + 素人数字头。"""
    heads: set[str] = set()
    if head:
        heads.add(_prefix_key(head))
        heads |= set(prefix_aliases(head))
    raw = normalize_maker_code(keyword).upper().replace("_", "-")
    m = re.match(r"^(\d{2,3}[A-Z]{2,20})", raw)
    if m:
        hub = m.group(1)
        heads.add(hub)
        letter = re.sub(r"^\d+", "", hub)
        if letter:
            heads.add(letter)
            heads |= set(prefix_aliases(letter))
    # 去空、去纯重复 compact
    out = [h for h in heads if h]
    out.sort(key=lambda s: (-len(s), s))
    return out


def _fc2_id_digits(parts: list[str], shape: str) -> str:
    """FC2 / FC2-PPV parts → 数字 id。"""
    if shape == "fc2ppv" and len(parts) >= 3 and str(parts[-1]).isdigit():
        return str(parts[-1])
    if shape == "fc2" and len(parts) >= 2 and str(parts[-1]).isdigit():
        return str(parts[-1])
    if parts and str(parts[-1]).isdigit():
        return str(parts[-1])
    return ""


def _part_lists_for_search(keyword: str, parts: list[str], shape: str) -> list[list[str]]:
    """同一番号的多套 parts（前缀别名 / TOKYOHOT 有无 N / FC2↔PPV）。"""
    if not parts:
        return []

    # 色花堂帖题常混写 FC2-123 与 FC2-PPV-123：搜任一都要能命中另一
    if shape in {"fc2", "fc2ppv"}:
        digits = _fc2_id_digits(parts, shape)
        if digits:
            variants = (
                [["FC2", digits], ["FC2", "PPV", digits]]
                if shape == "fc2"
                else [["FC2", "PPV", digits], ["FC2", digits]]
            )
            out: list[list[str]] = []
            seen: set[tuple[str, ...]] = set()
            for row in variants:
                key = tuple(row)
                if key in seen:
                    continue
                seen.add(key)
                out.append(row)
            return out

    head, *tail = parts
    heads = _search_prefix_heads(keyword, head)
    if not heads:
        heads = [head]

    bodies: list[list[str]] = [tail]
    # TOKYOHOT-N1234 ↔ TOKYOHOT-1234
    if shape == "fixed_std" and prefixes_equivalent(head, "TOKYOHOT") and tail:
        dig = re.sub(r"^[Nn]", "", str(tail[0]))
        if dig.isdigit():
            bodies = [[f"N{dig}"], [dig]]

    out = []
    seen = set()
    for h in heads:
        for body in bodies:
            row = [h, *body]
            key = tuple(row)
            if key in seen:
                continue
            seen.add(key)
            out.append(row)
    return out or [parts]


def _ilike_patterns_for_parts(parts: list[str], shape: str) -> list[str]:
    esc = [escape_ilike(p) for p in parts]
    if not esc:
        return []
    if len(esc) == 1:
        return [f"%{esc[0]}%"]
    out = [
        f"%{'-'.join(esc)}%",
        f"%{''.join(esc)}%",
        f"%{'_'.join(esc)}%",
        f"%{' '.join(esc)}%",
    ]
    if len(esc) >= 3:
        head = "".join(esc[:-1])
        num = esc[-1]
        out.extend([f"%{head}_{num}%", f"%{head}-{num}%"])
    if shape == "std" and len(parts) == 2 and str(parts[1]).isdigit():
        pref, num = parts[0], parts[1]
        bare = str(int(num))
        variants = {num, bare}
        for w in (2, 3, 4, 5, 6):
            if len(bare) <= w <= 6:
                variants.add(bare.zfill(w))
        ep = escape_ilike(pref)
        for v in variants:
            ev = escape_ilike(v)
            out.extend(
                [
                    f"%{ep}-{ev}%",
                    f"%{ep}{ev}%",
                    f"%{ep}_{ev}%",
                    f"%{ep} {ev}%",
                ]
            )
    if shape == "western_date" and len(parts) == 2 and len(parts[1]) == 6:
        y, mo, d = esc[1][:2], esc[1][2:4], esc[1][4:6]
        studio = esc[0]
        out.extend(
            [
                f"%{studio}.{y}.{mo}.{d}%",
                f"%{studio}_{y}.{mo}.{d}%",
                f"%{studio}-{y}-{mo}-{d}%",
            ]
        )
    if shape == "western_date" and len(parts) == 4:
        studio, yyyy, mo, d = esc[0], esc[1], esc[2], esc[3]
        out.extend(
            [
                f"%{studio}.{yyyy}.{mo}.{d}%",
                f"%{studio}_{yyyy}.{mo}.{d}%",
                f"%{studio}-{yyyy}-{mo}-{d}%",
            ]
        )
    if shape in {"western_ym", "western_year", "western_ep"} and len(esc) >= 2:
        out.append(f"%{'.'.join(esc)}%")
        out.append(f"%{esc[0]}_{'.'.join(esc[1:])}%")
    if shape == "date6" and len(parts) == 3:
        out.extend([f"%{esc[1]}-{esc[2]}%", f"%{esc[1]}_{esc[2]}%"])
    if shape == "fixed_std" and len(parts) == 2 and prefixes_equivalent(parts[0], "TOKYOHOT"):
        # Tokyo Hot / TOKYO-HOT 空格写法
        dig = re.sub(r"^[Nn]", "", parts[1])
        out.extend(
            [
                f"%TOKYO HOT%{escape_ilike(dig)}%",
                f"%TOKYO-HOT-{escape_ilike(dig)}%",
                f"%TOKYO-HOT-N{escape_ilike(dig)}%",
            ]
        )
    return out


def build_av_code_ilike_patterns(canonical: str) -> list[str]:
    """ILIKE patterns with ESCAPE '\\': literals escaped; bare `_` = any single sep.

    规范键会展开前缀别名（1PON↔1PONDO、GACHI↔GACHINCO）及 TOKYOHOT 有无 N。
    """
    parsed = parse_maker_code(canonical)
    shape = parsed.shape if parsed else "std"
    # 优先用解析后的 canonical parts（date6/fixed_std 更稳）
    base_src = parsed.canonical if parsed and parsed.canonical else canonical
    parts = _parts_for_patterns(base_src, shape)
    if not parts:
        u = normalize_maker_code(canonical).upper()
        return [f"%{escape_ilike(u)}%"] if u else []

    out: list[str] = []
    for plist in _part_lists_for_search(canonical, parts, shape):
        out.extend(_ilike_patterns_for_parts(plist, shape))

    seen: set[str] = set()
    uniq: list[str] = []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def _boundary_tail(parts: list[str]) -> str:
    last = parts[-1] if parts else ""
    return r"(?![A-Za-z0-9])" if re.search(r"[A-Z]", last, re.I) else r"(?![0-9])"


def build_av_code_boundary_re(canonical: str) -> re.Pattern[str]:
    parsed = parse_maker_code(canonical)
    shape = parsed.shape if parsed else "std"
    base_src = parsed.canonical if parsed and parsed.canonical else canonical
    parts = _parts_for_patterns(base_src, shape)
    if not parts:
        return re.compile(r"(?!)")

    alts: list[str] = []
    for plist in _part_lists_for_search(canonical, parts, shape):
        compact = "[-_.\\s]?".join(_escape_re(p) for p in plist)
        alts.append(compact)
        # 标准番号：前导零可选
        if shape == "std" and len(plist) == 2 and re.fullmatch(r"\d+", plist[1]):
            pref = _escape_re(plist[0])
            bare = str(int(plist[1]))
            alts.append(rf"{pref}[-_.\s]?0*{_escape_re(bare)}")
        # 欧美日戳
        if shape == "western_date" and len(plist) == 2 and re.fullmatch(r"\d{6}", plist[1]):
            y, mo, d = plist[1][:2], plist[1][2:4], plist[1][4:6]
            studio = _escape_re(plist[0])
            alts.append(
                rf"{studio}[._\-\s]?{_escape_re(y)}[._\-]{_escape_re(mo)}[._\-]{_escape_re(d)}"
            )
        if shape == "western_date" and len(plist) == 4:
            studio, yyyy, mo, d = (_escape_re(x) for x in plist)
            if re.fullmatch(r"20\d{2}", plist[1]):
                yy = _escape_re(plist[1][2:])
                alts.append(rf"{studio}[._\-\s]?{yy}[._\-]{mo}[._\-]{d}")

    # TOKYOHOT：TOKYO HOT / 可选 N
    if shape == "fixed_std" and prefixes_equivalent(parts[0], "TOKYOHOT"):
        dig = re.sub(r"^[Nn]", "", parts[1] if len(parts) > 1 else "")
        if dig.isdigit():
            alts.append(
                rf"(?:TOKYO[-_\s]?HOT|TOKYOHOT)[-_.\s]?N?{_escape_re(dig)}"
            )

    # dedupe alts
    seen_a: set[str] = set()
    uniq_alts: list[str] = []
    for a in alts:
        if a not in seen_a:
            seen_a.add(a)
            uniq_alts.append(a)
    if not uniq_alts:
        return re.compile(r"(?!)")

    body = "(?:" + "|".join(uniq_alts) + ")"
    cid = r"(?:\d{2,3})?" if shape == "std" else ""
    tail = _boundary_tail(parts)
    if shape == "western_date" and len(uniq_alts) > 1:
        tail = r"(?![0-9])"
    if shape == "fixed_std" and prefixes_equivalent(parts[0], "TOKYOHOT"):
        tail = r"(?![0-9])"
    return re.compile(
        rf"(^|[^A-Za-z0-9]){cid}{body}{tail}",
        re.I,
    )


def build_av_code_continuation_reject(canonical: str) -> str | None:
    """SQL !~* 拒绝续写：字母尾 C0930-HITOZUMA0759；数字尾 SSIS-0012。"""
    parsed = parse_maker_code(canonical)
    shape = parsed.shape if parsed else "std"
    base_src = parsed.canonical if parsed and parsed.canonical else canonical
    parts = _parts_for_patterns(base_src, shape)
    if not parts:
        return None
    last = parts[-1]
    # 多前缀别名：(1PON|1PONDO)[-_.[:space:]]?…
    heads = _search_prefix_heads(canonical, parts[0])
    if len(heads) > 1:
        pref = "(?:" + "|".join(_escape_re(h) for h in heads) + ")"
    else:
        pref = _escape_re(parts[0])
    rest = parts[1:]
    if rest:
        body = pref + "[-_.[:space:]]?" + "[-_.[:space:]]?".join(
            _escape_re(p) for p in rest
        )
    else:
        body = pref
    if shape == "fixed_std" and prefixes_equivalent(parts[0], "TOKYOHOT"):
        dig = re.sub(r"^[Nn]", "", last)
        if dig.isdigit():
            body = (
                r"(?:TOKYO[-_[:space:]]?HOT|TOKYOHOT)[-_.[:space:]]?N?"
                + _escape_re(dig)
            )
            return f"{body}\\d"
    if re.search(r"[A-Z]", last, re.I):
        return f"{body}[A-Za-z0-9]"
    if re.fullmatch(r"\d+", last) or (
        shape == "fixed_std" and re.fullmatch(r"N?\d+", last, re.I)
    ):
        return f"{body}\\d"
    return None
