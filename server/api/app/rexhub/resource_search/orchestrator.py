"""多源检索编排：并发调用各检索实现、按需扩容候选池并跨库合并去重。"""


import asyncio

import asyncpg

from .cloudsaver import _CloudSaverAuthError, _search_cloudsaver
from .constants import CANDIDATE_GROWTH, MAX_CANDIDATES, PAGE_CANDIDATES, RESULT_LIMIT
from .db_source import (
    _db_pool_get,
    _db_pool_put,
    _search_bitmagnet,
    _search_sehuatang,
    cache_key,
)
from .links import _link_identity
from .metadata import _merge_metadata, _metadata_rich, _password_from_text
from .relevance import _rerank


PROVIDERS = (
    ("bitmagnet", _search_bitmagnet),
    ("sehuatang", _search_sehuatang),
    ("ed2k", _search_sehuatang),
    ("cloudsaver", _search_cloudsaver),
    ("cloud-saver", _search_cloudsaver),
)

EXTERNAL_PROVIDERS = {_search_cloudsaver}


def resolve_provider(item: dict):
    """按服务标签识别检索实现，便于同类数据库直接复用。"""

    label = " ".join(
        str(item.get(key) or "") for key in ("id", "notes", "database", "name")
    ).lower()
    for key, provider in PROVIDERS:
        if key in label:
            return provider
    return None


def _ensure_password(rows: list[dict]) -> list[dict]:
    """外部搜索源没给 password 时，从标题里再兜底提取一次。"""

    for row in rows:
        if not str(row.get("password") or "").strip():
            value = _password_from_text(str(row.get("title") or ""))
            if value:
                row["password"] = value
    return rows


async def search(
    items: list[dict],
    keyword: str,
    limit: int = RESULT_LIMIT,
    offset: int = 0,
) -> list[tuple[dict, list[dict], str, bool, bool]]:
    """并发检索，返回 (服务, 本页结果, 错误信息, 是否还有更多, 是否已达候选上限)。"""

    offset = max(0, offset)

    async def run(item: dict):
        provider = resolve_provider(item)
        if provider is None:
            return item, [], "该服务尚未接入检索", False, False
        try:
            if provider in EXTERNAL_PROVIDERS:
                # 外部搜索源（CloudSaver）自带排序与游标分页，按需翻到 offset+limit 条
                rows, has_more = await provider(item, keyword, offset + limit)
                rows = _ensure_password(rows)
                return item, rows[offset : offset + limit], "", has_more, False

            key = cache_key(item, keyword)
            needed = offset + limit
            entry = _db_pool_get(key)
            if entry is None:
                rows, requested, complete = [], 0, False
            else:
                rows, requested, complete = entry[1], entry[2], entry[3]

            while True:
                if requested == 0:
                    want = PAGE_CANDIDATES
                elif complete is not False or requested >= MAX_CANDIDATES:
                    break
                elif len(_rerank(keyword, rows)) > offset:
                    # 当前候选池还能覆盖这一页，先按需返回
                    break
                else:
                    want = min(
                        MAX_CANDIDATES,
                        max(needed, requested * CANDIDATE_GROWTH),
                    )
                    if want <= requested:
                        break

                # 候选池按需扩容：翻页超出当前池子（或被相关性过滤用尽）时重新取更大的 LIMIT，
                # SQL 排序固定，扩大后的结果一定包含原池子，翻页顺序保持稳定
                rows, complete = await provider(item, keyword, want)
                requested = want
                _db_pool_put(key, rows, requested, complete)

            full = _rerank(keyword, rows)
            truncated = complete is None or (
                complete is False and requested >= MAX_CANDIDATES
            )
            has_more = len(full) > needed or (
                complete is False and requested < MAX_CANDIDATES
            )
            return item, full[offset : offset + limit], "", has_more, truncated
        except _CloudSaverAuthError as exc:
            label = str(item.get("name") or "该服务")
            detail = str(exc)
            if detail and detail != "未配置凭据":
                return (
                    item,
                    [],
                    f"{label} 鉴权失败：{detail}，请更新 API Key 或账号密码",
                    False,
                    False,
                )
            return (
                item,
                [],
                f"需要在服务管理里填写 {label} 的账号密码或 API Key",
                False,
                False,
            )
        except RuntimeError as exc:
            return item, [], str(exc) or "检索失败", False, False
        except asyncio.TimeoutError:
            return item, [], "连接超时，请检查服务是否在线", False, False
        except asyncpg.exceptions.QueryCanceledError:
            return item, [], "检索超时，请换个更具体的关键词", False, False
        except Exception as exc:  # noqa: BLE001
            return item, [], f"检索失败：{type(exc).__name__}", False, False

    outcomes = list(await asyncio.gather(*(run(item) for item in items)))

    # 跨库去重：以链接里的文件哈希为准（磁力 btih / ed2k 文件哈希），
    # 同一条链在多个库出现时只输出一条；一条记录挂多条链则不参与去重。
    # 重复时保留信息更全的那条（色花堂带板块 / 来源帖 / 正文 / 预览图，
    # bitmagnet 只有种子字段），并把另一条的做种数、画质等字段补过去，
    # 避免为了去重把详情页里能展示的内容丢掉。
    picked: dict[str, dict] = {}
    identity_of: dict[int, str | None] = {}
    for _item, rows, _error, _more, _truncated in outcomes:
        for row in rows:
            identity = _link_identity(str(row.get("link") or ""))
            identity_of[id(row)] = identity
            if identity is None:
                continue
            current = picked.get(identity)
            if current is None:
                picked[identity] = row
            elif _metadata_rich(row) and not _metadata_rich(current):
                _merge_metadata(row, current)
                picked[identity] = row
            else:
                _merge_metadata(current, row)

    merged: list[tuple[dict, list[dict], str, bool, bool]] = []
    for item, rows, error, has_more, truncated in outcomes:
        kept: list[dict] = []
        for row in rows:
            identity = identity_of[id(row)]
            # 同一条链只输出选中的那条，另一条库里的副本直接丢弃
            if identity is None or picked.get(identity) is row:
                kept.append(row)
        merged.append((item, kept, error, has_more, truncated))
    return merged
