"""假壳判定：热路径廉价判断（is_fake_forum_title_fast）与全量判断。


索引写入时应视为空标题，宁缺毋假。
"""


import re

from app.search.forum_title.codes import _needle_ext_re, _strip_code_tokens
from app.search.forum_title.patterns import (
    _BARE_EDGE_STRIP,
    _FORUM_GENERIC_ONLY_RE,
    _FORUM_META_ZH_JUNK_RE,
    _FORUM_PACK_NOISE_RE,
    _META_SHELL_FAKE_LEN,
    _WS_NICK_RE,
    _WS_RE,
)
from app.search.forum_title.shells import _is_ai_resolution_shell

_COMPACT_SEP_RE = re.compile(r"[\s_\-]+")
_SHORT_KANA_FULL_RE = re.compile(
    r"[\u3040-\u30ff\u31f0-\u31ffー·・\s　]{1,10}"
)
_CODE_MEDIA_ONLY_RE = re.compile(
    r"[A-Z0-9]{2,12}[\s\-_]?0*\d{1,6}(?:\s*(?:MP4|MKV|AVI|FHD|HD|4K|UHD))?",
    re.I,
)
_CLIP_SHELL_RE = re.compile(
    r"(?:^|[\s\-–—])(?:4K(?:60)?\s*)?修复片段|修復片段|剪辑片段|合集片段|"
    r"C-4K修复片段|片段\s*\d+\s*$",
    re.I,
)
_CLIP_ONLY_RE = re.compile(r"剪辑片段|修复片段|修復片段", re.I)
_PACK_EXTRA_RE = re.compile(
    r"橙子整理|含单体|DMM原档|截止\s*$|合集更新至|作品合集|系列合集|"
    r"-999汇总|汇总【",
    re.I,
)
_TB_PACK_RE = re.compile(
    r"\d+(?:\.\d+)?\s*TB\s*/|\d{2,}\s*V\s*/\s*\d|"
    r"【\s*\d+(?:\.\d+)?\s*TB",
    re.I,
)
_MAGNET_SHELL_RE = re.compile(
    r"磁力链接无资源|补个有资源的链接|论坛上有另一个帖子的磁力|"
    r"只有磁力|无种子|死链",
    re.I,
)
_MAGNET_CODE_ONLY_RE = re.compile(
    r"(?:【?\s*(?:磁力|磁链|BT)[^】\]]{0,12}】?\s*)+"
    r"[A-Z0-9][A-Z0-9\-_ ]{2,20}"
    r"(?:\s*【?\s*(?:FHD|HD|4K|MP4)[^】\]]{0,8}】?)?",
    re.I,
)
_MEDIA_ONLY_RE = re.compile(
    r"(?:MP4|MKV|AVI|ISO|FHD|HD|4K|UHD|1080[Pp]|720[Pp]|2160[Pp])"
    r"(?:\s*/\s*\S+)?",
    re.I,
)
_CJK_KANA_RE = re.compile(r"[\u4e00-\u9fff\u3040-\u30ff]")
_BARE_META_STRIP_RE = re.compile(
    r"(?i)(?:亚洲无码|亞洲無碼|日本无码|日本無碼|"
    r"【[^】]{0,40}】|\[[^\]]{0,40}\]|"
    r"\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?|"
    r"\d+\s*V|\d+\s*分|[FHDC4KUhdPp]+)"
)


def _is_short_kana_nick(title: str) -> bool:
    """素人短假名昵称（ゆあ / みう）— 不当正片标题。"""
    s = str(title or "").strip()
    if not s or not _SHORT_KANA_FULL_RE.fullmatch(s):
        return False
    core = _WS_NICK_RE.sub("", s)
    return 1 <= len(core) <= 6


def is_fake_forum_title_fast(title: str | None, code: str = "") -> bool:
    """热路径廉价假壳判断：不做 AI 全量剥码 / bare 剥码。

    用于收帖打分；最终写入仍走完整 is_fake / clean。
    """
    t = str(title or "").strip()
    if not t:
        return True
    needle = str(code or "").strip().upper()
    compact = _COMPACT_SEP_RE.sub("", t).upper()
    needle_compact = _COMPACT_SEP_RE.sub("", needle) if needle else ""
    if needle_compact and (
        compact == needle_compact
        or compact == needle_compact + "MP4"
        or compact == needle_compact + "MKV"
        or compact == needle_compact + "AVI"
        or compact == needle_compact + "FHD"
        or compact == needle_compact + "HD"
        or compact == needle_compact + "4K"
    ):
        return True
    if _CODE_MEDIA_ONLY_RE.fullmatch(t):
        return True
    if needle and _needle_ext_re(needle).fullmatch(t):
        return True
    if _CLIP_SHELL_RE.search(t) or _CLIP_ONLY_RE.fullmatch(t):
        return True
    if _FORUM_PACK_NOISE_RE.search(t) or _PACK_EXTRA_RE.search(t):
        return True
    if _FORUM_META_ZH_JUNK_RE.search(t) and (
        len(t) < _META_SHELL_FAKE_LEN or t.count("+") >= 2 or t.count("＋") >= 2
    ):
        return True
    # 「截止」仅在像合集目录时（邻近番号）才当壳
    if "截止" in t and re.search(r"[A-Za-z]{2,}\s*-?\s*\d{2,}", t):
        return True
    if _TB_PACK_RE.search(t):
        return True
    if _MAGNET_SHELL_RE.search(t) or _MAGNET_CODE_ONLY_RE.fullmatch(t):
        return True
    if _MEDIA_ONLY_RE.fullmatch(t) or _FORUM_GENERIC_ONLY_RE.fullmatch(t):
        return True
    if len(t) < 2:
        return True
    if len(t) <= 3 and not _CJK_KANA_RE.search(t):
        return True
    if _is_short_kana_nick(t):
        return True
    return False


def is_fake_forum_title(title: str | None, code: str = "") -> bool:
    """明显不是正片片名的假标题（番号壳/合集壳/片段壳/磁力壳等）。

    索引写入时应视为空标题，宁缺毋假。
    """
    t = str(title or "").strip()
    if not t:
        return True
    # 先走廉价路径；命中则不必做 AI/bare 重剥
    if is_fake_forum_title_fast(t, code):
        return True
    needle = str(code or "").strip().upper()

    # AI增强 / 分辨率 / ed2k 壳（无正片片名）
    if _is_ai_resolution_shell(t, needle):
        return True

    # 剥代号/体积后几乎无实质（亚洲无码 + 番号 + 【1V/…】）
    bare = _BARE_META_STRIP_RE.sub(" ", t)
    bare = _strip_code_tokens(bare, code)
    bare = _WS_RE.sub(" ", bare).strip(_BARE_EDGE_STRIP)
    if len(bare) < 2:
        return True

    return False
