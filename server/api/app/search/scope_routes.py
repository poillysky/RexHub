"""范围搜索：影视 / 片商两类范围的多源聚合检索。

- 影视（movie）：Bitmagnet + CloudSaver
- 片商（maker）：AVDB + Bitmagnet + 色花堂论坛

各源并行执行，单源失败只写入 ``sourceErrors``，不影响整体结果。
"""

from __future__ import annotations

import logging
import re
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, Query

import app.search.bitmagnet_client as bitmagnet_client
import app.search.cloudsaver_client as cloudsaver_client
import app.search.resource_service as resource_service
from app.auth.routes import require_user
from app.makers.service import TORRENT_LIMIT_MAX, fetch_torrents

log = logging.getLogger(__name__)

router = APIRouter(tags=["search"])

SCOPE_SOURCES: dict[str, tuple[str, ...]] = {
    "movie": ("bitmagnet", "cloudsaver"),
    "maker": ("avdb", "bitmagnet", "sehuatang"),
}

SOURCE_LABELS: dict[str, str] = {
    "bitmagnet": "Bitmagnet",
    "cloudsaver": "CloudSaver",
    "sehuatang": "色花堂",
    "avdb": "AVDB",
}

# 多源聚合总预算：到点未完成的源标记超时，保证请求按时返回。
# 深翻页时单次要取的前缀更长，预算随页码线性放宽，避免深层结果被整体判超时。
_SCOPE_BUDGET_S = 25.0
_SCOPE_BUDGET_MAX_S = 60.0

_TIME_CUTOFF_SECONDS = {
    "gt-1day": 86400,
    "gt-7day": 7 * 86400,
    "gt-31day": 31 * 86400,
    "gt-365day": 365 * 86400,
}

_SIZE_RANGES = {
    "lt100mb": (0, 100 * 1024 * 1024),
    "gt100mb-lt500mb": (100 * 1024 * 1024, 500 * 1024 * 1024),
    "gt500mb-lt1gb": (500 * 1024 * 1024, 1024 * 1024 * 1024),
    "gt1gb-lt5gb": (1024 * 1024 * 1024, 5 * 1024 * 1024 * 1024),
    "gt5gb": (5 * 1024 * 1024 * 1024, None),
}

# 「中文，English」这类多别名关键词：按分隔符拆词后逐词搜索再合并
_KEYWORD_TERM_SEP = re.compile(r"[,;，、；|｜/\n\r]+")
_MAX_KEYWORD_TERMS = 2


def _keyword_terms(keyword: str) -> list[str]:
    """拆成最多 2 个词（与 Bitmagnet 别名口径一致）；无分隔符时原样返回。"""
    raw = (keyword or "").strip()
    if not raw:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for part in _KEYWORD_TERM_SEP.split(raw):
        term = part.strip()
        if len(term) < 2:
            continue
        key = term.casefold()
        if key in seen:
            continue
        seen.add(key)
        out.append(term)
        if len(out) >= _MAX_KEYWORD_TERMS:
            break
    return out or [raw]


def _size_label(size: Any) -> str:
    n = float(size or 0)
    if n <= 0:
        return "0 B"
    units = ("B", "KB", "MB", "GB", "TB")
    idx = 0
    while n >= 1024 and idx < len(units) - 1:
        n /= 1024
        idx += 1
    return f"{int(n)} B" if idx == 0 else f"{n:.1f} {units[idx]}"


def _parse_datetime(value: Any) -> datetime | None:
    if isinstance(value, (int, float)) and value > 0:
        return datetime.fromtimestamp(float(value), tz=timezone.utc)
    text = str(value or "").strip()
    if not text:
        return None

    def _finish(dt: datetime) -> datetime:
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)

    try:
        return _finish(datetime.fromisoformat(text.replace("Z", "+00:00")))
    except ValueError:
        pass
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S"):
        try:
            return _finish(datetime.strptime(text[:19], fmt))
        except ValueError:
            continue
    for fmt in ("%Y-%m-%d", "%Y/%m/%d"):
        try:
            return _finish(datetime.strptime(text[:10], fmt))
        except ValueError:
            continue
    return None


def _passes_filters(
    item: dict[str, Any], *, filter_time: str, filter_size: str
) -> bool:
    if filter_time != "all":
        seconds = _TIME_CUTOFF_SECONDS.get(filter_time)
        published = item.get("_published")
        if seconds:
            if not published:
                return False
            age = (datetime.now(tz=timezone.utc) - published).total_seconds()
            if age > seconds:
                return False
    if filter_size != "all":
        lo, hi = _SIZE_RANGES.get(filter_size, (0, None))
        size = int(item.get("sizeBytes") or 0)
        # 网盘条目上游不给大小（恒 0），按「未知」处理，别当成 0 B 落进 <100MB
        if size <= 0:
            return False
        if size < lo or (hi is not None and size >= hi):
            return False
    return True


