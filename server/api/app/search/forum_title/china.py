"""国产片商名剥除：题首厂牌前缀 + 全场残留厂牌 + 91fans/出品噪声。"""


import re

from app.search.forum_title.codes import _strip_code_tokens

_CHINA_91_FANS_RE = re.compile(r"(?i)\s*x?\s*91\s*fans?\b")
_CHINA_PRODUCE_RE = re.compile(r"^(?:最新)?(?:出品|上映)[\s　\-–—_]*")
# 国产无码：标题里粘贴的片商名（短词必须带厂牌后缀，避免误伤「不见星空」「蜜桃臀」）
_CHINA_STUDIO_BRAND_RE = re.compile(
    r"(?:"
    r"麻豆(?:传媒|傳媒)(?:映画|最新(?:出品|上映))?|"
    r"果冻(?:传媒|傳媒)(?:最新出品)?|"
    r"星空(?:无限|無限)?(?:传媒|傳媒)|"
    r"蜜桃影像(?:传媒|傳媒)?|蜜桃(?:传媒|傳媒)|"
    r"天美(?:传媒|傳媒)|"
    r"杏吧(?:传媒|傳媒)|"
    r"香蕉(?:视频|視頻|传媒|傳媒|秀)|"
    r"皇家华人|皇家華人|"
    r"爱豆(?:传媒|傳媒)|愛豆(?:传媒|傳媒)|"
    r"扣扣(?:传媒|傳媒)|"
    r"猫爪(?:影像|传媒|傳媒)|"
    r"精东影业|精東影業|"
    r"起点(?:传媒|傳媒)|"
    r"色控(?:传媒|傳媒)|"
    r"性视界(?:传媒|傳媒)|"
    r"大象(?:传媒|傳媒)|大像(?:传媒|傳媒)|"
    r"萝莉社|蘿莉社|"
    r"91制片厂|91製片廠"
    r")"
    # 帖题常见「麻豆傳媒)(mdwp-0033)」破括号，顺带吃掉后随 )
    r"[\s　\-–—_·・✨❤]*[）)]?",
    re.I,
)
# 仅题首可剥的歧义厂牌（文中可能是剧情词）
_CHINA_STUDIO_LEADING_ONLY_RE = re.compile(
    r"^(?:绝对领域|絕對領域|性世界|焦点(?:传媒|傳媒)?|色控|兔子先生)"
    r"[\s　\-–—_·・✨❤]*",
    re.I,
)


def _strip_china_studio_and_code(t: str, code: str = "") -> str:
    """国产无码：剥片商名（题首+残留厂牌后缀）；代号交由 _strip_code_tokens。"""
    s = str(t or "").strip()
    if not s:
        return ""
    for _ in range(4):
        m = _CHINA_STUDIO_LEADING_ONLY_RE.match(s) or _CHINA_STUDIO_BRAND_RE.match(s)
        if not m:
            break
        s = s[m.end() :].strip()
    s = _CHINA_STUDIO_BRAND_RE.sub(" ", s)
    s = _CHINA_91_FANS_RE.sub(" ", s)
    s = _CHINA_PRODUCE_RE.sub("", s).strip()
    return _strip_code_tokens(s, code)
