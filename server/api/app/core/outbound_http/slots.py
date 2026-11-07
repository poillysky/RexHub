"""outbound_http 子模块：单源「等槽预算」与详情页出站槽。"""

from contextlib import contextmanager

from .tls import thread_cancel_event, thread_request_timeout

# ---------------------------------------------------------------------------
# 单源「等槽预算」与工作预算解耦（第十轮）
#
# 背景：`enrich._one()` 原用 `th.join(timeout=单源超时)` 等源结果，而线程里第一件事是
# **抢出站槽**。于是「排队/限速/退避」的时间被算进单源超时 → 源明明 3.4s 能返回，
# 生产 p50 却恰好等于策略上限（mgstage 433 次假 down）。
#
# 修法两层：
#   ① 记账：`SlotWaitMeter` 只累计「没在发请求」的时间，调用方用「墙钟 − 等槽」
#      判真超时 → 排队不再吃掉单源超时额度。
#   ② 超时类型：排队超时抛 `OutboundBusy`（TimeoutError 子类），
#      `_classify_source_failure` 归为 `busy` —— 源没坏，只是没轮到。
#
# 第十一轮收紧「代价」：原来地板 20s / 上限 45s 是**与工作预算无关的固定加项**，
# 于是单源最坏墙钟 = 工作预算 + 20~45s（工作预算 5s 时是 5×）。现在改成
#   queue = clamp(工作预算, 12s, 30s)
# 即「排队预算不超过工作预算本身」→ 最坏 ≤ 2× 工作预算（小预算时 ≤ work + 12s）。
# 生产默认 perSourceTimeoutSec=28 → 28s（与旧值相同，无回归）；
# 过盾源 18s → 18s（旧 20s，-10%）；探针/小预算 5s → 12s（旧 20s，-40%）。
# ⚠️ 别再把地板抬回 20s：那是拿番号尾延迟换「排队成功率」，而排队成功与否
# 主要由**出站容量**（见 kind="api" 通道）决定，不是靠等得久。
# ---------------------------------------------------------------------------

# 单源排队预算：下限 12s（够一次完整排队轮次）、上限 30s（别让排队拖住番号）
_QUEUE_WAIT_MIN_SEC = 12.0
_QUEUE_WAIT_CAP_SEC = 30.0
# 无「线程内单源超时」时（交互式/封面路径）沿用历史的 90s 槽位预算
_QUEUE_WAIT_DEFAULT_SEC = 90.0


def source_queue_budget(work_budget: float | None = None) -> float:
    """单源「等出站槽 + 限速 + 退避」可用预算（秒）＝ `clamp(工作预算, 12, 30)`。

    ⚠️ 与策略的「单源超时」**解耦**：后者只约束真正开始发请求之后的耗时，
    这里给排队留额度。**排队预算 ≤ 工作预算本身**，所以最坏单源墙钟 ≈
    `2× 工作预算`（工作预算小于下限 12s 时是 `工作预算 + 12s`），
    而不是旧版的 `工作预算 + 20~45s`。

    排队放得宽不会留下僵尸请求 —— 上层放弃时会置线程取消令牌，
    它们 ≤0.2s 内抛 `OutboundCancelled` 退出，不占槽、不发请求。
    """
    base = work_budget
    if base is None:
        base = thread_request_timeout()
    try:
        b = float(base) if base is not None else 0.0
    except (TypeError, ValueError):
        b = 0.0
    if b <= 0:
        return _QUEUE_WAIT_DEFAULT_SEC
    return min(_QUEUE_WAIT_CAP_SEC, max(_QUEUE_WAIT_MIN_SEC, b))


@contextmanager
def _page_slot(url: str, *, timeout: float = 90.0):
    """详情页出站：全局 + 按 host（与封面共用调度器）。

    ⚠️ 队列预算与策略「单源超时」**解耦**（第十轮）：原来取
    `min(90, max(2, 单源超时))` → 源只是排了个队就抛 `outbound slot timeout`，
    被记成 `down`。现在排队预算走 `source_queue_budget()`（≥20s、≤90s），
    单源超时只约束「开始发请求之后」的耗时（调用方用 `SlotWaitMeter` 剔除等槽）。
    放弃排队靠**取消令牌**回收，不会留下占槽的僵尸请求。
    """
    from app.core.outbound_scheduler import get_scheduler

    to = max(0.5, float(timeout))
    to = min(to, source_queue_budget())
    with get_scheduler().slot(
        url, kind="page", timeout=to, cancel=thread_cancel_event()
    ):
        yield
