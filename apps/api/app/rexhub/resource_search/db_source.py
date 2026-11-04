"""Postgres 数据库源检索：bitmagnet 与色花堂（ed2k_resources）。"""


import urllib.parse
from time import monotonic

import asyncpg

from .constants import (
    BITMAGNET_TIMEOUT_MS,
    CACHE_MAX,
    CACHE_TTL,
    CONNECT_TIMEOUT,
    STATEMENT_TIMEOUT_MS,
)
from .keywords import _levels, _pattern, _terms, _where
from .links import _link_identity
from .metadata import _bitmagnet_items, _ed2k_items
from .relevance import _anchor

_candidates: dict[tuple[str, str], tuple[float, list[dict]]] = {}
# 数据库候选池：(时间, 原始候选行, 已请求条数, 是否已取全)
# complete 为 None 表示查询超时降级，只拿到了部分结果，再扩容也没有意义
_db_pools: dict[tuple[str, str], tuple[float, list[dict], int, bool | None]] = {}


def _db_pool_get(
    key: tuple[str, str],
) -> tuple[float, list[dict], int, bool | None] | None:
    entry = _db_pools.get(key)
    if entry is None:
        return None
    if monotonic() - entry[0] > CACHE_TTL:
        _db_pools.pop(key, None)
        return None
    return entry


def _db_pool_put(
    key: tuple[str, str],
    rows: list[dict],
    requested: int,
    complete: bool | None,
) -> None:
    if len(_db_pools) >= CACHE_MAX:
        oldest = min(_db_pools, key=lambda name: _db_pools[name][0])
        _db_pools.pop(oldest, None)
    _db_pools[key] = (monotonic(), rows, requested, complete)


def _dsn(item: dict) -> str:
    user = urllib.parse.quote(str(item.get("username") or ""), safe="")
    password = urllib.parse.quote(str(item.get("password") or ""), safe="")
    return (
        f"postgresql://{user}:{password}"
        f"@{item.get('host')}:{item.get('port')}/{item.get('database')}"
    )


async def _fetch(
    item: dict, sql: str, *args, timeout_ms: int = STATEMENT_TIMEOUT_MS
):
    conn = await asyncpg.connect(dsn=_dsn(item), timeout=CONNECT_TIMEOUT)
    try:
        await conn.execute(f"SET statement_timeout = {timeout_ms}")
        return await conn.fetch(sql, *args)
    finally:
        await conn.close()


def _rank(column: str, param: int) -> str:
    """SQL 侧粗排，先挑出关键词靠前、标题较短的候选集。"""

    return (
        f"CASE WHEN strpos(lower({column}), lower(${param})) <= 6 THEN 0 ELSE 1 END, "
        f"length({column})"
    )


def _match_rank(columns: tuple[str, ...], param: int, prefix: str = "") -> str:
    """按命中位置粗排：`columns` 里越靠前的字段命中越优先。

    色花堂大量帖子正文里堆着同一个标签（例如「自提征用」有上万条），
    只按文件名的长度排序会把真正以该标签命名的资源挤出候选池；
    这里让文件名命中的行直接排在最前，仅正文命中的垫底。
    """

    names = [f"{prefix}{column}" for column in columns]
    branches = " ".join(
        f"WHEN strpos(lower({name}), lower(${param})) > 0 THEN {index}"
        for index, name in enumerate(names)
    )
    return f"CASE {branches} ELSE {len(names)} END, length({names[0]})"


def _ranks(
    column: str, param: int, rank_columns: tuple[str, ...]
) -> tuple[str, str]:
    """返回 (内层排序表达式, 派生表 rex 外层排序表达式)。"""

    if rank_columns:
        return (
            _match_rank(rank_columns, param),
            _match_rank(rank_columns, param, "rex."),
        )
    return _rank(column, param), _rank(f"rex.{column}", param)


def _prefix_pattern(keyword: str) -> str | None:
    """单关键词才能走前缀索引；多词查询没有可用的前缀。"""

    terms = _terms(keyword)
    if len(terms) != 1:
        return None
    return _pattern(terms[0][0])[1:]  # 去掉开头的 %，变成「关键词%」


