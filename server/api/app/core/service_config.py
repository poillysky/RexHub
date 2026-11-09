"""服务型配置的公共读取（元库 settings_store 为唯一真源）。

四个外部服务（MoviePilot / MorePlay / CloudSaver / AVDB）配置形状一致：
``enabled``、``baseUrl``、``timeoutSec``、``note``。这里负责读库、类型收敛
与地址归一化，各自的密钥字段仍由客户端模块补充。
"""

from typing import Any
from urllib.parse import urlparse

import app.core.settings_store as settings_store


def normalize_base(url: str) -> str:
    """归一化服务地址；只接受 http/https，避免 javascript:/file: 之类写进配置后被当作链接。"""
    s = str(url or "").strip()
    if not s:
        return ""
    if "://" not in s:
        s = f"http://{s}"
    parsed = urlparse(s)
    if parsed.scheme.lower() not in ("http", "https") or not parsed.netloc:
        return ""
    try:
        parsed.port
    except ValueError:
        return ""
    return s.rstrip("/")


def read_service(
    key: str,
    *,
    default_timeout: float,
    timeout_min: float,
    timeout_max: float,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """返回 (原始配置, 公共字段视图)；缺失或类型异常时按默认值收敛。"""
    raw = settings_store.get_setting(key) or {}
    if not isinstance(raw, dict):
        raw = {}

    enabled = raw.get("enabled")
    if enabled is None:
        enabled = True
    try:
        timeout = float(raw.get("timeoutSec") or default_timeout)
    except (TypeError, ValueError):
        timeout = default_timeout

    view: dict[str, Any] = {
        "enabled": bool(enabled),
        "baseUrl": str(raw.get("baseUrl") or "").strip(),
        "timeoutSec": max(timeout_min, min(timeout, timeout_max)),
        "note": str(raw.get("note") or ""),
    }
    return raw, view
