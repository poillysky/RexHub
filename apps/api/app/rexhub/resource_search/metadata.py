"""密码提取、元数据整理与结果条目组装，以及跨库合并的字段互补。"""


import re
import urllib.parse

from .keywords import _is_cjk


_PWD_RE = re.compile(
    r"(?:解压密码|解压码|压缩密码|提取码|提取密码|访问码|网盘密码|度盘密码)"
    r"[^:：=\n]{0,10}[:：=]\s*([^\s，,、;；|/\\]{2,40})"
)

_PWD_EMPTY = {"无", "无需", "无需解压", "无密码", "不需要", "none", "null", "-"}


def _password_from_text(text: str) -> str:
    """从资源描述里提取密码/提取码。

    色花堂的 ed2k 资源把帖子正文放在 search_string 里，常见形态：
    「【解压密码】：1998@www.98T.la」「度盘解压密码:asdfghjkl」「提取码：1grv」。
    只认带明确字段名的写法，避免把「密码房」「流量密码」这类标题当成密码。
    """

    if not text:
        return ""
    match = _PWD_RE.search(text)
    if not match:
        return ""
    value = match.group(1).strip().strip("。.,，;；")
    if not value or value.lower() in _PWD_EMPTY:
        return ""
    # 密码必然是 ASCII 串；带中文的说明是标题语义（如「爱情密码：玉儿怒张」）
    if any(_is_cjk(char) for char in value):
        return ""
    if not any(char.isalnum() for char in value):
        return ""
    return value


# MARK: 元数据整理

_SIZE_UNITS = ("B", "KB", "MB", "GB", "TB", "PB")

# 帖子正文里的信息块：每行形如「【影片名称】：xxx」
_INFO_RE = re.compile(r"【([^】\n]{1,10})】\s*[：:]\s*([^【\n]+)")
_INFO_LABELS = {
    "影片名称": "title",
    "出演女优": "actresses",
    "影片容量": "size",
    "是否有码": "censored",
    "影片时间": "runtime",
    "资源来源": "origin",
}

# 标题开头的番号，如 DASS-211 / FC2PPV-1234567
_HEAD_CODE_RE = re.compile(r"^([a-z][a-z0-9]{1,11}-\d{2,7})", re.IGNORECASE)

# 出演女优分隔符：顿号 / 斜杠 / 逗号 / 分号 / 竖线
_ACTRESS_SPLIT_RE = re.compile(r"[、,，/／;；|｜]+")


def _size_text(value) -> str:
    """字节数转人类可读容量：1024 进制，GB 保留两位小数。"""

    try:
        size = float(value or 0)
    except (TypeError, ValueError):
        return ""
    if size <= 0:
        return ""
    index = 0
    while size >= 1024 and index < len(_SIZE_UNITS) - 1:
        size /= 1024
        index += 1
    unit = _SIZE_UNITS[index]
    if unit in ("B", "KB"):
        return f"{size:.0f} {unit}"
    return f"{size:.2f} {unit}"


def _iso(value) -> str:
    """datetime 转 ISO 字符串；已经缓存的字符串原样返回。"""

    if not value:
        return ""
    try:
        return value.isoformat()
    except AttributeError:
        return str(value)


def _head_code(text: str) -> str:
    match = _HEAD_CODE_RE.match((text or "").strip())
    return match.group(1).upper() if match else ""


def _info_fields(text: str) -> dict:
    """从色花堂帖子正文里取结构化字段，正文比数据库列更全。"""

    if not text:
        return {}
    fields: dict[str, str] = {}
    for label, value in _INFO_RE.findall(text):
        key = _INFO_LABELS.get(label.strip())
        if key and key not in fields:
            fields[key] = value.strip(" \t\r，,；;/")
    return fields


def _actresses(value: str) -> list[str]:
    names = [
        part.strip()
        for part in _ACTRESS_SPLIT_RE.split(value or "")
        if part.strip()
    ]
    # 名字太长基本是描述文本，不是演员名
    return [name for name in names if len(name) <= 24][:8]


