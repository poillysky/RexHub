"""色花堂中文标题主清洗：clean_forum_zh_title 流程及其专用正则。

去番号 / 版块标签 / 破解字幕 / 清晰度 / 体积等噪声；共享正则见 patterns。
"""


import re
from typing import Iterable

from app.search.forum_title.actors import _strip_trailing_actor_name
from app.search.forum_title.china import _strip_china_studio_and_code
from app.search.forum_title.codes import _needle_clean_res, _strip_code_tokens
from app.search.forum_title.fake import is_fake_forum_title
from app.search.forum_title.patterns import (
    _FORUM_GENERIC_ONLY_RE,
    _FORUM_META_ZH_JUNK_RE,
    _FORUM_PACK_NOISE_RE,
    _META_SHELL_CLEAN_LEN,
    _WS_RE,
)
from app.search.forum_title.shells import _strip_ai_resolution_noise
from app.search.forum_title.titles import _prefer_chinese_segment

# 色花堂帖题噪声：版块标签 / 介质版本 / 清晰度 / 体积
_MP4_SLASH_TAG_RE = re.compile(
    r"[【\[]\s*(?:MP4|MKV|AVI|ISO)\s*/\s*[^】\]]{1,20}[】\]]\s*",
    re.I,
)
_LEADING_4K_BOOST_RE = re.compile(r"^4K(?:60(?:fps)?)?增强[\s\-–—_]*", re.I)
_GENERIC_PREFIX_CODE_RE = re.compile(
    r"^[A-Z]{2,15}[-_ ]?\d{2,5}[A-Z]?\s*[-_:：.]?\s*",
    re.I,
)
_BOARD_DATE_CODE_RE = re.compile(
    r"\b[A-Z]{1,6}\d{0,4}\s+[A-Za-z]{0,4}\d{5,10}\b",
    re.I,
)
_META_TAIL_BROKEN_RE = re.compile(
    r"[【\[]\s*(?:\d+\s*V\s*/\s*)?\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?"
    r"[\d\s./V分帧幀KkUuHhDdPp]*[】\]]?\s*$",
    re.I,
)
_META_TAIL_V_RE = re.compile(
    r"[【\[]\s*\d+\s*V\s*/\s*\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?"
    r"[\w\s./分帧幀]*[】\]]?\s*$",
    re.I,
)
_SHORT_CJK_TITLE_RE = re.compile(r"[\u4e00-\u9fff]{2,3}")
_NO_CODE_NEW_PAREN_RE = re.compile(
    r"（\s*无码新片\s*）|\(\s*无码新片\s*\)", re.I
)
_TRAILING_BANG_RE = re.compile(r"[！!]+\s*$")
_TRAILING_PUNCT_RE = re.compile(r"[、,，\s/｜|。．.\-_:：]+$")
_LEADING_PUNCT_CLEAN_RE = re.compile(r"^[\s\-_:：.]+")
# 题首孤立分集序号：1片名 / 2.片名 / -1片名（勿伤 18岁/91制片/2024）
_LEADING_EPISODE_ORD_RE = re.compile(
    r"^[-–—]?[1-9](?![0-9岁歲天日号號期禁届屆部集章篇制片製片])"
    r"[\s　.\-、:：)·）]*"
    r"(?=[\u4e00-\u9fff《「『])"
)
# 表情/装饰后的分集残号：❤ -1极品嫂子
_EMOJI_EPISODE_ORD_RE = re.compile(
    r"(?:[\u2600-\u27BF\U0001F300-\U0001FAFF❤♥♡⭐✨]+)\s*[-–—]?\d{1,2}"
    r"[\s　.\-、:：)·）]*"
    r"(?=[\u4e00-\u9fff《「『])"
)
_LEADING_ZONE_STRIP_RE = re.compile(
    r"^(?:[（(]\s*)?(?:无码|有码|無碼|有碼)(?:\s*[）)])?[\s\-–—_]*",
    re.I,
)
_RES_P_TAIL_RE = re.compile(
    r"(?i)[\s\-–—_]*\d{3,4}\s*[Pp]?\s*(?:高清|蓝光|藍光)?版?\s*$",
)
_VERSION_TAIL_RE = re.compile(
    r"(?:"
    # 破解/听译/修正（可带字幕），勿单独剥剧情「流出/字幕」
    r"(?:无码|有码|無碼|有碼)?(?:破解|听译|聽譯|修正){1,3}(?:字幕|中字)?版?|"
    r"(?:无码|有码|無碼|有碼)(?:流出|字幕|中字)版?|"
    r"(?:破解|听译|聽譯|修正)(?:字幕|中字)?版?"
    r")\s*$",
    re.I,
)
_FORUM_BOARD_TAG_RE = re.compile(
    r"^[\s　]*[【\[](?:BT(?:种子|種子|/磁力|/磁链|/磁力链接|/磁力鏈接)?|"
    r"磁链|磁力(?:链接|鏈接)?|今日新番|有码|无码|素人|"
    r"高清中文字幕|中文字幕|破解|合集|打包|自转|自购|自扒|转载|自译中字|"
    r"AI\s*画质修复|AI\s*畫质修复|画质修复|畫质修复|"
    r"(?:原汁原味\+?)?(?:AI\s*)?(?:增强|加強|畫质增强|画质增强|無碼增强|无码增强)"
    r"(?:4K|4k|60(?:fps|幀|帧)?)?(?:[丨+/]?(?:ED2K|115(?:网盘|sha1)?|磁力|磁链|4K(?:60(?:FPS|fps)?)?)){0,4}|"
    r"4K(?:60(?:fps|幀|帧)?)?(?:画质|畫质|无码|無碼)?(?:增强|加強)?(?:[丨+/]?(?:ED2K|115(?:网盘|sha1)?)){0,3}|"
    r"115(?:网盘|ED2K|sha1)?)[】\]]\s*[:：]?\s*",
    re.I,
)
_FORUM_BRACKET_NOISE_RE = re.compile(
    r"[【\[]\s*(?:"
    r"AI\s*破解(?:版)?|破解(?:版)?|无码(?:流出|破解|新片)?|有码|"
    r"中文字幕|字幕版|听译(?:修正)?版?|修正版|完整版|自译中字|"
    r"高清|蓝光(?:版)?|藍光(?:版)?|蓝光iso底版|4K|UHD|1080[Pp]|720[Pp]|HD|FHD|"
    r"无修正|中字|繁中|简中|"
    r"BT(?:种子|種子|/磁力|/磁链|/磁力链接|/磁力鏈接)?|磁链|磁力(?:链接|鏈接)?|"
    r"自转|自购|自扒|转载|"
    r"AI\s*画质修复|AI\s*畫质修复|画质修复|畫质修复|"
    r"(?:原汁原味\+?)?(?:AI\s*)?(?:增强|加強|畫质增强|画质增强|無碼增强|无码增强)"
    r"(?:4K|4k|60(?:fps|幀|帧)?)?(?:[丨+/]?(?:ED2K|115(?:网盘|sha1)?|磁力|磁链|4K(?:60(?:FPS|fps)?)?)){0,4}|"
    r"4K(?:60(?:fps|幀|帧)?)?(?:画质|畫质|无码|無碼)?(?:增强|加強)?(?:[丨+/]?(?:ED2K|115(?:网盘|sha1)?)){0,3}|"
    r"115(?:网盘|ED2K|sha1)?"
    r")\s*[】\]]\s*[:：]?",
    re.I,
)
_FORUM_MEDIA_SUFFIX_RE = re.compile(
    r"[\s　]*[（(【\[]?\s*(?:"
    r"蓝光(?:光盘|碟|版)?|藍光(?:光碟|版)?|ブルーレイ(?:ディスク)?|"
    r"Blu-?ray|BD|DVD|4K|UHD|1080[Pp]|720[Pp]|HD|高清|"
    r"無碼流出|无码(?:流出|破解)?|有码|破解(?:版)?|AI\s*破解(?:版)?|"
    r"中文字幕|字幕版|听译(?:修正)?版?|修正版|完整版|中字|繁中|简中"
    r")\s*[）)】\]]?\s*$",
    re.I,
)
_FORUM_SIZE_TAIL_RE = re.compile(
    r"[\s　]*\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?\s*$",
    re.I,
)
_FORUM_DATE_PREFIX_RE = re.compile(
    r"^[\s　]*(?:20\d{6}|20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}|"
    r"\d{1,2}/\d{1,2})\s*[★☆*]?\s*",
)
_FORUM_ACTOR_AGE_ONLY_RE = re.compile(
    r"^[\u4e00-\u9fffA-Za-z·・\s　]{2,20}\d{2}\s*歳\s*$",
)
_FORUM_BROKEN_BRACKET_TAIL_RE = re.compile(
    r"[【\[][^】\]]{0,20}$",
)
_FORUM_EMPTY_PAREN_RE = re.compile(
    r"[（(]\s*[）)]|[（(]\s*(?:果冻传媒|星空传媒|蜜桃传媒|麻豆传媒|香蕉视频)\s*[）)]",
)
# 剥厂牌/番号后残留：) (20230104)片名 → 片名
_ORPHAN_LEADING_PAREN_RE = re.compile(r"^[）)\s　]+")
_LEADING_DATE_PAREN_RE = re.compile(
    r"^[（(]\s*(?:20\d{6}|20\d{2}[-/.]\d{1,2}[-/.]\d{1,2})\s*[）)][\s　]*"
)
# 题首「SA國際傳媒) (20230105)片名」：短片商 + 残 ) + 日期壳
_LEADING_BRAND_ORPHAN_DATE_RE = re.compile(
    r"^[A-Za-z0-9\u4e00-\u9fff·・\s　]{1,28}[）)]\s*"
    r"[（(]\s*(?:20\d{6}|20\d{2}[-/.]\d{1,2}[-/.]\d{1,2})\s*[）)][\s　]*"
)
# 前缀体积/清晰度：[HD/926MB] 【HD版/3.15GB】 【磁 力】[HD/3.21G]
_FORUM_LEADING_HD_SIZE_RE = re.compile(
    r"^(?:[【\[]\s*磁\s*力\s*[】\]]\s*)?"
    r"[【\[]\s*(?:HD(?:版)?|FHD|FHDC|4K|UHD|BT|磁力|磁链)\s*"
    r"(?:[/丨|]\s*\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?)?\s*[】\]]\s*",
    re.I,
)
# 题首区标 / 质量括号：亚洲无码、[FHDC]、［BT磁力］
_FORUM_LEADING_REGION_QUALITY_RE = re.compile(
    r"^(?:"
    r"(?:亚洲无码|亞洲無碼|日本无码|日本無碼|国产无码|國產無碼|欧美无码|歐美無碼)"
    r"|[【\[]\s*(?:FHDC|FHD|HD|4K|UHD|BT(?:\s*磁力)?|磁力|磁链)\s*[】\]]"
    r"|［\s*(?:BT(?:\s*磁力)?|磁力|磁链|FHDC|FHD)\s*］"
    r")[\s　\-–—_:：]*",
    re.I,
)
# 残缺尾括号：【4.39 GB/1V/26分钟（无右括号）
_FORUM_BROKEN_META_TAIL_RE = re.compile(
    r"[【\[]\s*\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?"
    r"(?:\s*/\s*\d+\s*V)?"
    r"(?:\s*/\s*\d+\s*(?:分|分钟|分鐘))?"
    r"[^】\]]*$",
    re.I,
)
# 复合技术标签：【破解/调色/ED2K/Lada0.90】【CPU自转码H265/115ED2K链接】
_FORUM_TECH_SLASH_TAG_RE = re.compile(
    r"[【\[][^】\]]{0,60}?(?:"
    r"ED2K|115|破解|调色|轉码|转码|H\.?265|H\.?264|Lada|自整理|自购|"
    r"增强|加強|磁力|磁链|BT种子|CPU"
    r")[^】\]]{0,60}?[】\]]\s*",
    re.I,
)
_FORUM_STAR_NOISE_RE = re.compile(r"[★☆].*?[★☆]")
# 帖题/描述里任意位置的版块、介质、字幕标签
_FORUM_INLINE_TAG_RE = re.compile(
    r"[【\[]\s*(?:"
    r"BT(?:种子|種子|/种子|/種子|/磁力|/磁链|/磁力链接|/磁力鏈接)?|磁链|磁力(?:链接|鏈接)?|今日新番|有码|无码|素人|"
    r"高清中文字幕|中文字幕|字幕(?:版)?|破解(?:版)?|合集|打包|"
    r"自购|自扒|自转|转载|首发|独家|分享|福利|自译中字|"
    r"AI\s*破解(?:版)?|无码(?:流出|破解|新片)?|无修正|"
    r"AI\s*画质修复|AI\s*畫质修复|画质修复|畫质修复|"
    r"Topaz(?:\s*AI)?(?:\s*\d{3,4}[Pp]?)?|"
    r"最新素人无码|日本素人|最新素人|"
    r"高清|蓝光(?:版)?|藍光(?:版)?|蓝光iso底版|Blu-?ray|BD|DVD|"
    r"HD版|MP4|MKV|"
    r"4K|UHD|1080[Pp]|720[Pp]|HD|FHD|"
    r"听译(?:修正)?版?|修正版|完整版|中字|繁中|简中|"
    r"(?:原汁原味\+?)?(?:AI\s*)?(?:增强|加強|畫质增强|画质增强|無碼增强|无码增强)"
    r"(?:4K|4k|60(?:fps|幀|帧)?)?(?:[丨+/]?(?:ED2K|115(?:网盘|sha1)?|磁力|磁链|4K(?:60(?:FPS|fps)?)?)){0,4}|"
    r"4K(?:60(?:fps|幀|帧)?)?(?:无码|無碼)?(?:增强|加強)?(?:[丨+/]?(?:ED2K|115(?:网盘|sha1)?)){0,3}|"
    r"115(?:网盘|ED2K|sha1)?"
    r")\s*[】\]]\s*[:：]?",
    re.I,
)
# 缺左括号 / 无括号增强前缀
_FORUM_ORPHAN_TAG_RE = re.compile(
    r"^(?:[+\-]?\s*)?(?:增强|加強|AI\s*增强|AI\s*加強|4K(?:60(?:fps)?)?增强)"
    r"[丨+/]?(?:ED2K|115)?[】\]]?\s*",
    re.I,
)
# 尾部 [4K.60fps/MKV/8.84GB] 技术括号
_FORUM_TECH_TAIL_RE = re.compile(
    r"[\s]*[【\[][^】\]]{0,40}(?:\d+(?:\.\d+)?\s*(?:GB|MB|G)|4K|60(?:fps|幀|帧)|MKV|MP4|ISO)[^】\]]{0,40}[】\]]\s*$",
    re.I,
)
# 尾部体积/时长/分集：【3.18G/1V/19分/4K】【1V/702M】
_FORUM_META_TAIL_BRACKET_RE = re.compile(
    r"[【\[]\s*\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?"
    r"(?:\s*/\s*\d+\s*V)?"
    r"(?:\s*/\s*\d+\s*分)?"
    r"(?:\s*/\s*(?:4K|UHD|1080[Pp]|720[Pp]|HD|FHD))?"
    r"\s*[】\]]\s*$",
    re.I,
)
_FORUM_META_TAIL_BRACKET_ALT_RE = re.compile(
    r"[【\[]\s*\d+\s*V\s*/\s*\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?\s*[】\]]\s*$",
    re.I,
)
_FORUM_SOURCE_PREFIX_RE = re.compile(
    r"^[\s　]*(?:"
    r"自购|自扒|自转|转载|首发|独家|福利|分享|"
    # 「最新」仅当后接发布/上架等来源词，避免误剥「最新女友…」
    r"最新(?:发布|發佈|上架|资源|資源|放送|投稿|出品)"
    r")[\s:：\-–—]*",
    re.I,
)
_FORUM_FILE_EXT_TAIL_RE = re.compile(
    r"[\s.]*\.(?:mp4|mkv|avi|wmv|mov|ts|m2ts|rar|zip|7z|iso)\s*$",
    re.I,
)
_FORUM_RES_TAIL_RE = re.compile(
    r"[\s_]*\d{3,4}\s*[xX×]\s*\d{3,4}"
    r"(?:\s*[（(]?\s*(?:1080|720|2160|4K|UHD)?[Pp]?[^）)]{0,20}[）)]?)?\s*$",
    re.I,
)
_FORUM_DASH_QUALITY_TAIL_RE = re.compile(
    r"[\s\-–—_]+(?:1080[Pp]?|720[Pp]?|2160[Pp]?|4K|UHD|HD|FHD|MP4|MKV|AVI)\s*$",
    re.I,
)
_FORUM_LEADING_QUALITY_RE = re.compile(
    r"^(?:1080[Pp]?|720[Pp]?|2160[Pp]?|4K|UHD|HD|FHD|MP4|MKV|AVI)[\s\-–—_]+",
    re.I,
)
_FORUM_LEADING_PUNCT_RE = re.compile(r"^[\s\-–—_·・:：.–]+")