async def _search_db(
    item: dict,
    keyword: str,
    limit: int,
    *,
    table: str,
    columns: str,
    column: str,
    title_key: str,
    extra: str = "",
    tie: str = "",
    dedupe: bool = False,
    dedupe_column: str = "",
    alt_column: str = "",
    rank_columns: tuple[str, ...] = (),
    timeout_ms: int = STATEMENT_TIMEOUT_MS,
) -> tuple[list, bool]:
    """先严后宽的数据库查询，返回 (合并去重后的原始行, 是否已取全)。

    每层都带 LIMIT，只有上一层不足一页时才放宽一层，
    避免多词中文关键词在 bitmagnet 上反复全表扫描。

    dedupe 用窗口函数按标题去重，让一页候选都对应不同的资源；
    只给同名行大量重复的库打开，几百万行的大表上排序整批命中会明显拖慢。

    rank_columns 指定粗排的字段顺序：排在前面的字段命中更优先，
    用于「文件名命中 > 帖子标题命中 > 只有正文命中」这类分层排序。
    """

    tail = f", {tie}" if tie else ""
    rows: list = []
    seen: set[str] = set()
    for terms in _levels(keyword):
        where, args = _where(column, terms, alt_column)
        anchor_at = len(args) + 1
        limit_at = len(args) + 2
        if dedupe:
            # 去重分支要按时间倒序取每组最新一条；`columns` 已包含 created_at 时不再重复投影，
            # 否则派生表里会出现同名列，外层 ORDER BY 会变成歧义引用。
            # 默认按标题去重；色花堂这类「标题当文件名」的库按链接去重，
            # 避免同一部片子的不同清晰度/版本被误合并成一条。
            key_column = dedupe_column or column
            partition = f"lower({key_column})"
            created = "" if "created_at" in columns else ", created_at"
            rank_inner, rank_outer = _ranks(column, anchor_at, rank_columns)
            sql = f"""
            SELECT {columns} FROM (
                SELECT {columns}{created},
                       row_number() OVER (
                           PARTITION BY {partition}
                           ORDER BY {rank_inner}, created_at DESC
                       ) AS rex_rn
                FROM {table}
                WHERE {where}{extra}
            ) rex
            WHERE rex_rn = 1
            ORDER BY {rank_outer}, created_at DESC{tail}
            LIMIT ${limit_at}
            """
        else:
            rank_inner, _ = _ranks(column, anchor_at, rank_columns)
            sql = f"""
            SELECT {columns}
            FROM {table}
            WHERE {where}{extra}
            ORDER BY {rank_inner}, created_at DESC{tail}
            LIMIT ${limit_at}
            """
        got = await _fetch(
            item, sql, *args, _anchor(keyword), limit, timeout_ms=timeout_ms
        )
        key_column = dedupe_column or title_key
        for row in got:
            raw = row[key_column]
            # 链接列优先按链接里的文件哈希去重（改名但同文件的记录也能合并）；
            # 拿不到哈希就退回原始链接，避免把不同文件当成重复误杀。
            key = (_link_identity(str(raw or "")) or str(raw or "")).strip().lower()
            if key in seen:
                continue
            seen.add(key)
            rows.append(row)
        if len(got) >= limit:
            return rows, False
    return rows, True


async def _bitmagnet_meta(item: dict, rows) -> dict:
    """批量补充分辨率 / 编码 / 发布组与做种数，查不到时静默跳过。"""

    hashes = []
    for row in rows:
        try:
            hashes.append(bytes.fromhex(str(row["info_hash"])))
        except ValueError:
            continue
    if not hashes:
        return {}

    meta: dict[str, dict] = {}
    try:
        got = await _fetch(
            item,
            "SELECT encode(info_hash, 'hex') AS info_hash, video_resolution,"
            " video_codec, release_group"
            " FROM torrent_contents WHERE info_hash = ANY($1::bytea[])",
            hashes,
            timeout_ms=BITMAGNET_TIMEOUT_MS,
        )
        for row in got:
            meta[str(row["info_hash"]).lower()] = {
                "video_resolution": row["video_resolution"],
                "video_codec": row["video_codec"],
                "release_group": row["release_group"],
            }
    except Exception:  # noqa: BLE001 - 元数据缺失不影响检索
        meta = {}

    try:
        got = await _fetch(
            item,
            "SELECT encode(info_hash, 'hex') AS info_hash, seeders, leechers"
            " FROM torrents_torrent_sources WHERE info_hash = ANY($1::bytea[])",
            hashes,
            timeout_ms=BITMAGNET_TIMEOUT_MS,
        )
        for row in got:
            entry = meta.setdefault(str(row["info_hash"]).lower(), {})
            entry.setdefault("seeders", row["seeders"])
            entry.setdefault("leechers", row["leechers"])
    except Exception:  # noqa: BLE001
        pass

    return meta


