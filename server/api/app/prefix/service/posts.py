"""中文帖评分、番号标题桶与中文题补扫（zh boost）。

热路径用廉价假壳判断给帖打分（中文优先、假壳不进桶），
并对缺中文题的番号做 title-only 限定补扫重选 forumTitle。
"""

import logging
from typing import Any

from app.search.constants import escape_ilike
from app.search.resource_format import PUBLIC_RESOURCE_FILTER

from .codes import _std_code_key
from .db import _query_prefix_scan
from .params import (
    PREFIX_POSTS_PER_CODE,
    PREFIX_ZH_BOOST_ENABLED,
    PREFIX_ZH_BOOST_ROW_CAP,
)

log = logging.getLogger(__name__)


def _post_zh_keep_score(desc: str, title: str, *, code: str = "") -> int:
    """收帖优先级（热路径：禁止 clean_forum_zh_title，只用廉价假壳判断）。"""
    from app.search.pack_bleed import get_description_field
    from app.search.forum_title import is_fake_forum_title_fast

    d = str(desc or "")
    t = str(title or "")
    if not d.strip() and not t.strip():
        return -1

    film = str(
        get_description_field(d, "影片名称")
        or get_description_field(d, "影片名稱")
        or ""
    ).strip()
    title_fake = bool(t) and is_fake_forum_title_fast(t, code)
    film_fake = bool(film) and is_fake_forum_title_fast(film, code)
    film_ok = bool(film) and not film_fake
    title_ok = bool(t) and not title_fake
    # 帖题/影片名都是假壳 → 不占桶
    if not film_ok and not title_ok:
        return -100

    score = 0
    if "出演女优" in d or "出演女優" in d or "演出者" in d or "出演者" in d:
        score += 70
    if film_ok:
        score += 80
    elif "影片名称" in d or "影片名稱" in d:
        score += 20
    elif "资源名称" in d or "资源名稱" in d:
        score += 30
    if title_ok:
        score += 40
    elif title_fake:
        score -= 80

    # 只看题/片名短文本，避免整段 description 数汉字拖慢
    tip = f"{film}\n{t}"
    cjk = sum(1 for ch in tip if "\u4e00" <= ch <= "\u9fff")
    kana = any("\u3040" <= ch <= "\u30ff" for ch in tip)
    if title_ok or film_ok:
        if cjk >= 6 and not kana:
            score += 100
        elif cjk >= 4:
            score += 35
    if kana:
        score -= 50
    score += min(cjk, 40)
    return score


def _append_title_post(
    bucket: list[dict[str, Any]],
    post: dict[str, Any],
    *,
    code: str = "",
    cap: int = PREFIX_POSTS_PER_CODE,
) -> None:
    """桶未满则追加；已满则用更高分替换最弱一条。假壳帖不进桶。"""
    if cap <= 0:
        return
    # 已打过分（带 _ks）的帖子复用，避免同一帖重复解析 description
    new_sc = (
        int(post["_ks"])
        if "_ks" in post
        else _post_zh_keep_score(
            str(post.get("description") or ""),
            str(post.get("title") or ""),
            code=code,
        )
    )
    if new_sc < 0:
        return
    item = {
        "description": post.get("description") or "",
        "title": post.get("title") or "",
        "_ks": new_sc,
    }
    if len(bucket) < cap:
        bucket.append(item)
        return
    worst_i = 0
    worst_sc = int(bucket[0].get("_ks") or 0)
    for i in range(1, len(bucket)):
        sc = int(bucket[i].get("_ks") or 0)
        if sc < worst_sc:
            worst_sc = sc
            worst_i = i
    if new_sc > worst_sc:
        bucket[worst_i] = item


def _row_codes_and_pack(
    prefix: str, row: dict[str, Any]
) -> tuple[list[str], bool, str, str]:
    """从扫库行抽番号与合集标记，返回 (codes, pack, description, 帖题)。"""
    from app.search.pack_bleed import get_description_field, own_maker_codes_for_index_row

    desc = str(row.get("description") or "")
    post_title = str(row.get("title") or "").strip()
    filename = str(row.get("filename") or "").strip()
    film = str(
        get_description_field(desc, "影片名称")
        or get_description_field(desc, "影片名稱")
        or ""
    ).strip()
    resource = str(
        get_description_field(desc, "资源名称")
        or get_description_field(desc, "资源名稱")
        or ""
    ).strip()
    codes, pack = own_maker_codes_for_index_row(
        prefix=prefix,
        filename=filename,
        title=post_title,
        film=film,
        resource=resource,
        description=desc,
        hash_=str(row.get("hash") or "") or None,
        ed2k_links=row.get("ed2k_links"),
        ed2k_link=str(row.get("ed2k_link") or "") or None,
    )
    return codes, pack, desc, post_title


def _collect_posts_by_code_from_rows(
    prefix: str, rows: list[dict[str, Any]]
) -> dict[str, list[dict[str, Any]]]:
    """从扫库行抽番号→帖桶（只收标题，不碰封面）。合集不灌共享描述。"""
    posts_by_code: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        codes, pack, desc, seed_title = _row_codes_and_pack(prefix, row)
        if pack or not codes:
            continue
        for code in codes:
            code = _std_code_key(code, pad=0)
            if not code:
                continue
            if desc.strip() or seed_title:
                _append_title_post(
                    posts_by_code.setdefault(code, []),
                    {"description": desc, "title": seed_title},
                    code=code,
                )
    return posts_by_code