def _resolution(value) -> str:
    """bitmagnet 的分辨率枚举 V1080p / V2160p，统一成 1080p / 2160p。"""

    text = str(value or "").strip()
    if not text:
        return ""
    if text.lower().startswith("v") and len(text) > 1:
        text = text[1:]
    if text.lower() in ("other", "unknown"):
        return ""
    return text


def _bitmagnet_items(rows, meta: dict | None = None) -> list[dict]:
    meta = meta or {}
    items: list[dict] = []
    for row in rows:
        name = row["name"]
        extra = meta.get(str(row["info_hash"]).lower(), {})
        items.append(
            {
                "title": name,
                "link": (
                    "magnet:?xt=urn:btih:"
                    + row["info_hash"]
                    + "&dn="
                    + urllib.parse.quote(name)
                ),
                "kind": "磁力",
                "password": _password_from_text(name),
                "size": int(row["size"] or 0),
                "sizeText": _size_text(row["size"]),
                "filesCount": int(row["files_count"] or 0),
                "createdAt": _iso(row["created_at"]),
                "seeders": extra.get("seeders"),
                "leechers": extra.get("leechers"),
                "resolution": _resolution(extra.get("video_resolution")),
                "codec": str(extra.get("video_codec") or ""),
                "releaseGroup": str(extra.get("release_group") or ""),
                "code": _head_code(name),
            }
        )
    return items


def _ed2k_items(rows, meta: dict | None = None) -> list[dict]:
    meta = meta or {}
    items: list[dict] = []
    for row in rows:
        filename = str(row["filename"] or "")
        source = meta.get(str(row["hash"] or "").upper(), {})
        # 色花堂有两种叫法：帖子标题（resource_sources.title）当展示标题，
        # 文件名留作详情页里的「资源名称」；没抓到帖子标题时两者都退回文件名。
        post_title = str(source.get("title") or "").strip()
        title = post_title or filename
        description = str(source.get("description") or "")
        info = _info_fields(description)
        images = [
            str(url).strip()
            for url in (source.get("preview_images") or [])
            if str(url).strip().lower().startswith(("http://", "https://"))
        ][:4]
        link = row["ed2k_link"] or ""
        items.append(
            {
                "title": title,
                "resourceName": filename if post_title and post_title != filename else "",
                "link": link,
                "kind": "磁力" if link.lower().startswith("magnet:") else "ed2k",
                # 密码优先取帖子里的结构化字段，其次从正文 / 文件名兜底
                "password": str(source.get("extract_password") or "").strip()
                or _password_from_text(str(row["search_string"] or ""))
                or _password_from_text(title),
                "size": int(row["size"] or 0),
                "sizeText": _size_text(row["size"]),
                "createdAt": _iso(row["created_at"]),
                "boardName": str(source.get("board_name") or ""),
                "sourceUrl": str(source.get("source_url") or ""),
                "description": description,
                "previewImages": images,
                "actresses": _actresses(info.get("actresses", "")),
                "code": _head_code(filename) or _head_code(info.get("title", "")),
                "censored": info.get("censored", ""),
            }
        )
    return items


_METADATA_FIELDS = ("boardName", "sourceUrl", "description", "previewImages")
_TORRENT_FIELDS = (
    "seeders",
    "leechers",
    "resolution",
    "codec",
    "releaseGroup",
    "filesCount",
)


def _metadata_rich(row: dict) -> bool:
    """帖子类来源（色花堂）带板块、来源帖、正文或预览图，信息比纯种子库更全。"""

    return any(bool(row.get(key)) for key in _METADATA_FIELDS)


def _merge_metadata(target: dict, donor: dict) -> None:
    """同一条链在两个库都有时，把对方缺的做种数、画质等字段补进来。

    只填空值，不覆盖已有内容：信息更全的那条保持原样，另一条只做补充。
    """

    for key in _TORRENT_FIELDS:
        value = donor.get(key)
        if value is None or value == "":
            continue
        # 0 和空字符串都算「这条没带」，但做种 0 本身是有效数据，要能带过来
        if target.get(key) in (None, ""):
            target[key] = value
