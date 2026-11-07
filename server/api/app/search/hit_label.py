"""搜索命中项的展示标题：影片名优先，去掉 Discuz 壳。"""


import re
from urllib.parse import unquote

from app.search.pack_bleed import first_maker_code_in, get_description_field
from app.search.forum_title import clean_forum_zh_title

_EXT_RE = re.compile(r"\.(mp4|mkv|avi|wmv|iso|ts|m2ts|mov|flv|rmvb)$", re.I)
_WS_RE = re.compile(r"\s+")
_DISCUZ_CHROME_RE = re.compile(
    r"Powered by Discuz|98堂\s*[\[【]?原?色花堂",
    re.I,
)


def normalize_filename(name: str | None) -> str:
    s = unquote(str(name or "").strip())
    s = _EXT_RE.sub("", s)
    return _WS_RE.sub(" ", s).strip()


def _fold(s: str) -> str:
    return re.sub(r"[\s_\-]+", "", (s or "")).casefold()


def _clip(s: str, n: int = 120) -> str:
    t = _WS_RE.sub(" ", (s or "").strip())
    return t if len(t) <= n else t[: n - 1] + "…"


def _title_code(*parts: str) -> str:
    for p in parts:
        code = first_maker_code_in(p) or ""
        if code:
            return code
    return ""


def _clean_title(raw: str, code: str) -> str:
    t = str(raw or "").strip()
    if not t:
        return ""
    if _DISCUZ_CHROME_RE.search(t):
        return ""
    cleaned = clean_forum_zh_title(t, code, allow_weak=True)
    if cleaned:
        return cleaned
    return _clip(t, 80)


def _film_name(description: str | None) -> str:
    return str(get_description_field(description, "影片名称") or "").strip()


def _resource_name(description: str | None) -> str:
    return str(get_description_field(description, "资源名称") or "").strip()


def display_hit_label(
    *,
    title: str | None = None,
    description: str | None = None,
    filename: str | None = None,
) -> str:
    """列表/对话展示用短标题：影片名优先，去掉 Discuz 壳。"""
    film = _film_name(description)
    resource = _resource_name(description)
    file_stem = normalize_filename(filename)
    code = _title_code(file_stem, film, resource, str(title or ""))
    heading = _clean_title(str(title or ""), code)
    label = film or heading or resource or file_stem or code
    if code and label and _fold(code) not in _fold(label):
        label = f"{code} {label}"
    return _clip(label, 72) or "资源"
