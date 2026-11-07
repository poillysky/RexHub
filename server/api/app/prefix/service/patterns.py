"""前缀分类与 LIKE pattern 构建。

FC2 / 欧美 Studio / 普通字母品番走不同 ILIKE pattern 集，并提供排除
pattern（防串图、防串前缀）；有码风格前缀判定也归此。
"""

import re

from app.search.av import is_western_studio_prefix
from app.search.constants import escape_ilike


def _is_fc2_prefix(prefix: str) -> bool:
    p = str(prefix or "").strip().upper()
    return p in {"FC2", "FC2PPV"}


def prefix_like_patterns(prefix: str) -> list[str]:
    raw = str(prefix or "").strip()
    p_upper = raw.upper()
    if not raw:
        return []
    if p_upper == "FC2PPV":
        return [
            "FC2PPV%",
            "%FC2PPV%",
            "%FC2-PPV%",
            "%FC2 PPV%",
            "FC2-PPV%",
            "FC2 PPV%",
        ]
    if p_upper == "FC2":
        return ["FC2-%", "%FC2-%", "FC2 %", "%FC2 %"]
    esc = escape_ilike(raw)
    if is_western_studio_prefix(raw):
        # 欧美常见 Studio.yy.mm.dd / Studio-yyyy…；短站名禁止裸 %RK%，否则全表扫超时。
        out = [
            f"%{esc}.%",
            f"%{esc}-%",
            f"%{esc}_%",
            f"{esc}.%",
            f"{esc}-%",
            f"{esc}_%",
        ]
        if len(raw) >= 5:
            out.extend([f"%{esc} %", f"{esc} %", f"%{esc}%"])
        return out
    return [f"{esc}-%", f"%{esc}-%"]


def prefix_exclude_like_patterns(prefix: str) -> list[str]:
    p = str(prefix or "").strip().upper()
    if p == "FC2":
        return [
            "%FC2PPV%",
            "FC2PPV%",
            "%FC2-PPV%",
            "FC2-PPV%",
            "%FC2 PPV%",
            "FC2 PPV%",
        ]
    if p == "BLACKED":
        return ["%BlackedRaw%", "%BLACKEDRAW%", "%blackedraw%"]
    return []


def _is_japan_censored_style_prefix(prefix: str) -> bool:
    """字母品番前缀（非 FC2 / 欧美站名）按有码原则挑封面。"""
    raw = str(prefix or "").strip()
    if not raw or _is_fc2_prefix(raw) or is_western_studio_prefix(raw):
        return False
    return bool(re.fullmatch(r"[A-Za-z][A-Za-z0-9]{1,11}", raw))
