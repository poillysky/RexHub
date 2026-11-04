"""outbound_http 子模块：风控拦截页 / R18 软门 HTML 判定与 access 模式归一。"""

import re

_BLOCKED_RE = re.compile(
    r"Just a moment|cf-browser-verification|Attention Required|"
    r"Edge IP Restricted|Cloudflare has blocked|403 ERROR|"
    r"The request could not be satisfied|Access Denied|"
    r"Please enable cookies|banned your access|禁止了你的訪問|異常行為|"
    r"Web server is returning an unknown error|520:\s*Web server",
    re.I,
)
# 色花堂等 Discuz 名言/R18 拦截页：var safeid=… → cookie `_safe`
_SAFEID_RE = re.compile(r"safeid\s*=\s*['\"]([^'\"]+)['\"]", re.I)


def looks_blocked_html(html: str | None) -> bool:
    s = str(html or "")
    if len(s) < 400:
        return True
    return bool(_BLOCKED_RE.search(s[:4000]))


def is_r18_safe_shell(html: str | None) -> bool:
    """色花堂名言/R18 软门（短页 + safeid / static/safe）。"""
    s = str(html or "")
    if not s or len(s) >= 12_000:
        return False
    lowered = s.lower()
    return "var safeid" in s or "static/safe/" in lowered


def extract_safeid(html: str | None) -> str:
    m = _SAFEID_RE.search(html or "")
    return (m.group(1).strip() if m else "") or ""


def normalize_access(access: str | None) -> str:
    a = str(access or "").strip().lower()
    if a == "proxy_flare":
        return "proxy_flare"
    # 仅 curl/代理，永不 Flare（javbus 等）
    if a in {"proxy_only", "proxy_curl", "curl", "direct"}:
        return "proxy_only"
    return "proxy_adaptive"
