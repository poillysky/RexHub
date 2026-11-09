# -*- coding: utf-8 -*-
"""转存后延迟改名：等离线任务完成，给新增压缩包名追加 `[密码 xxx]`。

转存流程不再自动云解压；有解压密码时只把密码写进压缩包文件名
（`原名 [密码 abc].zip`），需要时用户可在设置里手动解压。
"""


import logging
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import httpx

from app.p115.client import normalize_cookie
from app.p115.extract import (
    MULTIPART_RE,
    POLL_MAX_S,
    _list_offline_tasks_pages,
)
from app.p115.naming import ARCHIVE_RE, PASSWORD_TAG_RE
from app.p115.polling import (
    POLL_INTERVAL_S,
    is_task_done,
    is_task_failed,
    match_tasks_by_hashes,
    submit_deferred,
    timeout_message,
)

log = logging.getLogger("p115-rename")

_rename_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="p115-rename")

LIST_PAGE = 200
MAX_LIST_PAGES = 20
MAX_SCAN_DIRS = 20


def password_labelled_name(name: str, password: str) -> str:
    """`原名 [密码 abc].zip`；非压缩包 / 分卷 / 已标注返回空串。"""
    base = (name or "").strip()
    pwd = (password or "").strip()
    if not base or not pwd:
        return ""
    # 分卷包改名后就认不出分卷了，直接跳过
    if MULTIPART_RE.search(base):
        return ""
    m = ARCHIVE_RE.search(base)
    if not m:
        return ""
    stem = base[: m.start()].strip()
    if not stem or PASSWORD_TAG_RE.search(stem):
        return ""
    return f"{stem[:170]} [密码 {pwd}]{m.group(0)}"


def _list_all(folder_cid: str, *, limit: int = LIST_PAGE) -> list[dict[str, Any]] | None:
    """翻页取全目录条目；任何一页失败返回 None（调用方放弃自动改名）。"""
    from app.rexhub import pan115

    rows: list[dict[str, Any]] = []
    offset = 0
    for _ in range(MAX_LIST_PAGES):
        try:
            data = pan115.list_files(folder_cid or "0", offset, limit)
        except Exception as err:  # noqa: BLE001 - 记录失败不影响转存
            log.info("list folder %s failed at offset %s: %s", folder_cid, offset, err)
            return None
        items = data.get("items") or []
        rows.extend(item for item in items if isinstance(item, dict))
        if len(items) < limit:
            break
        offset += limit
    return rows


def folder_item_ids(folder_cid: str, *, limit: int = LIST_PAGE) -> set[str] | None:
    """转存前记下目标目录现有条目；拿不到时返回 None（调用方放弃自动改名）。"""
    rows = _list_all(folder_cid, limit=limit)
    if rows is None:
        return None
    return {str(item.get("id") or "") for item in rows if item.get("id")}


def _collect_pairs(
    folder_cid: str,
    before_ids: set[str],
    password: str,
) -> list[tuple[str, str]]:
    """只给本次新增的压缩包（含新增目录里的一层）追加密码标注。"""
    rows = _list_all(folder_cid)
    if rows is None:
        return []

    pairs: list[tuple[str, str]] = []
    scanned_dirs = 0
    for item in rows:
        item_id = str(item.get("id") or "")
        if not item_id or item_id in before_ids:
            continue
        name = str(item.get("name") or "")
        if item.get("is_dir"):
            if scanned_dirs >= MAX_SCAN_DIRS:
                continue
            scanned_dirs += 1
            inner = _list_all(item_id)
            if inner is None:
                continue
            for sub in inner:
                if sub.get("is_dir"):
                    continue
                fid = str(sub.get("id") or "")
                new_name = password_labelled_name(str(sub.get("name") or ""), password)
                if fid and new_name:
                    pairs.append((fid, new_name))
            continue
        new_name = password_labelled_name(name, password)
        if new_name:
            pairs.append((item_id, new_name))
    return pairs


def _rename_new_archives(
    folder_cid: str,
    before_ids: set[str],
    password: str,
) -> dict[str, Any]:
    from app.rexhub import pan115

    pairs = _collect_pairs(folder_cid, before_ids, password)
    if not pairs:
        return {"ok": True, "message": "未发现需要标注密码的压缩包", "renamed": 0}
    try:
        pan115.rename_items(pairs)
    except Exception as err:  # noqa: BLE001 - 改名失败不影响转存结果
        log.info("rename archives with password failed: %s", err)
        return {"ok": False, "message": f"压缩包改名失败：{err}", "renamed": 0}
    return {"ok": True, "message": f"已给 {len(pairs)} 个压缩包标注密码", "renamed": len(pairs)}


def run_poll_then_rename(job: dict[str, Any]) -> dict[str, Any]:
    cookie = normalize_cookie(str(job.get("cookie") or ""))
    password = str(job.get("password") or "").strip()
    folder_cid = str(job.get("folderCid") or "0")
    before_ids = {str(x) for x in (job.get("beforeIds") or []) if x}
    if not cookie or not password:
        return {"ok": False, "message": "无 Cookie 或密码", "renamed": 0}

    hashes = [
        h.lower()
        for h in (job.get("infoHashes") or [])
        if isinstance(h, str) and h
    ]
    pending = set(hashes)
    started = time.time()
    budget = max(POLL_MAX_S, min(900.0, 90.0 + 60.0 * max(1, len(hashes))))

    with httpx.Client(
        timeout=30.0, follow_redirects=True, trust_env=False
    ) as client:
        while pending and time.time() - started < budget:
            try:
                tasks = _list_offline_tasks_pages(client, cookie)
            except Exception as err:  # noqa: BLE001
                log.info("poll offline tasks failed: %s", err)
                time.sleep(POLL_INTERVAL_S)
                continue
            for t in match_tasks_by_hashes(tasks, list(pending)):
                h = str(t.get("info_hash") or t.get("infoHash") or "").lower()
                if is_task_done(t) or is_task_failed(t):
                    pending.discard(h)
            if pending:
                time.sleep(POLL_INTERVAL_S)

    if pending:
        # 超时保留原名，不打扰用户
        log.info("rename skipped, offline unfinished: %s", len(pending))
        return {
            "ok": False,
            "message": timeout_message(budget, "压缩包未标注密码"),
            "renamed": 0,
        }

    # 任务刚完成时目录可能还没刷新，稍等一下再列目录
    time.sleep(1.5)
    return _rename_new_archives(folder_cid, before_ids, password)


def schedule_deferred_rename(job: dict[str, Any]) -> dict[str, str]:
    job_id = submit_deferred(
        _rename_pool, log=log, job=job, runner=run_poll_then_rename
    )
    log.info(
        "scheduled rename-after-save %s folderCid=%s hashes=%s",
        job_id,
        job.get("folderCid"),
        len(job.get("infoHashes") or []),
    )
    return {"jobId": job_id, "mode": "poll"}