def _scan_prefix_zh_boost_rows(prefix: str) -> list[dict[str, Any]]:
    """专扫中文帖题补译名（只扫 title，避免 description ILIKE 拖垮索引）。"""
    if not PREFIX_ZH_BOOST_ENABLED:
        return []
    needle = str(prefix or "").strip()
    if not needle:
        return []
    contains = f"%{escape_ilike(needle)}-%"
    # 仅 title：通常有 trigram/btree 可用；description 全表 ILIKE 是上次变慢主因
    sql = f"""
SELECT
  r.hash,
  r.filename,
  r.created_at,
  rs.title,
  rs.description,
  rs.preview_images,
  rs.board_fid,
  rs.board_name,
  rs.ed2k_links
FROM resource_sources rs
JOIN ed2k_resources r ON r.hash = rs.hash
WHERE TRUE
{PUBLIC_RESOURCE_FILTER}
  AND rs.title ILIKE %s ESCAPE '\\'
  AND rs.title ~ '[一-龥]'
  AND rs.title !~ '[ぁ-んァ-ン]'
ORDER BY rs.created_at DESC NULLS LAST
LIMIT %s
"""
    try:
        return _query_prefix_scan(sql, [contains, PREFIX_ZH_BOOST_ROW_CAP])
    except Exception as err:
        log.warning("prefix zh boost scan %s failed: %s", needle, err)
        return []


def _apply_zh_title_boost(
    prefix: str, indexed: dict[str, Any], *, region: str | None = None
) -> dict[str, Any]:
    """对尚无中文题的番号，用中文补扫结果重选 forumTitle。"""
    from app.search.forum_seed import pick_forum_seed_from_posts
    from app.core.region_meta import indexes_forum_actors
    from app.search.forum_title import is_fake_forum_title, is_likely_chinese

    if not PREFIX_ZH_BOOST_ENABLED:
        return indexed

    want_actors = indexes_forum_actors(region)

    items = indexed.get("items")
    if not isinstance(items, list) or not items:
        return indexed
    need = [
        it
        for it in items
        if isinstance(it, dict)
        and (
            not str(it.get("forumTitle") or "").strip()
            or is_fake_forum_title(
                str(it.get("forumTitle") or ""), str(it.get("code") or "")
            )
            or not is_likely_chinese(str(it.get("forumTitle") or ""))
        )
    ]
    # 几乎都已是中文则跳过补扫
    if not need or len(need) < max(3, len(items) // 50):
        return indexed

    boost_rows = _scan_prefix_zh_boost_rows(prefix)
    if not boost_rows:
        return indexed
    posts_by_code = _collect_posts_by_code_from_rows(prefix, boost_rows)
    if not posts_by_code:
        return indexed

    # AARM-015 / AARM-15 对齐
    posts_norm: dict[str, list[dict[str, Any]]] = {}
    for code, posts in posts_by_code.items():
        key = _std_code_key(code)
        bucket = posts_norm.setdefault(key, [])
        for p in posts:
            _append_title_post(bucket, p, code=code)

    upgraded = 0
    for it in need:
        code = str(it.get("code") or "").strip()
        posts = posts_norm.get(_std_code_key(code)) or posts_by_code.get(code) or []
        if not posts:
            continue
        posts = sorted(
            posts,
            key=lambda p: -int(
                p.get("_ks")
                if "_ks" in p
                else _post_zh_keep_score(
                    str(p.get("description") or ""),
                    str(p.get("title") or ""),
                    code=code,
                )
            ),
        )
        seed = pick_forum_seed_from_posts(
            code,
            posts,
            max_posts=PREFIX_POSTS_PER_CODE,
            want_actors=want_actors,
        )
        title = str(seed.get("title") or "").strip()
        if not is_likely_chinese(title) or is_fake_forum_title(title, code):
            continue
        actors = (
            seed.get("actors") if isinstance(seed.get("actors"), list) else []
        )
        # 女优名不当中文补译：会把日文正片标题冲掉
        from app.search.forum_seed import (
            _looks_like_bare_actor_title,
            _title_is_actor_echo,
        )

        if _title_is_actor_echo(title, [str(a) for a in actors if str(a).strip()]):
            continue
        # 人名形短串一律不补；空标题时也不许用女优名填坑
        if _looks_like_bare_actor_title(title):
            continue
        it["forumTitle"] = title
        if want_actors:
            if actors:
                it["forumActors"] = [str(a) for a in actors if str(a).strip()]
            else:
                it.pop("forumActors", None)
        else:
            it.pop("forumActors", None)
        upgraded += 1

    if upgraded:
        log.info(
            "prefix %s zh-boost: +%s chinese titles (from %s rows)",
            prefix,
            upgraded,
            len(boost_rows),
        )
    indexed["zhBoostRows"] = len(boost_rows)
    indexed["zhBoostUpgraded"] = upgraded
    return indexed
