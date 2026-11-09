"""115 网盘压缩包解压任务：状态、持久化、配置与任务调度辅助。

队列 / 扫描结果保存在内存，并按节流策略落盘；本模块只负责读写状态，
具体执行逻辑见 `app.p115.extract_worker`，对外接口见 `app.p115.extract_jobs`。
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any

import app.core.settings_store as settings_store
from app.core.db import data_dir

log = logging.getLogger("p115-extract-jobs")

# 进度更新很频繁，落盘做节流；关键节点强制写
SAVE_MIN_INTERVAL_S = 1.0
# 队列与扫描结果落盘，刷新页面/重启服务后还能看到上次进度
STATE_PATH = data_dir() / "p115-extract-state.json"

# 空间类错误连本地解压也做不了，直接判失败
_SPACE_ERR_HINTS = ("空间", "容量", "已满")

_state_lock = threading.Lock()
_saved_at = 0.0

_state: dict[str, Any] = {
    "running": False,
    "stopped": False,
    "startedAt": 0.0,
    "finishedAt": 0.0,
    "folderCid": "0",
    "folderName": "",
    "scanning": False,
    "current": None,
    "items": [],
    "preview": None,
    "previewCid": "",
}


def work_root() -> Path:
    """本地下载/解压的工作目录。

    默认放在 `server/data/p115-extract/`，路径固定、可直接挂载或查看；
    需要换盘时设环境变量 `REXHUB_P115_EXTRACT_DIR` 指到目标目录即可。
    """
    raw = os.environ.get("REXHUB_P115_EXTRACT_DIR", "").strip()
    base = Path(raw) if raw else data_dir() / "p115-extract"
    base.mkdir(parents=True, exist_ok=True)
    return base


def _persist_locked(force: bool = False) -> None:
    """把队列/预览写入磁盘（调用方需持有 _state_lock）。"""
    global _saved_at
    now = time.time()
    if not force and now - _saved_at < SAVE_MIN_INTERVAL_S:
        return
    _saved_at = now
    payload = {
        "startedAt": _state.get("startedAt") or 0,
        "finishedAt": _state.get("finishedAt") or 0,
        "folderCid": _state.get("folderCid") or "0",
        "folderName": _state.get("folderName") or "",
        "items": list(_state["items"]),
        "preview": _state.get("preview"),
        "previewCid": _state.get("previewCid") or "",
    }
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        tmp.replace(STATE_PATH)
    except OSError as exc:
        log.warning("save extract state failed: %s", exc)


def _load_state() -> None:
    """启动时恢复上次的队列与扫描结果；上次中断的条目退回「等待解压」。"""
    try:
        raw = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    if not isinstance(raw, dict):
        return
    items = [it for it in raw.get("items") or [] if isinstance(it, dict)]
    for item in items:
        if item.get("state") == "running":
            item.update(
                {
                    "state": "queued",
                    "stage": "等待解压",
                    "message": "上次中断，重新开始后继续",
                    "percent": 0.0,
                }
            )
    preview = raw.get("preview")
    with _state_lock:
        _state.update(
            {
                "startedAt": raw.get("startedAt") or 0,
                "finishedAt": raw.get("finishedAt") or 0,
                "folderCid": str(raw.get("folderCid") or "0"),
                "folderName": str(raw.get("folderName") or ""),
                "items": items,
                "preview": preview if isinstance(preview, list) else None,
                "previewCid": str(raw.get("previewCid") or ""),
            }
        )


_load_state()


# ---------------------------------------------------------------------------
# 配置（沿用 P115 settings 的 extract 字段）
# ---------------------------------------------------------------------------

def get_config() -> dict[str, str]:
    raw = settings_store.get_setting(settings_store.P115_KEY) or {}
    ext = raw.get("extract") if isinstance(raw.get("extract"), dict) else {}
    return {
        "folderCid": str(ext.get("folder_cid") or ext.get("folderCid") or "0"),
        "folderName": str(ext.get("folder_name") or ext.get("folderName") or ""),
        "password": str(ext.get("password") or ""),
    }


def save_config(folder_cid: str, folder_name: str, password: str) -> dict[str, str]:
    settings_store.update_setting(
        settings_store.P115_KEY,
        lambda raw: {
            **raw,
            "extract": {
                "folder_cid": str(folder_cid or "0").strip() or "0",
                "folder_name": str(folder_name or "").strip(),
                "password": str(password or ""),
            },
        },
    )
    return get_config()


# ---------------------------------------------------------------------------
# 状态快照
# ---------------------------------------------------------------------------

def _public_item(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": str(item.get("id") or ""),
        "name": str(item.get("name") or ""),
        "size": int(item.get("size") or 0),
        "state": str(item.get("state") or "queued"),
        "stage": str(item.get("stage") or ""),
        "message": str(item.get("message") or ""),
        "attempts": int(item.get("attempts") or 0),
        "percent": float(item.get("percent") or 0),
        # 云端 / 本地通道：同一时刻两条通道各跑一个任务，界面需要标出是哪一个
        "lane": str(item.get("lane") or "cloud"),
        "phase": str(item.get("phase") or ""),
    }


def snapshot() -> dict[str, Any]:
    with _state_lock:
        items = list(_state["items"])
        current = _state.get("current")
        counts = {"total": len(items), "done": 0, "failed": 0, "waiting": 0, "queued": 0}
        for item in items:
            state = str(item.get("state") or "")
            if state == "done":
                counts["done"] += 1
            elif state == "failed":
                counts["failed"] += 1
            elif state == "waiting":
                counts["waiting"] += 1
            elif state in {"queued", "running"}:
                counts["queued"] += 1
        return {
            "running": bool(_state["running"]),
            "scanning": bool(_state.get("scanning")),
            "workDir": str(work_root()),
            "startedAt": _state.get("startedAt") or 0,
            "finishedAt": _state.get("finishedAt") or 0,
            "folderCid": _state.get("folderCid") or "0",
            "folderName": _state.get("folderName") or "",
            "current": _public_item(current) if isinstance(current, dict) else None,
            "items": [_public_item(item) for item in items],
            "counts": counts,
            "preview": _state.get("preview"),
            "previewCid": _state.get("previewCid") or "",
            "config": get_config(),
        }


def _set_item(item_id: str, **patch: Any) -> None:
    with _state_lock:
        for item in _state["items"]:
            if item.get("id") == item_id:
                item.update(patch)
                if _state.get("current") and _state["current"].get("id") == item_id:
                    _state["current"] = dict(item)
                _persist_locked()
                return


def _next_item_locked(lane: str) -> tuple[dict[str, Any] | None, float | None]:
    """按通道取下一个可执行条目；返回 (条目, 需要等待的秒数)。"""
    now = time.time()
    wait_until = 0.0
    # 通道里已经有条目在跑（解压轮询期间状态保持 running）：优先继续它，
    # 不然它会被后面的 queued 条目顶掉、永远停在「执行中」。
    for item in _state["items"]:
        if item.get("lane", "cloud") == lane and item.get("state") == "running":
            return dict(item), None
    for item in _state["items"]:
        if item.get("lane", "cloud") != lane:
            continue
        state = item.get("state")
        if state == "queued":
            item["state"] = "running"
            item["stage"] = "准备中"
            return dict(item), None
        if state == "waiting":
            next_at = float(item.get("nextAt") or 0)
            if next_at <= now:
                item["state"] = "running"
                item["stage"] = "重试中"
                return dict(item), None
            wait_until = next_at if not wait_until else min(wait_until, next_at)
    if wait_until:
        # 还有等待重试的任务：短暂休眠后再看，避免空转
        return None, max(1.0, min(30.0, wait_until - now))
    return None, None


def _defer(item_id: str, delay: float, stage: str, message: str, **extra: Any) -> None:
    """把任务退回队列并约定下次复查时间，云端先去处理别的任务。"""
    _set_item(
        item_id,
        state="waiting",
        stage=stage,
        message=message,
        nextAt=time.time() + max(1.0, delay),
        **extra,
    )


def _handoff_local(item_id: str, message: str) -> None:
    """云端这条路走不通：交给本地 worker，云端继续下一个任务。"""
    _set_item(
        item_id,
        lane="local",
        state="queued",
        stage="等待本地解压",
        percent=0.0,
        message=message,
        nextAt=0.0,
        phase="",
        extractId="",
        destCid="",
        pollAt=0.0,
        pollPct=0.0,
        readyTries=0,
        verifyTries=0,
        verifyReason="",
    )


def _retry_with_next_password(
    item_id: str,
    idx: int,
    passwords: list[str],
    reason: str,
) -> None:
    """本次密码在云端失败：换下一个候选密码重试，全部试完直接判失败。

    密码类失败不再转本地：本地同样要试同一批密码，白下载一遍；
    用户明确要求「兜底失败立即下一个」。
    """
    next_idx = idx + 1
    if next_idx >= len(passwords):
        _set_item(
            item_id,
            state="failed",
            stage="失败",
            message=f"{reason}，候选密码已全部失败，跳过（不转本地）",
        )
        return
    _set_item(
        item_id,
        state="queued",
        stage="等待解压",
        percent=0.0,
        nextAt=0.0,
        phase="",
        extractId="",
        destCid="",
        pollAt=0.0,
        pollPct=0.0,
        readyTries=0,
        verifyTries=0,
        verifyReason="",
        pwdIndex=next_idx,
        message=f"{reason}，换密码重试（还有 {len(passwords) - next_idx} 个）",
    )


def _cloud_unavailable(item_id: str, message: str) -> None:
    """115 明确拒绝的错误：不再退避重试，空间类直接失败，其余交本地。"""
    msg = str(message or "")
    if any(hint in msg for hint in _SPACE_ERR_HINTS):
        _set_item(item_id, state="failed", stage="失败", message=msg)
        return
    _handoff_local(item_id, msg)