def _make_item(
    *,
    source: str,
    category: str,
    item_id: str,
    title: str,
    size_bytes: Any = 0,
    published: datetime | None = None,
    magnet: str | None = None,
    ed2k: str | None = None,
    links: list[dict[str, str]] | None = None,
    thumb_url: str | None = None,
    detail_kind: str | None = None,
    detail_id: str | None = None,
    info_hash: str | None = None,
) -> dict[str, Any]:
    size = max(0, int(size_bytes or 0))
    return {
        "id": f"{source}:{item_id}",
        "hash": info_hash or None,
        "source": source,
        "sourceLabel": SOURCE_LABELS[source],
        "category": category,
        "title": title,
        "sizeBytes": size,
        "sizeLabel": _size_label(size),
        "publishedAt": published.strftime("%Y-%m-%d") if published else None,
        "magnet": magnet or None,
        "ed2k": ed2k or None,
        "links": links or [],
        "thumbUrl": thumb_url or None,
        "detailKind": detail_kind,
        "detailId": detail_id,
        "_published": published,
    }


def _bitmagnet_items(
    keyword: str,
    want: int,
    *,
    sort_type: str,
    filter_time: str,
    filter_size: str,
) -> list[dict[str, Any]]:
    if len(keyword) < 2:
        return []
    # 一次取够 want 条（不再按 Bitmagnet 每页 10 条逐页拉，深翻页会重复扫库）；
    # 多取 20 条补偿同名同体积去重带来的前缀损耗。
    data = bitmagnet_client.search(
        keyword,
        limit=want + 20,
        sort_type=sort_type,
        filter_time=filter_time,
        filter_size=filter_size,
    )
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    seen_pairs: set[tuple[str, int]] = set()
    for row in data.get("items") or []:
        if not isinstance(row, dict):
            continue
        info_hash = str(row.get("hash") or row.get("infoHash") or "").strip()
        if not info_hash or info_hash in seen:
            continue
        seen.add(info_hash)
        title = str(row.get("name") or row.get("title") or info_hash)
        # 与其它源一致：同名同体积只保留一条，避免重复项占掉分页窗口
        pair = (title.strip().lower(), int(row.get("size") or 0))
        if pair in seen_pairs:
            continue
        seen_pairs.add(pair)
        out.append(
            _make_item(
                source="bitmagnet",
                category="torrent",
                item_id=info_hash,
                title=title,
                size_bytes=row.get("size"),
                published=_parse_datetime(row.get("created_at")),
                magnet=str(row.get("magnet") or row.get("magnet_uri") or "") or None,
                info_hash=info_hash,
            )
        )
    return out[:want]


def _cloudsaver_items(
    keyword: str,
    want: int,
    *,
    sort_type: str,
    filter_time: str,
    filter_size: str,
) -> list[dict[str, Any]]:
    # 有筛选条件时提前多取一些，避免「先截断再过滤」把有效结果漏掉；
    # 再额外多取 20 条补偿按链接类型/重复标题过滤造成的损耗。
    fetch_want = (want if filter_time == "all" and filter_size == "all" else want * 3) + 20
    # 「中文，English」拆词分别搜再合并（CloudSaver 自身不支持多词 OR）；
    # 多词并行请求，总耗时按最慢的一路算。
    terms = _keyword_terms(keyword)
    if len(terms) <= 1:
        datasets = [cloudsaver_client.search(t, min_items=fetch_want) for t in terms]
    else:
        with ThreadPoolExecutor(max_workers=min(len(terms), 4)) as pool:
            datasets = list(
                pool.map(lambda t: cloudsaver_client.search(t, min_items=fetch_want), terms)
            )
    items: list[dict[str, Any]] = []
    seen_rows: set[str] = set()
    rows: list[dict[str, Any]] = []
    for data in datasets:
        for row in data.get("items") or []:
            if not isinstance(row, dict):
                continue
            uid = str(row.get("id") or row.get("title") or "").strip()
            if uid and uid in seen_rows:
                continue
            if uid:
                seen_rows.add(uid)
            rows.append(row)
    for row in rows:
        links: list[dict[str, str]] = []
        magnet: str | None = None
        for link in row.get("links") or []:
            if not isinstance(link, dict):
                continue
            url = str(link.get("url") or "").strip()
            if not url:
                continue
            # 只保留 115 网盘与磁力，其它网盘（夸克/百度/阿里等）不展示
            kind = str(link.get("type") or "").strip().lower()
            if not kind:
                kind = cloudsaver_client._normalize_cloud_type("", url)
            if kind not in ("115", "magnet"):
                continue
            links.append(
                {
                    "label": str(link.get("label") or link.get("type") or "链接"),
                    "url": url,
                    "password": str(link.get("password") or "").strip(),
                }
            )
            if not magnet and url.startswith("magnet:"):
                magnet = url
        if not links:
            continue
        items.append(
            _make_item(
                source="cloudsaver",
                category="pan",
                item_id=f"{row.get('id') or row.get('title') or 'item'}#{len(items)}",
                title=str(row.get("title") or "未命名资源"),
                published=_parse_datetime(row.get("datetime")),
                magnet=magnet,
                links=links,
            )
        )
    items = [
        it
        for it in items
        if _passes_filters(
            it, filter_time=filter_time, filter_size=filter_size
        )
    ]
    items.sort(
        key=lambda it: it["_published"].timestamp() if it["_published"] else 0,
        reverse=True,
    )
    return items[:want]


