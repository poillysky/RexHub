"""观看进度：跨设备续播。

进度保存在 data/progress.json（0600），App 播放时上报、打开列表时拉取；
本地 `UserDefaults` 仍作缓存，断网时照常续播。
"""

from __future__ import annotations

import json
import math
import os
import threading
import time

from . import config

PROGRESS_PATH = config.DATA_DIR / "progress.json"

# 单条记录上限，超出后按更新时间淘汰最旧的，避免文件无限增长。
MAX_ENTRIES = 2000

# 起播 5 秒内或距片尾 3 秒内视为没看 / 看完，不保留记录。
MIN_POSITION = 5.0
END_MARGIN = 3.0

_LOCK = threading.Lock()


def _read() -> dict[str, dict]:
    try:
        data = json.loads(PROGRESS_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    items = data.get("items") if isinstance(data, dict) else None
    return items if isinstance(items, dict) else {}


def _write(items: dict[str, dict]) -> None:
    config.ensure_data_dir()
    tmp = PROGRESS_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"items": items}, ensure_ascii=False), "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(PROGRESS_PATH)


def _numbers(raw: object) -> tuple[float, float, float] | None:
    if not isinstance(raw, dict):
        return None
    try:
        position = float(raw.get("position"))
        duration = float(raw.get("duration"))
        updated_at = float(raw.get("updated_at", 0))
    except (TypeError, ValueError):
        return None
    if not (math.isfinite(position) and math.isfinite(duration) and math.isfinite(updated_at)):
        return None
    return position, duration, updated_at


def _updated_at(raw: object) -> float:
    values = _numbers(raw)
    return values[2] if values else 0.0


def _entry(pickcode: str, raw: object) -> dict | None:
    """把落盘的原始记录转成响应结构；无效或已看完的记录返回 None。"""
    values = _numbers(raw)
    if values is None:
        return None
    position, duration, updated_at = values
    if duration <= 0 or position < MIN_POSITION or position >= duration - END_MARGIN:
        return None
    return {
        "pickcode": pickcode,
        "position": position,
        "duration": duration,
        "updated_at": updated_at,
    }


def all_entries() -> list[dict]:
    """全部有效记录，按更新时间倒序，App 一次拉取即可补齐列表。"""
    with _LOCK:
        items = _read()
        entries = [entry for code, raw in items.items() if (entry := _entry(code, raw))]

    entries.sort(key=lambda entry: entry["updated_at"], reverse=True)
    return entries


def save(pickcode: str, position: float, duration: float) -> dict | None:
    """写入单条进度；位置过小或已到片尾时删除记录并返回 None。"""
    code = pickcode.strip()
    if not code:
        return None
    try:
        pos = float(position)
        dur = float(duration)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(pos):
        return None

    now = time.time()
    # 位置归零表示没看 / 看完，直接删除已有记录；时长缺失时只当作删除信号处理。
    finished = pos < MIN_POSITION or (
        math.isfinite(dur) and dur > 0 and pos >= dur - END_MARGIN
    )

    with _LOCK:
        items = _read()
        if finished:
            if items.pop(code, None) is None:
                return None
            _write(items)
            return None

        if not math.isfinite(dur) or dur <= 0:
            return None

        items[code] = {"position": pos, "duration": dur, "updated_at": now}
        if len(items) > MAX_ENTRIES:
            newest = sorted(items.items(), key=lambda pair: _updated_at(pair[1]), reverse=True)
            items = dict(newest[:MAX_ENTRIES])
        _write(items)

    return {"pickcode": code, "position": pos, "duration": dur, "updated_at": now}
