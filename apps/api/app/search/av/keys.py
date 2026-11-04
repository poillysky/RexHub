"""番号统一键与排序键：std_code_key 规范化、code_sort_key 自然排序。"""


import re

from app.search.av.parse import parse_maker_code


def std_code_key(code: str, *, pad: int = 3) -> str:
    """统一番号键：短号按 pad 补零；已带前导零的保留源串位数。

    例：SONE-15 + pad3 → SONE-015；JD-150 + pad3 → JD-150；MDSR-0002 保持四位。
    分集 / -C / -CH / 分盘字母等尾缀不进键（IPZZ-599C → IPZZ-599）。
    欧美为点分 YYYY.MM.DD。
    """
    raw = str(code or "").strip().upper().replace("_", "-")
    raw = re.sub(r"(?<=\d)-(?:EP|E)?\d{1,2}$", "", raw, flags=re.I)
    try:
        parsed = parse_maker_code(raw)
        if parsed and parsed.shape in {
            "western_date",
            "western_ym",
            "western_year",
            "western_ep",
            "fc2",
            "fc2ppv",
            "alnum_id",
            "date6",
            "fixed_std",
        }:
            return parsed.canonical
        # std：用解析后的 PREFIX-数字（丢掉破解/分盘字母尾缀）
        if parsed and parsed.shape == "std" and parsed.canonical:
            raw = parsed.canonical
    except Exception:
        pass
    m = re.fullmatch(r"([A-Z0-9]+)-(\d+)", raw)
    if not m:
        return raw
    prefix, num_s = m.group(1), m.group(2)
    n = int(num_s)
    # pad<=0：完全保留源串位数（国产按帖题原样）
    if int(pad or 0) <= 0:
        width = max(len(str(n)), len(num_s))
    elif len(num_s) > len(str(n)):
        # 源串已有前导零（MDSR-0002）→ 保留
        width = max(len(num_s), len(str(n)))
    else:
        # 短号按 pad 补（SONE-15 → SONE-015）
        width = max(1, int(pad or 3), len(str(n)))
    return f"{prefix}-{n:0{width}d}"


def code_sort_key(code: str) -> tuple[int, int, str]:
    parts = re.findall(r"\d+", str(code or "").upper())
    a = int(parts[0]) if parts else 0
    b = int(parts[1]) if len(parts) > 1 else 0
    return a, b, str(code or "").upper()