def _sehuatang_items(
    keyword: str,
    want: int,
    *,
    sort_type: str,
    filter_time: str,
    filter_size: str,
) -> list[dict[str, Any]]:
    if len(keyword) < 2:
        return []
    # 合并前各源都要给出「从头到 want」的连续前缀，深页才能正确切片。
    # 分页大小必须固定：上游按 (page-1)*ps 取窗口，ps 每次变化会让下一页和前页重叠，
    # 去重后条目数不增，hasMore 就会误判「没有更多」。
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    seen_pairs: set[tuple[str, int]] = set()
    page = 1
    step = 80
    while len(items) < want:
        data = resource_service.search_resources(
            keyword=keyword,
            p=page,
            ps=step,
            sort_type=sort_type,
            filter_time=filter_time,
            filter_size=filter_size,
            match_mode="exact",
            with_total_count=False,
        )
        rows = data.get("resources") or []
        for row in rows:
            if not isinstance(row, dict):
                continue
            link = str(row.get("ed2k_link") or "").strip()
            magnets = row.get("ed2k_links") or []
            magnet = next(
                (str(x) for x in magnets if str(x).startswith("magnet:")), ""
            )
            hard_id = str(row.get("hash") or "").strip() or link or str(row.get("name") or "")
            title = str(row.get("title") or row.get("name") or hard_id)
            # 同一资源会被不同频道重复搬运（hash 不同、标题与体积相同）：
            # 在源内先去重，保证「前缀长度」和最终展示条数一致，避免翻页越走越空。
            pair = (title.strip().lower(), int(row.get("size") or 0))
            if not hard_id or hard_id in seen or pair in seen_pairs:
                continue
            seen.add(hard_id)
            seen_pairs.add(pair)
            previews = row.get("preview_images") or []
            items.append(
                _make_item(
                    source="sehuatang",
                    category="torrent",
                    item_id=hard_id,
                    title=title,
                    size_bytes=row.get("size"),
                    published=_parse_datetime(row.get("created_at")),
                    magnet=magnet or (link if link.startswith("magnet:") else None),
                    ed2k=link if link.startswith("ed2k://") else None,
                    thumb_url=str(previews[0]) if previews else None,
                    info_hash=str(row.get("hash") or "").strip(),
                )
            )
        if len(rows) < step:
            break
        page += 1
    return items[:want]


def _avdb_items(
    keyword: str,
    want: int,
    *,
    sort_type: str,
    filter_time: str,
    filter_size: str,
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    seen_pairs: set[tuple[str, int]] = set()
    page = 1
    # 分页大小固定，避免 (page-1)*limit 的窗口随 limit 变化而重叠
    step = TORRENT_LIMIT_MAX
    while len(items) < want:
        data = fetch_torrents(
            keyword=keyword,
            page=page,
            limit=step,
            exact=False,
        )
        rows = data.get("items") or []
        for row in rows:
            if not isinstance(row, dict):
                continue
            download = str(row.get("downloadUrl") or "").strip()
            dedupe_key = str(row.get("id") or download or row.get("number") or "").strip()
            title = str(row.get("title") or row.get("number") or "未命名资源")
            pair = (title.strip().lower(), int(row.get("sizeBytes") or 0))
            if dedupe_key:
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)
            if pair in seen_pairs:
                continue
            seen_pairs.add(pair)
            links = (
                [{"label": "下载", "url": download, "password": ""}]
                if download and not download.startswith(("magnet:", "ed2k://"))
                else []
            )
            item = _make_item(
                source="avdb",
                category="torrent",
                item_id=f"{row.get('id') or download or row.get('number') or 'item'}#{len(items)}",
                title=title,
                size_bytes=row.get("sizeBytes"),
                published=_parse_datetime(row.get("postTime")),
                magnet=download if download.startswith("magnet:") else None,
                ed2k=download if download.startswith("ed2k://") else None,
                links=links,
                thumb_url=row.get("previewImage"),
            )
            # 先过滤再计数，否则带筛选条件时会在凑满 want 后停止翻页，漏掉后续有效结果
            if not _passes_filters(
                item, filter_time=filter_time, filter_size=filter_size
            ):
                continue
            items.append(item)
            if len(items) >= want:
                break
        if not data.get("hasMore") or not rows:
            break
        page += 1
    return items[:want]


