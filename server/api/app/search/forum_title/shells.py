"""AI增强 / 分辨率 / ed2k 技术壳：剥标签与整题壳判定。"""


import re

from app.search.forum_title.china import _strip_china_studio_and_code
from app.search.forum_title.patterns import _BARE_EDGE_STRIP, _WS_RE

# AI增强 / 分辨率 / ed2k 技术壳（剥完无正片名则拒）
_AI_RES_NOISE_RE = re.compile(
    r"(?i)"
    r"[【\[]\s*(?:AI\s*)?(?:增强|加強|画质|畫质|修复|修復)"
    r"[^】\]]{0,24}[】\]]|"
    r"[【\[]\s*(?:ed2k|115(?:网盘|sha1)?|磁力|磁链|BT)[^】\]]{0,16}[】\]]|"
    r"[【\[]\s*(?:1080|720|2160|4K|UHD|FHD|HD)\s*[Pp]?[^】\]]{0,12}[】\]]|"
    r"[【\[]\s*\d+\s*V\s*/\s*\d+(?:\.\d+)?\s*(?:GB|MB|G|M)(?:B)?[^】\]]{0,20}[】\]]|"
    # 下划线也是字词字符，不用 \\b，改用数字边界
    r"(?<![A-Za-z0-9])\d{3,4}\s*[xX×]\s*\d{3,4}(?![A-Za-z0-9])|"
    r"[（(]\s*(?:1080|720|2160)\s*[Pp]?\s*(?:全高清|高清)?\s*[）)]|"
    r"(?:^|[\s_/\-])(?:1080|720|2160)\s*[Pp]?(?:\s*全高清)?(?=[\s_/\-]|$)|"
    r"(?:^|[\s_])(?:AI\s*)?(?:增强|加強|画质增强|畫质增强)(?=[\s_/【\[]|$)"
)
_AI_SHELL_COMPACT_RE = re.compile(r"[\s_./|·・\-–—:：]+")
_AI_SHELL_TECH_ONLY_RE = re.compile(
    r"(?i)(?:ed2k|ai|mp4|mkv|avi|fhd|hd|4k|uhd|1080p?|720p?|2160p?)+"
)


def _strip_ai_resolution_noise(t: str) -> str:
    """剥 AI增强 / 分辨率 / ed2k 技术标签。"""
    s = str(t or "").strip()
    if not s:
        return ""
    for _ in range(5):
        nxt = _AI_RES_NOISE_RE.sub(" ", s)
        nxt = _WS_RE.sub(" ", nxt).strip(_BARE_EDGE_STRIP)
        if nxt == s:
            break
        s = nxt
    return s


def _is_ai_resolution_shell(title: str, code: str = "") -> bool:
    """整题只剩 AI增强+分辨率+番号/ed2k/片商，无正片片名。"""
    s = _strip_ai_resolution_noise(title)
    s = _strip_china_studio_and_code(s, code)
    s = _AI_SHELL_COMPACT_RE.sub("", s)
    if not s or len(s) < 2:
        return True
    if _AI_SHELL_TECH_ONLY_RE.fullmatch(s):
        return True
    return False