def _strip_orphan_meta_prefix(t: str) -> str:
    """清题首残括号 / 日期壳：`) (20230104)片名` → `片名`。"""
    s = str(t or "").strip()
    if not s:
        return ""
    for _ in range(6):
        nxt = _LEADING_BRAND_ORPHAN_DATE_RE.sub("", s)
        nxt = _ORPHAN_LEADING_PAREN_RE.sub("", nxt)
        nxt = _LEADING_DATE_PAREN_RE.sub("", nxt)
        nxt = _FORUM_EMPTY_PAREN_RE.sub(" ", nxt)
        nxt = _FORUM_DATE_PREFIX_RE.sub("", nxt).strip()
        nxt = _WS_RE.sub(" ", nxt).strip()
        if nxt == s:
            break
        s = nxt
    return s


def _strip_inline_forum_tags(t: str) -> str:
    """去掉字符串任意位置的版块/介质/字幕括号标签。"""
    for _ in range(6):
        nxt = _FORUM_INLINE_TAG_RE.sub(" ", t)
        nxt = _WS_RE.sub(" ", nxt).strip()
        if nxt == t:
            break
        t = nxt
    return t


def clean_forum_zh_title(
    raw: str,
    code: str = "",
    *,
    actors: Iterable[str] | None = None,
    allow_weak: bool = False,
) -> str:
    """安全清洗色花堂标题：去番号 / 版块标签 / 破解字幕 / 清晰度 / 体积等噪声。

    - 索引聚合调用时 actors=None：不剥女优（女优只从描述字段取）。
    - 显式传入 actors 时：仅剥与名单匹配的末尾女优名。
    - allow_weak=True：合集/过短也可继续洗；假壳（番号MP4/片段/汇总）仍返回空。
    """
    t = str(raw or "").strip()
    if not t:
        return ""
    t = _WS_RE.sub(" ", t).strip()
    needle = str(code or "").strip().upper()
    raw_keep = t

    # 合集/黑客打包帖：不当作单片标题（弱模式仍继续洗，避免索引空题）
    if _FORUM_PACK_NOISE_RE.search(t) and not allow_weak:
        return ""

    # [HD/926MB] 【HD版/3.15GB】【磁 力】前缀
    for _ in range(3):
        nxt = _FORUM_LEADING_HD_SIZE_RE.sub("", t).strip()
        if nxt == t:
            break
        t = nxt

    # 亚洲无码 / [FHDC] / ［BT磁力］
    for _ in range(4):
        nxt = _FORUM_LEADING_REGION_QUALITY_RE.sub("", t).strip()
        if nxt == t:
            break
        t = nxt

    # AI增强 / 分辨率 / ed2k 技术标签
    t = _strip_ai_resolution_noise(t)

    # 复合技术标签（破解/调色/ED2K…）整段剥掉
    for _ in range(4):
        nxt = _FORUM_TECH_SLASH_TAG_RE.sub(" ", t)
        nxt = _WS_RE.sub(" ", nxt).strip()
        if nxt == t:
            break
        t = nxt

    # 【MP4/无码】【MP4/中文字幕】类斜杠标签
    t = _MP4_SLASH_TAG_RE.sub(" ", t)
    t = _WS_RE.sub(" ", t).strip()

    # 反复剥前缀版块标签
    for _ in range(4):
        nxt = _FORUM_BOARD_TAG_RE.sub("", t).strip()
        if nxt == t:
            break
        t = nxt

    # 任意位置的中括号标签（帖标题常见）
    t = _strip_inline_forum_tags(t)
    for _ in range(3):
        nxt = _FORUM_ORPHAN_TAG_RE.sub("", t).strip()
        if nxt == t:
            break
        t = nxt
    t = _LEADING_4K_BOOST_RE.sub("", t).strip()

    # 自购/转载等来源前缀
    for _ in range(3):
        nxt = _FORUM_SOURCE_PREFIX_RE.sub("", t).strip()
        if nxt == t:
            break
        t = nxt

    # 国产片商名 + 全场番号/FC2 代号
    t = _strip_china_studio_and_code(t, needle)
    t = _strip_code_tokens(t, needle)
    t = _strip_orphan_meta_prefix(t)

    # 题首/装饰后的孤立分集序号（1片名、❤-1片名）
    for _ in range(2):
        nxt = _LEADING_EPISODE_ORD_RE.sub("", t).strip()
        nxt = _EMOJI_EPISODE_ORD_RE.sub(" ", nxt)
        nxt = _WS_RE.sub(" ", nxt).strip()
        if nxt == t:
            break
        t = nxt

    # ★…★ 装饰噪声
    t = _FORUM_STAR_NOISE_RE.sub(" ", t)
    t = _WS_RE.sub(" ", t).strip()
    # 剥星号后再清一轮序号残渣
    t = _LEADING_EPISODE_ORD_RE.sub("", t).strip()
    t = _EMOJI_EPISODE_ORD_RE.sub(" ", t)
    t = _WS_RE.sub(" ", t).strip()
    # 日期前缀
    t = _FORUM_DATE_PREFIX_RE.sub("", t).strip()
    t = _FORUM_EMPTY_PAREN_RE.sub(" ", t)
    t = _strip_orphan_meta_prefix(t)
    t = _WS_RE.sub(" ", t).strip()

    # 开头番号（含 [HEYZO-3291] 形态）
    if needle:
        lead_re, mid_re, bare_re, paren_re = _needle_clean_res(needle)
        t = lead_re.sub("", t).strip()
        t = _GENERIC_PREFIX_CODE_RE.sub("", t).strip()
        # 文中残留番号（清洗标签后常见）
        t = mid_re.sub(" ", t)
        t = bare_re.sub(" ", t)
        t = paren_re.sub(" ", t)
        # C0930 ki231024 / 板号+日期串
        t = _BOARD_DATE_CODE_RE.sub(" ", t)
        t = _WS_RE.sub(" ", t).strip()

    # 括号内版本/字幕噪声（可多段）
    for _ in range(4):
        nxt = _FORUM_BRACKET_NOISE_RE.sub(" ", t)
        nxt = _WS_RE.sub(" ", nxt).strip()
        if nxt == t:
            break
        t = nxt

    # 尾部体积标签先剥（避免媒体后缀先吃掉 /4K】 留下残缺括号）
    t = _FORUM_SIZE_TAIL_RE.sub("", t).strip()
    for _ in range(3):
        nxt = _FORUM_META_TAIL_BRACKET_RE.sub("", t).strip()
        nxt = _FORUM_META_TAIL_BRACKET_ALT_RE.sub("", nxt).strip()
        if nxt == t:
            break
        t = nxt
    # 残缺体积尾巴：…！【3.18G/1V/19分  或 【1V/12.7G/57分/4K60帧】
    t = _META_TAIL_BROKEN_RE.sub("", t).strip()
    t = _META_TAIL_V_RE.sub("", t).strip()

    # 尾部介质/版本后缀
    for _ in range(4):
        nxt = _FORUM_MEDIA_SUFFIX_RE.sub("", t).strip()
        if nxt == t:
            break
        t = nxt

    # 开头残留「无码/有码」及括号形态
    t = _LEADING_ZONE_STRIP_RE.sub("", t).strip()

    # 文件后缀 / -1080P 类尾巴
    t = _FORUM_FILE_EXT_TAIL_RE.sub("", t).strip()
    t = _FORUM_DASH_QUALITY_TAIL_RE.sub("", t).strip()
    t = _FORUM_RES_TAIL_RE.sub("", t).strip()
    t = _RES_P_TAIL_RE.sub("", t).strip()
    t = _FORUM_TECH_TAIL_RE.sub("", t).strip()
    t = _FORUM_BROKEN_META_TAIL_RE.sub("", t).strip()
    t = _TRAILING_BANG_RE.sub("", t).strip()
    for _ in range(3):
        nxt = _FORUM_LEADING_QUALITY_RE.sub("", t).strip()
        if nxt == t:
            break
        t = nxt

    # 无括号粘连的版本尾巴：…无码破解听译修正版
    t = _VERSION_TAIL_RE.sub("", t).strip()
    t = _NO_CODE_NEW_PAREN_RE.sub("", t).strip()

    # 末尾女优名（可带顿号/句号/空格分隔；含简繁异体字）
    t = _strip_trailing_actor_name(t, actors or [])

    # 破折号 / 全角括号：有中文译名则优先中文
    t = _prefer_chinese_segment(t)

    t = _TRAILING_PUNCT_RE.sub("", t).strip()
    t = _LEADING_PUNCT_CLEAN_RE.sub("", t).strip()
    t = _FORUM_LEADING_PUNCT_RE.sub("", t).strip()
    t = _LEADING_EPISODE_ORD_RE.sub("", t).strip()
    t = _strip_orphan_meta_prefix(t)
    # 再剥一轮残留括号标签（番号剥离后露出的）
    t = _strip_inline_forum_tags(t)
    if len(t) > 100:
        t = t[:100].rstrip()
    if needle and t.upper() == needle:
        return ""
    if _FORUM_GENERIC_ONLY_RE.fullmatch(t) and not allow_weak:
        return ""
    if _FORUM_ACTOR_AGE_ONLY_RE.fullmatch(t) and not allow_weak:
        return ""
    t = _FORUM_BROKEN_BRACKET_TAIL_RE.sub("", t).strip()
    # 合集元信息被抠成「标题」时丢掉（宁缺毋假，弱模式也不保留壳）
    if t and _FORUM_META_ZH_JUNK_RE.search(t) and len(t) < _META_SHELL_CLEAN_LEN:
        return ""
    if len(t) < 4:
        # 短中文正片名（上海滩 / 绿帽）保留；其它过短宁缺
        if _SHORT_CJK_TITLE_RE.fullmatch(t):
            if is_fake_forum_title(t, needle):
                return ""
            return t
        if allow_weak:
            # 弱兜底：保留剥标签后的原文片段；假壳仍清空
            weak = _WS_RE.sub(" ", raw_keep).strip()
            if needle:
                weak = _needle_clean_res(needle)[0].sub("", weak).strip()
            weak = _strip_inline_forum_tags(weak)
            weak = weak[:80].strip()
            if (
                weak
                and weak.upper() != needle
                and not is_fake_forum_title(weak, needle)
            ):
                return weak
        return ""
    if is_fake_forum_title(t, needle):
        return ""
    return t