_FETCHERS = {
    "bitmagnet": _bitmagnet_items,
    "cloudsaver": _cloudsaver_items,
    "sehuatang": _sehuatang_items,
    "avdb": _avdb_items,
}


def _error_text(exc: Exception) -> str:
    detail = getattr(exc, "detail", None)
    return str(detail or exc or "搜索失败")


@router.get("/search/scope")
def search_scope(
    scope: str = Query("movie"),
    keyword: str = Query(..., min_length=1),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1),
    sort_type: str = Query("relevance"),
    filter_time: str = Query("all"),
    filter_size: str = Query("all"),
    source: str = Query("all"),
    _user: dict[str, Any] = Depends(require_user),
) -> dict[str, Any]:
    """按范围聚合多源搜索；返回裸 JSON（不包 Envelope）。"""
    scope_key = scope if scope in SCOPE_SOURCES else "movie"
    kw = keyword.strip()
    # 多取 1 条才能判断「还有下一页」（各源取到 want，合并后 > start+page_size 即 hasMore）
    want = page * page_size + 1
    budget_s = min(_SCOPE_BUDGET_MAX_S, _SCOPE_BUDGET_S + (page - 1) * 2.0)
    sources = SCOPE_SOURCES[scope_key]
    if source != "all" and source in sources:
        sources = (source,)
    sort_key = sort_type if sort_type in ("relevance", "date", "size") else "relevance"

    results: dict[str, list[dict[str, Any]]] = {}
    source_errors: dict[str, str] = {}
    offset = (page - 1) * page_size
    pool = ThreadPoolExecutor(max_workers=len(sources))
    futures = {
        pool.submit(
            _FETCHERS[name],
            kw,
            want,
            sort_type=sort_key,
            filter_time=filter_time,
            filter_size=filter_size,
        ): name
        for name in sources
    }
    try:
        done, pending = wait(futures, timeout=budget_s)
        for future in done:
            name = futures[future]
            try:
                results[name] = future.result()
            except Exception as exc:  # 单源失败隔离
                log.warning("scope search %s failed: %s", name, exc)
                source_errors[name] = _error_text(exc)
        for future in pending:
            name = futures[future]
            future.cancel()
            log.warning("scope search %s timed out after %.0fs", name, budget_s)
            source_errors[name] = "搜索超时"
    finally:
        # 不等未完成线程：到预算就返回，后端线程自行收尾
        pool.shutdown(wait=False, cancel_futures=True)

    merged: list[dict[str, Any]] = []
    if sort_key == "relevance":
        # 各源的相关度分数不可比：按源轮转交错，让每个来源从第一页就出现。
        # 否则排在前面的源（AVDB、Bitmagnet）会占满前面几十页，其它源看起来像没结果。
        queues = [results.get(name) or [] for name in sources]
        row = 0
        while True:
            appended = False
            for queue in queues:
                if row < len(queue):
                    merged.append(queue[row])
                    appended = True
            if not appended:
                break
            row += 1
    else:
        for name in sources:
            merged.extend(results.get(name) or [])

    seen: set[tuple[str, int, str]] = set()
    deduped: list[dict[str, Any]] = []
    for item in merged:
        # 网盘条目没有大小（sizeBytes=0），只用 (标题, 0) 去重会把同名不同资源的
        # 115 链接全压成一条，所以无大小时补上首个链接做区分。
        tail = "" if item["sizeBytes"] else next(
            (str(lk.get("url") or "") for lk in item.get("links") or []), ""
        )
        key = (item["title"].strip().lower(), item["sizeBytes"], tail)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(item)

    if sort_key == "size":
        deduped.sort(key=lambda it: it["sizeBytes"], reverse=True)
    elif sort_key == "date":
        deduped.sort(
            key=lambda it: (
                it["_published"].timestamp() if it["_published"] else 0,
            ),
            reverse=True,
        )

    page_items = deduped[offset : offset + page_size]
    for item in page_items:
        item.pop("_published", None)

    # 去重会压缩前缀：同一资源被多个频道/种子重复发布时，deduped 会比 want 短，
    # 只看 deduped 长度会在第 2 页就误判「没有更多」。只要还有来源能凑满 want，
    # 就说明它没取完，必须继续翻页。
    raw_more = any(len(results.get(name) or []) >= want for name in sources)

    return {
        "scope": scope_key,
        "keyword": kw,
        "page": page,
        "sourceErrors": source_errors,
        "items": page_items,
        "hasMore": len(deduped) > offset + len(page_items) or raw_more,
    }
