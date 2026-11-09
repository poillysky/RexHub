# -*- coding: utf-8 -*-
"""115 离线转存轮询 + 延迟任务调度。

「按 info_hash 匹配任务 → 判失败/终态/已完成 → 算进度文案 → 超时文案」这一段
曾在校验/搬移流程中逐字复制；`schedule_deferred_*` 也是同一形状。此处收敛为唯一实现。
"""


import secrets
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable

POLL_INTERVAL_S = 3.0


def is_task_done(t: Any) -> bool:
    if not isinstance(t, dict):
        return False
    try:
        status = int(t.get("status", -99))
    except (TypeError, ValueError):
        status = -99
    if status == 2 or t.get("status") == "2":
        return True
    for key in ("percentDone", "percent_done"):
        try:
            if float(t.get(key) or 0) >= 100:
                return True
        except (TypeError, ValueError):
            continue
    return False


def is_task_failed(t: Any) -> bool:
    if not isinstance(t, dict):
        return False
    try:
        status = int(t.get("status") or 0)
    except (TypeError, ValueError):
        status = 0
    return status < 0


def match_tasks_by_hashes(tasks: list[Any], hashes: list[str]) -> list[dict[str, Any]]:
    """按 info_hash（或 infoHash）过滤出本次关心的离线任务。"""
    return [
        t
        for t in tasks
        if isinstance(t, dict)
        and str(t.get("info_hash") or t.get("infoHash") or "").lower() in hashes
    ]


def timeout_message(poll_max_s: float, note: str) -> str:
    return f"等待转存超时（{int(poll_max_s)} 秒）：{note}"


def submit_deferred(
    pool: ThreadPoolExecutor,
    *,
    log: Any,
    job: dict[str, Any],
    runner: Callable[[dict[str, Any]], dict[str, Any]],
) -> str:
    """生成 jobId、包一层统一的成功/失败日志，提交到池；返回 jobId。

    调用方负责随后打自己那条 `scheduled …` 日志（各模块字段不同）。
    """
    job_id = f"{int(time.time() * 1000)}_{secrets.token_hex(3)}"

    def _run() -> None:
        try:
            result = runner(job)
            log.info(
                "%s %s %s",
                job_id,
                "ok" if result.get("ok") else "fail",
                result.get("message"),
            )
        except Exception:
            log.exception("%s fail", job_id)

    pool.submit(_run)
    return job_id
