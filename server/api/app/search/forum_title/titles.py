"""语言判定与中文段优先：is_likely_chinese / is_likely_japanese /
_prefer_chinese_segment / is_indexable_forum_title。"""


import re

from app.search.forum_title.fake import _is_short_kana_nick, is_fake_forum_title
from app.search.forum_title.patterns import _FORUM_META_ZH_JUNK_RE, _WS_NICK_RE

_KANA_RE = re.compile(r"[\u3040-\u30ff]")
_CJK_RE = re.compile(r"[\u4e00-\u9fff]")
_KANA_EXT_RE = re.compile(r"[\u3040-\u30ff\u31f0-\u31ff]")
_ZONE_ONLY_RE = re.compile(r"(?:无码|有码|無碼|有碼|中字|字幕|破解|增强|合集)", re.I)
_PLUS_SLASH_RE = re.compile(r"[+\uff0b/｜|]")
_PAREN_INNER_RE = re.compile(r"[（(]([^）)]{4,80})[）)]")
_LEADING_KANA_LATIN_RE = re.compile(
    r"^[\u3040-\u30ff\u31f0-\u31ffA-Za-z0-9\s　·・]+",
)
_SPACE_SPLIT_RE = re.compile(r"[\s　]+")
_FORUM_EM_DASH_SPLIT_RE = re.compile(r"\s*[–—]\s*|\s+-\s+")

# 论坛 titleZh 可复用门槛：壳题 / 截断壳不合格 → 仍走网络
_TITLE_ZH_TRUNC_TAIL_RE = re.compile(r"[、，,…]+$")
_TITLE_ZH_BROKEN_LEAD_RE = re.compile(r"^.{1,4}[、，,]")
_TITLE_ZH_WESTERN_NAME_RE = re.compile(
    r"^[\u4e00-\u9fff]{2,8}[-·・‧][\u4e00-\u9fff]{2,12}$"
)
_TITLE_ZH_AV_SHELL_RE = re.compile(
    r"^(?:AV)?(?:隐退作|引退作|出道作|解禁作|引退|隐退)$|"
    r"^AV初[体體][験驗].{0,6}$",
    re.I,
)


def _prefer_chinese_segment(t: str) -> str:
    """同一帖题里：中文括号译名 / 破折号右侧中文 优先于日文原文。"""
    raw = str(t or "").strip()
    if not raw:
        return ""

    def _usable_zh(s: str) -> bool:
        s = str(s or "").strip()
        if not is_likely_chinese(s):
            return False
        # 排除纯分区词 / 过短女优名 / 合集元信息
        if _ZONE_ONLY_RE.fullmatch(s):
            return False
        if _FORUM_META_ZH_JUNK_RE.search(s):
            return False
        # 人名形短串不当译名（避免「（花咲澪）」盖掉日文）
        try:
            from app.search.forum_seed import _looks_like_bare_actor_title

            if _looks_like_bare_actor_title(s):
                return False
        except Exception:
            pass
        # 短纯中文译名可取（绿帽/上海滩）；过短拉丁/混排仍拒
        if len(s) < 8:
            return bool(re.fullmatch(r"[\u4e00-\u9fff]{2,7}", s))
        # 真译名一般较长，短壳「含单体+共演+写真」不要
        if len(s) < 12 and _PLUS_SLASH_RE.search(s):
            return False
        return True

    # （中文译名）或 (中文译名)
    for m in _PAREN_INNER_RE.finditer(raw):
        inner = m.group(1).strip()
        if _usable_zh(inner):
            return inner

    if _FORUM_EM_DASH_SPLIT_RE.search(raw):
        left, right = _FORUM_EM_DASH_SPLIT_RE.split(raw, maxsplit=1)
        left, right = left.strip(), right.strip()
        # 右侧整段是中文片名（够长，非女优短名）
        if _usable_zh(right):
            return right
        # 右侧里再挖括号中文
        for m in _PAREN_INNER_RE.finditer(right):
            inner = m.group(1).strip()
            if _usable_zh(inner):
                return inner
        # 右侧去假名女优前缀后仍是中文
        right_stripped = _LEADING_KANA_LATIN_RE.sub("", right).strip(" （()）")
        if _usable_zh(right_stripped):
            return right_stripped
        # 右侧只是女优名：保留左侧日文片名
        if len(left) >= 4:
            return left

    # 日文名 + 空格 + 中文译名：取无假名的中文段
    if _KANA_RE.search(raw) and _CJK_RE.search(raw):
        parts = _SPACE_SPLIT_RE.split(raw)
        zh_parts = [p for p in parts if _usable_zh(p)]
        if zh_parts:
            joined = " ".join(zh_parts)
            if _usable_zh(joined) or is_likely_chinese(joined):
                return joined

    return raw


def is_likely_chinese(title: str | None) -> bool:
    """简体/繁体中文片名（无假名）— 对齐 scrape util.isLikelyChinese。"""
    t = str(title or "").strip()
    if not t or not _CJK_RE.search(t):
        return False
    # 忽略中点・等标点，勿把「教室・厕所」判成日文（・属假名区 U+30FB）
    body = re.sub(r"[\s・･·‧\-–—:：|/／～~]", "", t)
    if _KANA_RE.search(body):
        return False
    # 英文片名末尾挂女优中文名不算中文题
    cjk = sum(1 for ch in t if "\u4e00" <= ch <= "\u9fff")
    if cjk / max(len(t), 1) < 0.35 and cjk < 8:
        return False
    return True


def is_likely_japanese(title: str | None) -> bool:
    """含假名的日文片名（非纯中文）— 对齐 scrape util.isLikelyJapanese。"""
    t = str(title or "").strip()
    if not t or is_likely_chinese(t):
        return False
    return bool(_KANA_EXT_RE.search(t))


def is_indexable_forum_title(
    title: str | None,
    code: str = "",
    *,
    assume_not_fake: bool = False,
) -> bool:
    """索引可写标题：中文优先候选 / 日文正片兜底；假壳与纯拉丁壳不可写。

    正常：合格中文，或含汉字/假名的日文正片名（非短昵称）。
    非正常：假壳、合集壳、番号+介质、纯英文罗马字、短假名昵称等 → 宁缺毋假。
    assume_not_fake=True：调用方已确认非假壳（如刚过 clean），跳过完整 is_fake。
    """
    t = str(title or "").strip()
    if not t:
        return False
    if not assume_not_fake and is_fake_forum_title(t, code):
        return False
    if _is_short_kana_nick(t):
        return False
    if is_likely_chinese(t):
        return True
    if is_likely_japanese(t):
        # 日文正片至少要有一定长度；纯短昵称已在上面拒绝
        core = _WS_NICK_RE.sub("", t)
        return len(core) >= 5
    # 少量汉字题（无假名、不够 is_likely_chinese 阈值）仍可作兜底
    if _CJK_RE.search(t) and len(t) >= 4:
        return True
    return False
