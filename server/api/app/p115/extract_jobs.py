"""115 网盘压缩包解压任务：单例串行队列。

一次只处理一个压缩包：先走 115 云端解压，解压产物不小于原文件时删除原文件；
小于原文件（或云端不可用）时，下载原文件到本地解压、上传产物后再删除原文件。
云端还需后台准备时（unzipStatus 未就绪），先跳过，过一段时间再重试。
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

import httpx

import app.core.settings_store as settings_store
import app.p115.extract as p115_extract
from app.core.db import data_dir
from app.p115.client import normalize_cookie
from app.rexhub import pan115

log = logging.getLogger("p115-extract-jobs")

ARCHIVE_RE = re.compile(r"\.(zip|rar|7z)$", re.I)
# 转存时写在文件夹 / 压缩包名里的密码标记：xxx [密码 abc] / xxx【密码:abc】（兼容旧标记）
PASSWORD_TAG_RE = re.compile(
    r"(?:【\s*(?:解压)?密码\s*[:：]\s*([^】]*?)\s*】|\[\s*密码\s*[:：]?\s*([^\]]*?)\s*\])"
)
# 云端是两段式：先 push 让 115 后台预解析，就绪后再提交一次才真正解压到网盘。
# 预解析阶段没有产物，只能查 unzip_status
CLOUD_READY_BACKOFF_S = (120.0, 300.0, 600.0)
# 预解析还没就绪（115 还在服务器端解压）：固定等 10 分钟再来看，期间继续别的任务
CLOUD_READY_WAIT_S = 600.0
CLOUD_READY_MAX_TRIES = 12
CLOUD_READY_MAX_S = 2 * 3600.0
# 提交解压后固定每 10 秒看一次百分比
CLOUD_EXTRACT_POLL_S = 10.0
CLOUD_EXTRACT_FIRST_S = CLOUD_EXTRACT_POLL_S
CLOUD_EXTRACT_DEADLINE_S = 30 * 60.0
# 一直在推进的任务不受上面 30 分钟限制，但也不能无限等：给一个绝对上限
CLOUD_EXTRACT_HARD_DEADLINE_S = 6 * 3600.0
# 百分比连续 15 分钟没有任何变化才算停滞（10 秒采一次，不能用次数计）
CLOUD_STALL_LIMIT_S = 15 * 60.0
# 产物与原文件大小的允许误差：压缩包头/填充等会造成少量差异，
# 相差在这个比例内视为解压成功，避免误走“下载到本地解压”的路径。
SIZE_TOLERANCE = 0.02
# 115 云解压官方限制：单个压缩包不得超过 20GB
CLOUD_MAX_ARCHIVE_BYTES = 20 * 1024**3
# 进度到 100% 后产物可能还在沉降：首次核对不达标时等一会再量一次
CLOUD_VERIFY_SETTLE_S = 30.0
LOCAL_DIR = "local-extract"


def work_root() -> Path:
    """本地下载/解压的工作目录。

    默认放在 `server/data/p115-extract/`，路径固定、可直接挂载或查看；
    需要换盘时设环境变量 `REXHUB_P115_EXTRACT_DIR` 指到目标目录即可。
    """
    raw = os.environ.get("REXHUB_P115_EXTRACT_DIR", "").strip()
    base = Path(raw) if raw else data_dir() / "p115-extract"
    base.mkdir(parents=True, exist_ok=True)
    return base


# 色花堂资源最常见的解压密码（按出现频次排序，来自 resource_sources.extract_password 统计）。
# 用户配置的密码优先，其余作为兜底逐个尝试（最后再试无密码）。
DEFAULT_PASSWORDS: tuple[str, ...] = (
    "1998@www.98t.la",
    "www.98t.la@",
    "1314",
    "www.98t.la@8858",
    "www.98t.la",
    "teenmegaworld@sehuatang",
    "sehuatang",
    "www.98t.la@1",
    "1024",
    "98tang",
)

# 115 返回这些字样时判定为“密码不对”，换下一个候选密码而不是等待重试
_PASSWORD_ERR_HINTS = (
    "密码错误",
    "密码不正确",
    "密码无效",
    "密码有误",
    "请输入密码",
    "需要密码",
    "密码不能为空",
)


def _is_password_error(message: str) -> bool:
    msg = str(message or "")
    return any(hint in msg for hint in _PASSWORD_ERR_HINTS)


# 115 明确拒绝（非会员 / 无权限 / 超限 / 格式不支持 / 任务不存在）：
# 这类错误重试多少次都没用，别白等十几轮退避。
_FATAL_CLOUD_HINTS = (
    "会员",
    "vip",
    "权限",
    "空间",
    "容量",
    "超过",
    "不支持",
    "格式",
    "不存在",
    "找不到",
)
# 空间类错误连本地解压也做不了，直接判失败
_SPACE_ERR_HINTS = ("空间", "容量", "已满")


def _is_fatal_cloud_error(message: str) -> bool:
    msg = str(message or "").lower()
    return any(hint in msg for hint in _FATAL_CLOUD_HINTS)


def _password_tag(name: str) -> str:
    """从文件夹 / 压缩包名里取出密码标记（兼容【密码:xxx】与 [密码 xxx]）。"""
    m = PASSWORD_TAG_RE.search(str(name or ""))
    return (m.group(1) or m.group(2) or "").strip() if m else ""


def candidate_passwords(configured: str, preferred: str = "") -> list[str]:
    """密码顺序：压缩包名字里的密码 → 配置密码 → 空密码 → 兜底密码。

    名字里带【密码:xxx】时先试它；名字没带密码时按配置来：
    配了密码就先试配置的，再试空密码，最后才用常见密码兜底。
    115 的 push_extract 是同步判定密码的：密码不对会直接返回
    unzip_status=6 或 errno，不会等后台解压再报错，所以多试一次很便宜。
    """
    configured = str(configured or "").strip()
    preferred = str(preferred or "").strip()
    order: list[str] = []
    if preferred:
        order.append(preferred)
    if configured:
        order.append(configured)
    order.append("")
    order.extend(DEFAULT_PASSWORDS)
    out: list[str] = []
    seen: set[str] = set()
    for pwd in order:
        key = pwd.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(pwd)
    return out


def _pwd_note(password: str) -> str:
    return f"，密码 {password}" if password else ""


def _pwd_fail_reason(passwords: list[str], idx: int) -> str:
    """空密码失败 => 包确实加密了；其它候选失败 => 就是密码不对。"""
    if 0 <= idx < len(passwords) and not passwords[idx]:
        return "该压缩包需要密码"
    return "115 云解压失败（密码可能不对）"


_state_lock = threading.Lock()
_worker: threading.Thread | None = None
# 队列与扫描结果落盘，刷新页面/重启服务后还能看到上次进度
STATE_PATH = data_dir() / "p115-extract-state.json"
# 进度更新很频繁，落盘做节流；关键节点强制写
SAVE_MIN_INTERVAL_S = 1.0
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
    raw = settings_store.get_setting(settings_store.P115_KEY) or {}
    value = {
        **raw,
        "extract": {
            "folder_cid": str(folder_cid or "0").strip() or "0",
            "folder_name": str(folder_name or "").strip(),
            "password": str(password or ""),
        },
    }
    settings_store.put_setting(settings_store.P115_KEY, value)
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


def preview(folder_cid: str = "") -> dict[str, Any]:
    """扫描指定目录，返回待解压的压缩包清单（不启动队列）。

    一次扫描即新建一批任务：旧批次的进度直接丢弃，列表只反映本次扫描结果。
    """
    cookie = pan115.cookie_string()
    if not cookie:
        raise RuntimeError("尚未登录 115，请先在概览页扫码或粘贴 Cookie")
    config = get_config()
    cid = str(folder_cid or "").strip() or config["folderCid"]
    with httpx.Client(timeout=60.0, follow_redirects=True, trust_env=False) as client:
        items = _scan_items(client, cookie, cid)
    public = [_public_item(item) for item in items]
    with _state_lock:
        _state.update(
            {
                "startedAt": time.time(),
                "finishedAt": 0.0,
                "folderCid": cid,
                "folderName": config["folderName"] if cid == config["folderCid"] else "",
                "current": None,
                "items": items,
                "preview": public,
                "previewCid": cid,
            }
        )
        _persist_locked(force=True)
    return {"folderCid": cid, "items": public}


def _set_item(item_id: str, **patch: Any) -> None:
    with _state_lock:
        for item in _state["items"]:
            if item.get("id") == item_id:
                item.update(patch)
                if _state.get("current") and _state["current"].get("id") == item_id:
                    _state["current"] = dict(item)
                _persist_locked()
                return


# ---------------------------------------------------------------------------
# 队列控制
# ---------------------------------------------------------------------------

def start() -> dict[str, Any]:
    global _worker
    with _state_lock:
        already_running = bool(_state["running"])
    if already_running:
        return snapshot()
    with _state_lock:
        cookie = pan115.cookie_string()
        if not cookie:
            raise RuntimeError("尚未登录 115，请先在概览页扫码或粘贴 Cookie")
        config = get_config()
        # 已扫描过且还有待处理的条目：直接跑这份清单，扫描一次即一批任务
        reuse = any(
            item.get("state") in {"queued", "waiting"} for item in _state["items"]
        ) and str(_state.get("folderCid") or "0") == str(config["folderCid"] or "0")
        _state.update(
            {
                "running": True,
                "stopped": False,
                "startedAt": time.time(),
                "finishedAt": 0.0,
                "folderCid": config["folderCid"],
                "folderName": config["folderName"],
                "scanning": not reuse,
                "current": None,
            }
        )
        if not reuse:
            _state["items"] = []
        _persist_locked(force=True)
        _worker = threading.Thread(
            target=_run,
            args=(cookie, config, reuse),
            name="p115-extract-worker",
            daemon=True,
        )
        _worker.start()
    return snapshot()


def stop() -> dict[str, Any]:
    with _state_lock:
        _state["stopped"] = True
        for item in _state["items"]:
            if item.get("state") in {"queued", "waiting", "running"}:
                item.update({"state": "failed", "stage": "已停止", "message": "任务已手动停止"})
        _state["running"] = False
        _persist_locked(force=True)
    return snapshot()


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

def _run(cookie: str, config: dict[str, str], reuse: bool = False) -> None:
    try:
        with httpx.Client(timeout=60.0, follow_redirects=True, trust_env=False) as client:
            if reuse:
                with _state_lock:
                    _state["scanning"] = False
                    _persist_locked(force=True)
            else:
                items = _scan_items(client, cookie, config["folderCid"])
                with _state_lock:
                    _state["items"] = items
                    _state["scanning"] = False
                    _persist_locked(force=True)
            # 云端 worker 串行跑云端解压；发现异常交给本地 worker，云端继续下一个
            cloud_done = threading.Event()
            cloud = threading.Thread(
                target=_cloud_worker,
                args=(client, cookie, config, cloud_done),
                name="p115-extract-cloud",
                daemon=True,
            )
            local = threading.Thread(
                target=_local_worker,
                args=(client, cookie, config, cloud_done),
                name="p115-extract-local",
                daemon=True,
            )
            cloud.start()
            local.start()
            cloud.join()
            local.join()
    except Exception as exc:  # noqa: BLE001 - 后台线程兜底
        log.exception("extract worker crashed")
        with _state_lock:
            _state["items"].append(
                {
                    "id": f"error:{int(time.time())}",
                    "name": "任务异常",
                    "size": 0,
                    "state": "failed",
                    "stage": "失败",
                    "message": str(exc) or "解压任务异常",
                    "attempts": 0,
                    "percent": 0,
                }
            )
    finally:
        with _state_lock:
            _state["running"] = False
            _state["scanning"] = False
            _state["finishedAt"] = time.time()
            _state["current"] = None
            _persist_locked(force=True)


def _cloud_worker(
    client: httpx.Client,
    cookie: str,
    config: dict[str, str],
    done: threading.Event,
) -> None:
    try:
        while True:
            with _state_lock:
                if _state["stopped"]:
                    break
                item, wait_delay = _next_item_locked("cloud")
                if item is not None:
                    _state["current"] = dict(item)
            if item is None:
                if wait_delay is None:
                    break
                time.sleep(wait_delay)
                continue
            _process_one(client, cookie, config["password"], item)
    except Exception:  # noqa: BLE001 - 交给外层兜底
        log.exception("cloud worker crashed")
        raise
    finally:
        done.set()


def _local_worker(
    client: httpx.Client,
    cookie: str,
    config: dict[str, str],
    done: threading.Event,
) -> None:
    while True:
        with _state_lock:
            if _state["stopped"]:
                break
            item, wait_delay = _next_item_locked("local")
        if item is None:
            if wait_delay is not None:
                time.sleep(wait_delay)
                continue
            # 云端还没收尾：等它继续交接任务
            if not done.is_set():
                time.sleep(1.0)
                continue
            with _state_lock:
                pending = any(
                    row.get("lane") == "local"
                    and row.get("state") in {"queued", "waiting"}
                    for row in _state["items"]
                )
            if pending:
                continue
            break
        try:
            _local_fallback(
                client,
                cookie,
                candidate_passwords(config["password"], item.get("pwd") or ""),
                item,
            )
        except Exception as exc:  # noqa: BLE001
            log.exception("local fallback failed: %s", item.get("name"))
            _set_item(
                str(item.get("id")),
                state="failed",
                stage="失败",
                message=str(exc) or "本地解压失败",
            )



def _build_items(rows: list[Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict) or row.get("ns") or not row.get("fid"):
            continue
        name = str(row.get("n") or row.get("name") or "").strip()
        pick = str(row.get("pc") or row.get("pick_code") or "").strip()
        if not name or not pick or not ARCHIVE_RE.search(name):
            continue
        size = int(row.get("s") or 0)
        # 密码来源：转存时直接写在压缩包标题上的【密码:xxx】
        pwd = _password_tag(name)
        if p115_extract._is_multipart_archive(name):
            items.append(
                {
                    "id": str(row.get("fid")),
                    "name": name,
                    "pickCode": pick,
                    "fid": str(row.get("fid")),
                    "size": size,
                    "state": "failed",
                    "stage": "跳过",
                    "lane": "cloud",
                    "message": "分卷压缩包不支持解压",
                    "attempts": 0,
                    "percent": 0,
                    "pwd": pwd,
                }
            )
            continue
        if size > CLOUD_MAX_ARCHIVE_BYTES:
            # 115 云解压硬上限 20GB：超过的直接走本地，别先推云端再失败
            items.append(
                {
                    "id": str(row.get("fid")),
                    "name": name,
                    "pickCode": pick,
                    "fid": str(row.get("fid")),
                    "size": size,
                    "state": "queued",
                    "stage": "等待本地解压",
                    "lane": "local",
                    "message": "超过 115 云解压 20GB 上限，改为本地解压",
                    "attempts": 0,
                    "nextAt": 0.0,
                    "percent": 0,
                    "pwd": pwd,
                }
            )
            continue
        items.append(
            {
                "id": str(row.get("fid")),
                "name": name,
                "pickCode": pick,
                "fid": str(row.get("fid")),
                "size": size,
                "state": "queued",
                "stage": "待解压",
                "lane": "cloud",
                "message": "",
                "attempts": 0,
                "nextAt": 0.0,
                "percent": 0,
                "pwd": pwd,
                "parent": parent,
            }
        )
    return items


def _scan_items(
    client: httpx.Client,
    cookie: str,
    folder_cid: str,
) -> list[dict[str, Any]]:
    """扫描待解压压缩包：只看目标目录第一层，不进子文件夹。"""
    rows = p115_extract._list_folder_files_all(client, cookie, folder_cid)
    return _build_items(rows)


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


def _drop_cloud_folder(dest_cid: str) -> None:
    if not dest_cid:
        return
    try:
        pan115.delete_items([dest_cid])
    except Exception as err:  # noqa: BLE001
        log.warning("delete cloud extract folder %s failed: %s", dest_cid, err)


def _process_one(
    client: httpx.Client,
    cookie: str,
    password: str,
    item: dict[str, Any],
) -> None:
    """云端通道推进一步后立刻返回，真正的等待交给 nextAt 调度。"""
    item_id = str(item["id"])
    name = str(item["name"])
    try:
        phase = str(item.get("phase") or "")
        if phase == "extract":
            _cloud_extract_step(client, cookie, password, item)
        elif phase == "verify":
            _cloud_verify(
                item,
                candidate_passwords(password, item.get("pwd") or ""),
                max(0, int(item.get("pwdIndex") or 0)),
                reason=str(item.get("verifyReason") or "complete"),
            )
        else:
            _cloud_prepare_step(client, cookie, password, item)
    except httpx.HTTPError as exc:
        # 网络抖动不算失败：稍后重试，别把整条任务判死
        log.warning("extract item %s network error: %s", name, exc)
        delay = CLOUD_READY_BACKOFF_S[0]
        _defer(item_id, delay, "等待重试", f"网络异常，稍后重试：{exc}")
    except Exception as exc:  # noqa: BLE001
        log.exception("extract item %s failed", name)
        _set_item(item_id, state="failed", stage="失败", message=str(exc) or "解压失败")


def _cloud_prepare_step(
    client: httpx.Client,
    cookie: str,
    password: str,
    item: dict[str, Any],
) -> None:
    """阶段一：推送云解压（115 后台预解析）→ 就绪后提交解压。

    115 的预解析和真正解压是两步：预解析完成只代表能读目录，
    必须再提交一次 add_extract_file 才会往网盘里写文件。
    """
    item_id = str(item["id"])
    name = str(item["name"])
    pick = str(item["pickCode"])
    now = time.time()
    passwords = candidate_passwords(password, item.get("pwd") or "")
    idx = max(0, int(item.get("pwdIndex") or 0))
    if idx >= len(passwords):
        _set_item(
            item_id,
            state="failed",
            stage="失败",
            message="所有候选密码在云端均未通过，跳过（不转本地）",
        )
        return

    if str(item.get("phase") or "") != "prepare":
        # 115 云解压是会员专属：非会员直接走本地，省掉十几轮无意义的退避
        snap = pan115.snapshot()
        if (
            snap.get("bound")
            and snap.get("checked_at")
            and snap.get("status") == "ok"
            and not snap.get("vip_active")
        ):
            _handoff_local(item_id, "115 云解压仅会员可用（当前账号未开通），改为本地解压")
            return
        # 首次（或换密码后）：推送一次，让 115 在服务端预解析
        _set_item(item_id, stage="云端准备中", percent=0.0, message="")
        status = -1
        while idx < len(passwords):
            push = p115_extract._push_extract(client, cookie, pick, passwords[idx])
            if push.get("ok"):
                try:
                    status = int(push.get("unzipStatus"))
                except (TypeError, ValueError):
                    status = -1
                break
            message = str(push.get("message") or "推送云解压失败")
            if not _is_password_error(message):
                if _is_fatal_cloud_error(message):
                    _cloud_unavailable(item_id, message)
                    return
                tries = int(item.get("readyTries") or 0) + 1
                if tries > CLOUD_READY_MAX_TRIES:
                    _handoff_local(item_id, f"云端持续无法开始预解析：{message}")
                    return
                delay = CLOUD_READY_BACKOFF_S[
                    min(tries - 1, len(CLOUD_READY_BACKOFF_S) - 1)
                ]
                _defer(item_id, delay, "等待云端准备", message, readyTries=tries)
                return
            log.info("cloud rejected password %r for %s", passwords[idx], name)
            idx += 1
        if idx >= len(passwords):
            _set_item(
                item_id,
                state="failed",
                stage="失败",
                message="云端拒绝了所有候选密码，跳过（不转本地）",
            )
            return
        _set_item(item_id, pwdIndex=idx, phase="prepare", pushAt=now, readyTries=0)
        if status == 6:
            # 6 = 预解析失败（多为密码不对），不能当成就绪继续提交
            log.info("cloud pre-parse failed status=6 for %s", name)
            _retry_with_next_password(item_id, idx, passwords, _pwd_fail_reason(passwords, idx))
            return
        if status != 4:
            _defer(
                item_id,
                CLOUD_READY_WAIT_S,
                "等待云端准备",
                "115 还在后台预解析，10 分钟后复查",
                phase="prepare",
                pwdIndex=idx,
                pushAt=now,
            )
            return
    else:
        # 已经推送过：只查状态，绝不重复推送
        _set_item(item_id, stage="云端准备中")
        prog = p115_extract._read_push_progress(client, cookie, pick)
        try:
            status = int(prog.get("unzipStatus"))
        except (TypeError, ValueError):
            status = -1
        if status == 6:
            log.info("cloud pre-parse failed status=6 for %s", name)
            _retry_with_next_password(item_id, idx, passwords, _pwd_fail_reason(passwords, idx))
            return
        if status != 4:
            tries = int(item.get("readyTries") or 0) + 1
            pushed_at = float(item.get("pushAt") or now)
            if tries > CLOUD_READY_MAX_TRIES or now - pushed_at > CLOUD_READY_MAX_S:
                _handoff_local(item_id, "云端长时间未完成预解析，改用本地解压")
                return
            _defer(
                item_id,
                CLOUD_READY_WAIT_S,
                "等待云端准备",
                "115 还在后台预解析，10 分钟后复查",
                readyTries=tries,
            )
            return

    # 预解析就绪：读目录并提交解压（这一步才真正开始往网盘写）
    info = p115_extract._extract_info_all(client, cookie, pick)
    # 条目太多翻不完：改用空列表，让 115 按“解压全部”处理
    truncated = bool(info.get("truncated"))
    files = [] if truncated else list(info.get("files") or [])
    dirs = [] if truncated else list(info.get("dirs") or [])
    if truncated:
        log.info("extract listing truncated for %s, fallback to extract-all", name)
    elif not files and not dirs:
        message = str(info.get("message") or "")
        if not message or _is_password_error(message):
            # 没有解析出条目、也没有明确原因：多半是密码不对，换下一个候选
            log.info("cloud empty listing, try next password for %s", name)
            _retry_with_next_password(item_id, idx, passwords, "云端未解析出文件（密码可能不对）")
            return
        if _is_fatal_cloud_error(message):
            _cloud_unavailable(item_id, message)
            return
        tries = int(item.get("readyTries") or 0) + 1
        if tries > CLOUD_READY_MAX_TRIES:
            _handoff_local(item_id, message)
            return
        delay = CLOUD_READY_BACKOFF_S[min(tries - 1, len(CLOUD_READY_BACKOFF_S) - 1)]
        _defer(item_id, delay, "等待云端准备", message, readyTries=tries)
        return

    dest_name = p115_extract._same_name_folder_label(name)
    dest = _ensure_target_folder(client, cookie, get_config()["folderCid"], dest_name)
    if not dest.get("ok"):
        message = str(dest.get("message") or "创建解压目录失败")
        if _is_fatal_cloud_error(message):
            _cloud_unavailable(item_id, message)
            return
        tries = int(item.get("readyTries") or 0) + 1
        if tries > CLOUD_READY_MAX_TRIES:
            _handoff_local(item_id, message)
            return
        delay = CLOUD_READY_BACKOFF_S[min(tries - 1, len(CLOUD_READY_BACKOFF_S) - 1)]
        _defer(item_id, delay, "等待云端准备", message, readyTries=tries)
        return
    dest_cid = str(dest.get("cid") or "")
    if not truncated:
        # 同名文件直接覆盖：先删掉目标目录里与压缩包顶层同名的条目
        _overwrite_targets(dest_cid, [*files, *dirs])

    add = p115_extract._add_extract_file(client, cookie, pick, dest_cid, files, dirs)
    if not add.get("ok"):
        message = str(add.get("message") or "提交解压失败")
        if _is_password_error(message):
            _retry_with_next_password(item_id, idx, passwords, "云端拒绝该密码")
            return
        if _is_fatal_cloud_error(message):
            _cloud_unavailable(item_id, message)
            return
        tries = int(item.get("readyTries") or 0) + 1
        if tries > CLOUD_READY_MAX_TRIES:
            _handoff_local(item_id, message)
            return
        delay = CLOUD_READY_BACKOFF_S[min(tries - 1, len(CLOUD_READY_BACKOFF_S) - 1)]
        _defer(item_id, delay, "等待云端准备", message, readyTries=tries)
        return

    # 解压已提交：本轮原地等 10 秒再看进度。状态保持 running（正在解压），
    # 否则「正在解压」和「排队等待」在列表里长得一模一样。
    _set_item(
        item_id,
        state="running",
        stage="云端解压中",
        message="已提交解压，正在等待 115 返回进度",
        phase="extract",
        extractId=str(add.get("extractId") or ""),
        destCid=dest_cid,
        submittedAt=now,
        pollAt=0.0,
        pollPct=0.0,
        readyTries=0,
        verifyTries=0,
        pwdIndex=idx,
    )
    time.sleep(CLOUD_EXTRACT_FIRST_S)


def _cloud_extract_step(
    client: httpx.Client,
    cookie: str,
    password: str,
    item: dict[str, Any],
) -> None:
    """阶段二：固定每 10 秒查一次解压百分比，到 100% 就实测产物大小。"""
    item_id = str(item["id"])
    name = str(item["name"])
    now = time.time()
    target = int(item.get("size") or 0)
    dest_cid = str(item.get("destCid") or "")
    submitted = float(item.get("submittedAt") or now)
    passwords = candidate_passwords(password, item.get("pwd") or "")
    idx = max(0, int(item.get("pwdIndex") or 0))

    _set_item(item_id, stage="云端解压中")
    prog = p115_extract.extract_progress_once(
        client, cookie, str(item.get("extractId") or "")
    )
    if not prog.get("ok"):
        message = str(prog.get("message") or "查询解压进度失败")
        if _is_fatal_cloud_error(message):
            _cloud_unavailable(item_id, message)
            return
        tries = int(item.get("readyTries") or 0) + 1
        if tries > CLOUD_READY_MAX_TRIES:
            # 进度一直查不到也总有个头：核对产物，产物不够就交本地
            _cloud_verify(item, passwords, idx, reason="timeout")
            return
        delay = CLOUD_READY_BACKOFF_S[min(tries - 1, len(CLOUD_READY_BACKOFF_S) - 1)]
        _defer(
            item_id,
            delay,
            "进度查询失败",
            message,
            readyTries=tries,
        )
        return
    _set_item(item_id, readyTries=0)

    # 115 的 unzip_status：0 未解压 / 1 解压中 / 4 解压成功 / 6 解压失败。
    # 6 是明确失败信号，不必再等 stall 或 30 分钟超时，直接换密码。
    status = int(prog.get("unzipStatus") or -1)
    if status == 6:
        log.info("cloud unzip_status=6 for %s", name)
        _retry_with_next_password(item_id, idx, passwords, _pwd_fail_reason(passwords, idx))
        return

    prev_at = float(item.get("pollAt") or 0)
    prev_ratio = max(0.0, float(item.get("pollPct") or 0)) / 100.0

    ratio: float | None = None
    measured: int | None = None
    if prog.get("percent") is not None:
        ratio = float(prog["percent"]) / 100.0
    elif prog.get("bytes") is not None and target > 0:
        ratio = float(prog["bytes"]) / target
    if prog.get("done"):
        ratio = 1.0
    # 115 完成后进度字段会直接消失（percent/bytes 都为 None），
    # 这时只能量目录大小来判断；不能沿用上次的 99.x%，否则永远等不到 100%。
    if ratio is None and status == 1:
        # 115 明确回报“仍在服务器端解压”：固定 10 分钟后再看，不占队列、不量目录
        if now - submitted >= CLOUD_EXTRACT_DEADLINE_S:
            log.info("cloud extract still status=1 after deadline for %s", name)
            _cloud_verify(item, passwords, idx, reason="timeout")
            return
        _defer(
            item_id,
            CLOUD_READY_WAIT_S,
            "等待云端解压",
            "115 仍在服务器端解压，10 分钟后复查",
        )
        return
    if ratio is None and dest_cid and target > 0:
        measured = _folder_size(dest_cid)
        ratio = measured / target
    if ratio is None:
        ratio = prev_ratio
    ratio = max(0.0, min(1.0, ratio))

    if measured is not None:
        # 目录实测：压缩包头/填充等差异落在容差内即视为解压完成
        if measured >= target * (1.0 - SIZE_TOLERANCE):
            _cloud_verify(item, passwords, idx, out_size=measured)
            return
    elif ratio >= 1.0:
        _cloud_verify(item, passwords, idx)
        return

    elapsed = now - submitted
    if elapsed >= CLOUD_EXTRACT_HARD_DEADLINE_S:
        # 一直在推进也总有个头：超过上限就核对产物，别再占着队列
        log.info("cloud extract exceeded hard deadline for %s", name)
        _cloud_verify(item, passwords, idx, reason="timeout")
        return

    # 百分比有变化（含首次采样、回退）就重置停滞计时；10 秒一次采样不能用次数算停滞
    changed = prev_at <= 0 or abs(ratio - prev_ratio) > 1e-4
    poll_at = now if changed else prev_at
    if not changed and now - poll_at >= CLOUD_STALL_LIMIT_S:
        log.info("cloud extract stalled for %s (%.0f%%, %.0fs)", name, ratio * 100, elapsed)
        _cloud_verify(item, passwords, idx, reason="stalled")
        return

    pct_text = int(ratio * 100)
    if ratio <= 0:
        stage, message = "等待重试", "暂未产生解压产物，115 可能还在后台处理"
    elif changed and ratio > prev_ratio:
        stage, message = f"云端解压中 {pct_text}%", f"已解压 {pct_text}%"
    else:
        stage, message = f"云端解压中 {pct_text}%", f"已解压 {pct_text}%，进度暂未变化"
    # 10 秒一次的轮询就是「正在解压」本身：保持 running 并原地等下一轮，
    # 不能再退回 waiting，否则列表里正在解压和排队等待的任务分不出来。
    _set_item(
        item_id,
        state="running",
        stage=stage,
        message=message,
        percent=ratio * 100.0,
        pollAt=poll_at,
        pollPct=ratio * 100.0,
    )
    time.sleep(CLOUD_EXTRACT_POLL_S)


_VERIFY_REASON_TEXT = {
    "complete": "进度已到 100%",
    "timeout": "等待超时",
    "stalled": "长时间无进展",
    "empty": "未产生产物",
}


def _cloud_verify(
    item: dict[str, Any],
    passwords: list[str],
    idx: int,
    out_size: int | None = None,
    *,
    reason: str = "complete",
) -> None:
    """核对云解压产物，按「密码问题」和「产物问题」分开处理。

    - 达标：删原包，任务完成
    - 零产物：更像密码没生效（115 偶尔不回 unzip_status=6），还有候选就换密码，
      候选用完直接判失败，不下载到本地
    - 有产物但偏小：云解压不完整，不是密码问题（密码错不会解出文件）。
      先等 30 秒沉降复核，仍不达标就交本地，绝不删产物换密码。
    """
    item_id = str(item["id"])
    name = str(item.get("name") or "")
    target = int(item.get("size") or 0)
    dest_cid = str(item.get("destCid") or "")
    if out_size is None:
        out_size = _folder_size(dest_cid)
    if _size_ok(out_size, target):
        try:
            pan115.delete_items([str(item["fid"])])
        except Exception as err:  # noqa: BLE001
            log.warning("delete original %s failed: %s", item["fid"], err)
        pwd = passwords[idx] if idx < len(passwords) else ""
        _set_item(
            item_id,
            state="done",
            stage="完成",
            percent=100.0,
            nextAt=0.0,
            phase="",
            extractId="",
            destCid="",
            pollAt=0.0,
            pollPct=0.0,
            message=f"云端解压完成（{_fmt_size(out_size)}），已删除原文件{_pwd_note(pwd)}",
        )
        return

    # 不达标：可能刚跑完还在沉降（产物还没落地），先复核一次再定性
    if not item.get("verifyTries"):
        log.info(
            "cloud output size mismatch for %s (%s/%s), recheck later",
            name,
            out_size,
            target,
        )
        detail = (
            "产物尚未落地"
            if out_size <= 0
            else f"产物 {_fmt_size(out_size)} 小于原文件 {_fmt_size(target)}"
        )
        _defer(
            item_id,
            CLOUD_VERIFY_SETTLE_S,
            "核对产物",
            f"{detail}，稍后复核",
            phase="verify",
            verifyTries=1,
            verifyReason=reason,
        )
        return

    if out_size <= 0:
        # 超时说明 115 自己还报「解压中」，不能当密码错把正确密码换掉：交本地重解
        if reason == "timeout":
            log.info("cloud produced nothing after timeout for %s, handoff to local", name)
            _handoff_local(item_id, "云端长时间未产出文件（115 仍显示解压中），改用本地解压")
            return
        if idx + 1 < len(passwords):
            log.info("cloud produced nothing for %s, try next password", name)
            _retry_with_next_password(
                item_id, idx, passwords, "云端未产生解压产物（密码可能不对）"
            )
            return
        _set_item(
            item_id,
            state="failed",
            stage="失败",
            message="云端未产生解压产物，候选密码已全部失败，跳过（不转本地）",
        )
        return

    # 复核仍偏小：云解压不完整，交本地重解，不消耗密码候选
    log.info(
        "cloud output short for %s (%s/%s), handoff to local",
        name,
        out_size,
        target,
    )
    _drop_cloud_folder(dest_cid)
    _handoff_local(
        item_id,
        f"云端产物 {_fmt_size(out_size)} 小于原文件 {_fmt_size(target)}"
        f"（{_VERIFY_REASON_TEXT.get(reason, reason)}），改用本地解压",
    )


# ---------------------------------------------------------------------------
# 同名覆盖：云端解压与本地兜底都先删旧条目再写入
# ---------------------------------------------------------------------------

def _list_children(cid: str) -> list[dict[str, Any]]:
    """列出目录下一层的全部条目（翻页拉全）。"""
    if not cid:
        return []
    rows: list[dict[str, Any]] = []
    offset = 0
    while True:
        data = pan115.list_files(cid, offset, 200)
        items = data.get("items") or []
        rows.extend(items)
        if len(items) < 200:
            break
        offset += 200
    return rows


def _ensure_target_folder(
    client: httpx.Client,
    cookie: str,
    parent_cid: str,
    folder_name: str,
) -> dict[str, Any]:
    """优先复用同名目录，没有才新建，避免每次解压都多出一个文件夹。"""
    for row in _list_children(parent_cid):
        if row.get("is_dir") and str(row.get("name") or "") == folder_name:
            return {"ok": True, "cid": str(row.get("id") or "")}
    return p115_extract._ensure_same_name_folder(client, cookie, parent_cid, folder_name)


def _top_level_names(paths: list[str]) -> set[str]:
    names: set[str] = set()
    for raw in paths:
        text = str(raw or "").strip().strip("/")
        if text:
            names.add(text.split("/")[0])
    return names


def _overwrite_targets(dest_cid: str, paths: list[str]) -> None:
    """目标目录里已有同名条目时先删除，解压产物直接覆盖。"""
    names = _top_level_names(paths)
    if not dest_cid or not names:
        return
    victims = [
        str(row.get("id"))
        for row in _list_children(dest_cid)
        if str(row.get("name") or "") in names
    ]
    if not victims:
        return
    try:
        pan115.delete_items(victims)
    except Exception as err:  # noqa: BLE001
        log.warning("overwrite existing entries in %s failed: %s", dest_cid, err)


# ---------------------------------------------------------------------------
# 本地兜底：下载 → 解压 → 上传 → 删除原文件
# ---------------------------------------------------------------------------

def _local_fallback(
    client: httpx.Client,
    cookie: str,
    passwords: list[str],
    item: dict[str, Any],
) -> None:
    item_id = str(item["id"])
    name = str(item["name"])
    size = int(item.get("size") or 0)
    config = get_config()
    folder_cid = config["folderCid"]

    workdir = Path(tempfile.mkdtemp(prefix="item-", dir=str(work_root())))
    try:
        archive_path = workdir / _safe_name(name)
        _set_item(item_id, stage="下载原文件", percent=0.0)
        _download(client, str(item["pickCode"]), archive_path, lambda pct: _set_item(item_id, percent=pct))

        out_dir = workdir / "out"
        last_err = ""
        for pwd in passwords:
            _set_item(item_id, stage="本地解压", percent=0.0, message="")
            shutil.rmtree(out_dir, ignore_errors=True)
            out_dir.mkdir(parents=True, exist_ok=True)
            try:
                _extract_archive(archive_path, out_dir, pwd)
            except Exception as exc:  # noqa: BLE001
                last_err = str(exc) or "解压失败"
                log.info("local password %r failed for %s: %s", pwd, name, last_err)
                continue

            out_size = _dir_size(out_dir)
            if not _size_ok(out_size, size):
                last_err = (
                    f"本地解压产物 {_fmt_size(out_size)} 小于原文件 {_fmt_size(size)}"
                )
                continue

            _set_item(item_id, stage="上传解压文件", percent=0.0)
            dest = _ensure_target_folder(
                client,
                cookie,
                folder_cid,
                p115_extract._same_name_folder_label(name),
            )
            if not dest.get("ok"):
                _set_item(
                    item_id,
                    state="failed",
                    stage="失败",
                    message=f"创建同名文件夹失败：{dest.get('message') or '未知错误'}",
                )
                return
            dest_cid = str(dest.get("cid") or folder_cid)
            _upload_tree(client, cookie, out_dir, dest_cid, item_id)
            pan115.delete_items([str(item["fid"])])
            _set_item(
                item_id,
                state="done",
                stage="完成",
                percent=100.0,
                message=(
                    f"本地解压并上传完成（{_fmt_size(out_size)}），已删除原文件"
                    f"{_pwd_note(pwd)}"
                ),
            )
            return

        shutil.rmtree(out_dir, ignore_errors=True)
        _set_item(
            item_id,
            state="failed",
            stage="失败",
            message=f"本地解压失败：{last_err or '所有预设密码均未通过'}，已清理产物",
        )
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _download(
    client: httpx.Client,
    pickcode: str,
    target: Path,
    on_percent: Any,
) -> None:
    info = pan115.play_url(pickcode)
    url = str(info.get("url") or "")
    headers = {str(k): str(v) for k, v in (info.get("headers") or {}).items()}
    if not url:
        raise RuntimeError("获取下载直链失败")
    with httpx.Client(
        timeout=httpx.Timeout(60.0, read=300.0),
        follow_redirects=True,
        trust_env=False,
    ) as dl:
        with dl.stream("GET", url, headers=headers) as resp:
            resp.raise_for_status()
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            with open(target, "wb") as fh:
                for chunk in resp.iter_bytes(1 << 20):
                    fh.write(chunk)
                    done += len(chunk)
                    if total:
                        on_percent(min(99.0, done * 100.0 / total))


def _extract_archive(archive: Path, out_dir: Path, password: str) -> None:
    suffix = archive.suffix.lower()
    if suffix == ".zip":
        import zipfile

        with zipfile.ZipFile(archive) as zf:
            _safe_extract_zip(zf, out_dir, password)
        return
    if suffix == ".7z":
        import py7zr

        with py7zr.SevenZipFile(archive, mode="r", password=password or None) as zf:
            zf.extractall(path=out_dir)
        return
    if suffix == ".rar":
        import rarfile

        with rarfile.RarFile(archive) as rf:
            if password:
                rf.setpassword(password)
            rf.extractall(path=out_dir)
        return
    raise RuntimeError(f"不支持的压缩格式：{suffix or '未知'}")


def _safe_extract_zip(zf: Any, out_dir: Path, password: str) -> None:
    pwd = password.encode("utf-8") if password else None
    base = out_dir.resolve()
    for member in zf.infolist():
        target = (out_dir / member.filename).resolve()
        if not str(target).startswith(str(base)):
            raise RuntimeError(f"压缩包内路径非法：{member.filename}")
        if member.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with zf.open(member, pwd=pwd) as src, open(target, "wb") as dst:
            shutil.copyfileobj(src, dst)


def _upload_tree(
    client: httpx.Client,
    cookie: str,
    root: Path,
    parent_cid: str,
    item_id: str,
) -> None:
    cid_map: dict[Path, str] = {root: parent_cid}
    entries = sorted(root.rglob("*"), key=lambda p: (len(p.relative_to(root).parts), str(p)))
    files = [p for p in entries if p.is_file()]
    # 目录里已有的同名条目缓存：同名目录复用，同名文件先删再传（直接覆盖）
    existing: dict[str, dict[str, str]] = {}

    def children(cid: str, want_dir: bool) -> dict[str, str]:
        key = f"{cid}:{'d' if want_dir else 'f'}"
        if key not in existing:
            existing[key] = {
                str(row.get("name") or ""): str(row.get("id") or "")
                for row in _list_children(cid)
                if bool(row.get("is_dir")) is want_dir
            }
        return existing[key]

    done = 0
    for entry in entries:
        parent = cid_map.get(entry.parent, parent_cid)
        if entry.is_dir():
            if entry == root:
                continue
            cid = children(parent, True).get(entry.name)
            if not cid:
                created = pan115.create_folder(parent, entry.name)
                cid = str(created.get("cid") or "")
                children(parent, True)[entry.name] = cid
            cid_map[entry] = cid or parent
            continue
        cid = parent or parent_cid
        old_id = children(cid, False).pop(entry.name, "")
        if old_id:
            try:
                pan115.delete_items([old_id])
            except Exception as err:  # noqa: BLE001
                log.warning("overwrite %s in %s failed: %s", entry.name, cid, err)
        pan115.upload_file(str(entry), cid, entry.name)
        done += 1
        if files:
            _set_item(item_id, percent=min(99.0, done * 100.0 / len(files)))


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

def _folder_size(cid: str) -> int:
    """云端目录总大小（全递归，visited 防环）。"""
    if not cid:
        return 0
    total = 0
    stack: list[str] = [cid]
    seen: set[str] = set()
    while stack:
        cur = stack.pop()
        if not cur or cur in seen:
            continue
        seen.add(cur)
        offset = 0
        while True:
            data = pan115.list_files(cur, offset, 200)
            items = data.get("items") or []
            for row in items:
                if row.get("is_dir"):
                    stack.append(str(row.get("id") or ""))
                else:
                    total += int(row.get("size") or 0)
            if len(items) < 200:
                break
            offset += 200
    return total


def _dir_size(root: Path) -> int:
    return sum(p.stat().st_size for p in root.rglob("*") if p.is_file())


def _size_ok(out_size: int, size: int) -> bool:
    """产物大小是否达标：允许比原文件小 SIZE_TOLERANCE（默认 2%）。"""
    if out_size <= 0:
        return False
    if size <= 0:
        return True
    return out_size >= size * (1 - SIZE_TOLERANCE)


def _safe_name(name: str) -> str:
    base = os.path.basename(name.replace("\\", "/")) or "archive"
    return re.sub(r'[<>:"/\\|?*]', "_", base)


def _fmt_size(n: int) -> str:
    v = float(max(0, int(n)))
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if v < 1024 or unit == "TB":
            return f"{v:.0f} {unit}" if unit == "B" else f"{v:.1f} {unit}"
        v /= 1024
    return f"{v:.1f} TB"
