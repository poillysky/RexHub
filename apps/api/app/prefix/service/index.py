"""前缀索引构建：扫库行 → 番号条目（封面 + 中文标题 + 女优）。

封面上锁"列表首条 + 备用图"，标题全站同番号帖参与（讨论区中文可覆盖），
最终按 code_sort_key 输出并剔除跨番号共享垃圾封面。
"""

from typing import Any

from app.search.av import code_sort_key

from .codes import _std_code_key
from .covers import (
    _append_cover_fallbacks,
    _has_still_cover,
    _is_domestic_or_clear_uncensored_row,
    _prefix_tile_covers,
    _sort_for_prefix_cover,
    _strip_shared_junk_covers,
)
from .params import PREFIX_POSTS_PER_CODE
from .patterns import _is_japan_censored_style_prefix
from .posts import _append_title_post, _post_zh_keep_score


def _rows_to_prefix_index(
    prefix: str,
    rows: list[dict[str, Any]],
    *,
    region: str | None = None,
) -> dict[str, Any]:
    # 封面 = 点进番号后默认列表第一条的预览图（created_at 新→旧）
    from app.search.forum_seed import pick_forum_seed_from_posts
    from app.search.pack_bleed import get_description_field
    from app.core.region_board_allowlist import board_fid_allowed, normalize_region

    ordered = _sort_for_prefix_cover(rows)
    region_key = normalize_region(region)
    from app.core.region_meta import indexes_forum_actors
    from app.search.pack_bleed import own_maker_codes_for_index_row

    want_actors = indexes_forum_actors(region_key or region)
    # 无 region 时：有码风格前缀仍排除国产/明确无码（旧行为）
    skip_foreign = (not region_key) and _is_japan_censored_style_prefix(prefix)
    by_code: dict[str, dict[str, Any]] = {}
    posts_by_code: dict[str, list[dict[str, Any]]] = {}
    for row in ordered:
        fid = str(row.get("board_fid") or "").strip()
        # 封面：仅本分区；标题：全站同番号帖都可参与（便于讨论区中文译名）
        cover_ok = True
        if region_key and not board_fid_allowed(fid, region_key):
            cover_ok = False
        if skip_foreign and _is_domestic_or_clear_uncensored_row(row):
            cover_ok = False
        desc = str(row.get("description") or "")
        post_title = str(row.get("title") or "").strip()
        filename = str(row.get("filename") or "").strip()
        # 标题只用帖题；文件名仅参与抽码，不当标题兜底（非正常宁缺）
        seed_title = post_title
        # 抽码：文件名/帖题 + 【影片名称】/【资源名称】（描述里常有番号）
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
        if not codes:
            continue
        for code in codes:
            code = _std_code_key(code, pad=0)
            if not code:
                continue
            # 合集帖：共享描述/女优属其中一部，勿灌进本资源以外的番号
            if (desc.strip() or seed_title) and not pack:
                _append_title_post(
                    posts_by_code.setdefault(code, []),
                    {"description": desc, "title": seed_title},
                    code=code,
                )
            if not cover_ok:
                continue
            covers = _prefix_tile_covers(
                code, row.get("preview_images"), pack=pack
            )
            prev = by_code.get(code)
            if not prev:
                # 无预览图也收录番号；有图时再填封面
                by_code[code] = {
                    "code": code,
                    "coverUrl": covers[0] if covers else None,
                    "coverUrls": covers,
                }
                continue
            if not covers:
                continue
            # 列表首条锁定；后排只补备用。脆弱图床沉底后刷新 coverUrl
            if _has_still_cover(covers) and not _has_still_cover(
                prev.get("coverUrls")
            ):
                by_code[code] = {
                    "code": code,
                    "coverUrl": covers[0],
                    "coverUrls": covers,
                }
            else:
                merged = _append_cover_fallbacks(
                    list(prev.get("coverUrls") or []), covers, code=code
                )
                prev["coverUrls"] = merged
                prev["coverUrl"] = merged[0] if merged else None
    # 仅保留本分区已收录番号的标题；讨论区中文可覆盖日文
    for code, entry in by_code.items():
        posts = posts_by_code.get(code) or []
        # 多帖桶：中文分高的先扫，保证聚合窗口内中文优先
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
        actors = (
            seed.get("actors")
            if want_actors and isinstance(seed.get("actors"), list)
            else []
        )
        # pick_forum_seed_from_posts 已保证可索引或空
        if title:
            entry["forumTitle"] = title
        if want_actors and actors:
            entry["forumActors"] = [str(a) for a in actors if str(a).strip()]
    items = sorted(by_code.values(), key=lambda it: code_sort_key(it["code"]))
    _strip_shared_junk_covers(items)
    return {"items": items, "matchedRows": len(rows)}
