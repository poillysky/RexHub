"""末尾女优名剥除：简繁/新旧异体字归一后按分隔符剥尾。"""


import re
import unicodedata
from functools import lru_cache
from typing import Iterable

# 女优名常见异体字（帖题简繁/新旧字与库内【出演女优】不一致时仍剥尾）
_ACTOR_VARIANT_PAIRS: tuple[tuple[str, str], ...] = (
    ("薫", "薰"),
    ("薰", "薫"),
    ("熏", "薰"),
    ("恵", "惠"),
    ("惠", "恵"),
    ("凪", "澪"),
    ("澪", "凪"),
    ("咲", "笑"),
    ("笑", "咲"),
)
_TRAILING_CJK_RE = re.compile(r"([\u4e00-\u9fff\u3040-\u30ff]{2,8})$")


def _actor_strip_variants(name: str) -> set[str]:
    raw = str(name or "").strip()
    if not raw:
        return set()
    out = {raw, unicodedata.normalize("NFKC", raw)}
    pool = list(out)
    for base in pool:
        for a, b in _ACTOR_VARIANT_PAIRS:
            if a in base:
                out.add(base.replace(a, b))
            if b in base:
                out.add(base.replace(b, a))
    return {x for x in out if len(x) >= 2}


def _actor_names_match(a: str, b: str) -> bool:
    aa = str(a or "").strip()
    bb = str(b or "").strip()
    if not aa or not bb:
        return False
    if aa == bb:
        return True
    va = _actor_strip_variants(aa)
    vb = _actor_strip_variants(bb)
    return bool(va & vb)


@lru_cache(maxsize=4096)
def _actor_trailing_re(name: str) -> re.Pattern[str]:
    esc = re.escape(name)
    return re.compile(rf"(?:[\s　]*[、,，/｜|。．.·・][\s　]*)?{esc}\s*$")


def _strip_trailing_actor_name(t: str, actors: Iterable[str]) -> str:
    names = [str(a).strip() for a in actors if str(a or "").strip()]
    if not t or not names:
        return t
    all_variants: set[str] = set()
    for name in names:
        all_variants |= _actor_strip_variants(name)
    ordered = sorted(all_variants, key=len, reverse=True)
    for _ in range(4):
        changed = False
        for name in ordered:
            if len(name) < 2:
                continue
            nxt = _actor_trailing_re(name).sub("", t).strip()
            if nxt != t and len(nxt) >= 4:
                t = nxt
                changed = True
        if not changed:
            break
    tail = _TRAILING_CJK_RE.search(t)
    if tail and any(_actor_names_match(tail.group(1), n) for n in names):
        t = t[: tail.start()].strip()
    return t
