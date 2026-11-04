"""App 外观相关的服务端配置。

图标库地址统一保存在 data/appearance.json（0600），App 只作为管理端读写；
客户端本地 `UserDefaults` 仅作离线缓存。
"""

from __future__ import annotations

import json
import os
from urllib.parse import urlparse

from app.rexhub import config

APPEARANCE_PATH = config.DATA_DIR / "appearance.json"

MAX_ICON_LIBRARIES = 20

# 默认推荐：高质量彩色图标库（GitHub 开源），App 端按需取用。
DEFAULT_ICON_LIBRARIES = [
    "https://github.com/xushier/HD-Icons",
    "https://github.com/homarr-labs/dashboard-icons",
    "https://github.com/icons8/flat-color-icons",
    "https://github.com/xandemon/developer-icons",
]


def _read() -> dict:
    try:
        data = json.loads(APPEARANCE_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write(data: dict) -> None:
    config.ensure_data_dir()
    tmp = APPEARANCE_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(APPEARANCE_PATH)


def _valid(url: str) -> bool:
    parsed = urlparse(url)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def icon_libraries() -> list[str]:
    """未落盘时返回推荐默认值；显式保存空列表表示不使用在线图标库。"""
    raw = _read().get("icon_libraries")
    if not isinstance(raw, list):
        return list(DEFAULT_ICON_LIBRARIES)

    urls: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            continue
        value = item.strip()
        if _valid(value) and value not in urls:
            urls.append(value)
    return urls


def save_icon_libraries(urls: list[str]) -> list[str]:
    cleaned: list[str] = []
    for item in urls:
        value = item.strip() if isinstance(item, str) else ""
        if not value:
            continue
        if not _valid(value):
            raise ValueError("图标库地址必须是 http 或 https 开头的完整链接")
        if value not in cleaned:
            cleaned.append(value)
    if len(cleaned) > MAX_ICON_LIBRARIES:
        raise ValueError(f"图标库最多配置 {MAX_ICON_LIBRARIES} 个")

    data = _read()
    data["icon_libraries"] = cleaned
    _write(data)
    return cleaned