async def _search_bitmagnet(
    item: dict, keyword: str, limit: int
) -> tuple[list[dict], bool | None]:
    """返回 (结果, 是否已取全)。complete=None 表示超时降级，只有部分结果。

    prefix 命中只作为超时兜底，不再提前返回。
    """

    columns = (
        "name, size, files_count, extension, created_at,"
        " encode(info_hash, 'hex') AS info_hash"
    )
    prefix = _prefix_pattern(keyword)
    seeded: list = []
    try:
        if prefix:
            seeded = await _fetch(
                item,
                f"SELECT {columns} FROM torrents WHERE name ILIKE $1"
                " ORDER BY created_at DESC, info_hash LIMIT $2",
                prefix,
                limit,
            )
        rows, complete = await _search_db(
            item,
            keyword,
            limit,
            table="torrents",
            columns=columns,
            column="name",
            title_key="name",
            tie="info_hash",
            dedupe_column="info_hash",
            timeout_ms=BITMAGNET_TIMEOUT_MS,
        )
    except asyncpg.exceptions.QueryCanceledError:
        # 中文关键词在英文库上只能全表扫描，超时时先返回前缀命中的结果，避免整组搜索失败；
        # 这批结果一定不全，返回 None 标记降级：不再扩容重试，前端会提示结果可能不完整
        if seeded:
            return _bitmagnet_items(seeded, await _bitmagnet_meta(item, seeded)), None
        raise
    return _bitmagnet_items(rows, await _bitmagnet_meta(item, rows)), complete


async def _sehuatang_meta(item: dict, rows) -> dict:
    """按 hash 批量取帖子信息：帖子标题、板块、来源帖、正文、预览图与提取码。

    ed2k_resources 与 resource_sources 是 1:1（哈希唯一索引），
    一次性批量读回比逐条回表快得多，也避免用无索引的链接数组做匹配。
    """

    hashes = [str(row["hash"] or "").upper() for row in rows if row["hash"]]
    if not hashes:
        return {}
    try:
        got = await _fetch(
            item,
            "SELECT hash, title, board_name, source_url, description, preview_images,"
            " extract_password"
            " FROM resource_sources WHERE hash = ANY($1::text[])",
            hashes,
        )
    except Exception:  # noqa: BLE001 - 元数据缺失不影响检索
        return {}
    return {str(row["hash"]).upper(): row for row in got}


async def _search_sehuatang(
    item: dict, keyword: str, limit: int
) -> tuple[list[dict], bool]:
    """返回 (结果, 是否已取全)。前缀命中只是全量匹配的子集，不能短路。"""

    rows, complete = await _search_db(
        item,
        keyword,
        limit,
        table="ed2k_resources",
        columns="filename, ed2k_link, search_string, size, created_at, hash",
        column="filename",
        title_key="filename",
        extra="\n          AND ed2k_link NOT LIKE 'unavailable://%'",
        tie="ed2k_link",
        dedupe=True,
        dedupe_column="ed2k_link",
        alt_column="search_string",
        # 文件名命中的行排在最前：色花堂大量帖子正文里堆着同一个标签，
        # 只按长度排序会把真正以该标签命名的资源挤出候选池。
        rank_columns=("filename",),
    )
    return _ed2k_items(rows, await _sehuatang_meta(item, rows)), complete
