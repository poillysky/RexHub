"""资源链接的文件哈希提取：跨库去重的统一标识。"""


import base64
import re


_LINK_TOKEN_RE = re.compile(r"magnet:\?\S+|ed2k://\S+|(?:https?|115)://\S+", re.I)
_BTIH_RE = re.compile(r"urn:btih:([A-Za-z0-9]+)", re.I)
_ED2K_HASH_RE = re.compile(r"ed2k://\|file\|[^|]*\|\d+\|([0-9A-Fa-f]{32})\|")


def _link_identity(link: str) -> str | None:
    """取资源链接里的文件哈希，用于跨库去重。

    磁力取 `urn:btih:` 那段（40 位十六进制或 32 位 base32），ed2k 取 `|file|名|大小|哈希|`
    里的哈希；两者都归一化成大写十六进制。一个记录里挂了多条链接（合集/多文件帖）
    不参与去重，返回 None，避免误删整组资源。
    """

    tokens = _LINK_TOKEN_RE.findall(link or "")
    if len(tokens) != 1:
        return None

    token = tokens[0]

    match = _BTIH_RE.search(token)
    if match:
        raw = match.group(1).strip()
        if len(raw) == 32:
            try:
                return base64.b32decode(raw.upper()).hex().upper()
            except Exception:  # noqa: BLE001
                return raw.upper()
        return raw.upper()

    match = _ED2K_HASH_RE.match(token)
    if match:
        return match.group(1).upper()

    return None
