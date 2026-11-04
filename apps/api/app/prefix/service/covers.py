"""封面挑选、排序与清洗。

职责：番号格封面挑选（防合集串图）、稳定图床优先、脆弱图床沉底、
共享垃圾封面剔除、BT 板只补空缺的排序策略。
"""

import re
from typing import Any


BT_BOARD_ROOT_FID_SET = {
    "2",
    "36",
    "37",
    "38",
    "39",
    "103",
    "104",
    "107",
    "151",
    "152",
    "160",
}


def _is_bt_board_fid(fid: Any) -> bool:
    raw = str(fid or "").strip()
    if not raw:
        return False
    root = raw.split(":", 1)[0]
    return root in BT_BOARD_ROOT_FID_SET


def _created_at_ms(v: Any) -> float:
    if v is None:
        return 0.0
    if hasattr(v, "timestamp"):
        try:
            return float(v.timestamp()) * 1000
        except Exception:
            return 0.0
    try:
        from datetime import datetime

        if isinstance(v, str):
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp() * 1000
    except Exception:
        return 0.0
    return 0.0


def _sort_for_prefix_cover(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """前缀封面排序：sehua 主库优先，BT 只补空缺；同源内按 created_at 新→旧。"""
    indexed = list(enumerate(rows))
    indexed.sort(
        key=lambda pair: (
            1 if _is_bt_board_fid(pair[1].get("board_fid")) else 0,
            -_created_at_ms(pair[1].get("created_at")),
            pair[0],
        )
    )
    return [row for _, row in indexed]


def _is_gif_url(url: str) -> bool:
    path = str(url or "").lower().split("?", 1)[0]
    return path.endswith(".gif")


# TLS 握手直接断 / 长期不可达的图床：有其它源时不要排第一（避免干等 onError）
_FLAKY_COVER_HOST_RE = re.compile(
    r"xms45\.com|"
    r"imghost\.biz|"
    r"gifyu\.com|"
    r"imagetwist\.com",
    re.I,
)


def _is_flaky_cover_host(url: str) -> bool:
    return bool(_FLAKY_COVER_HOST_RE.search(url or ""))


def _prefer_stable_cover_urls(urls: list[str]) -> list[str]:
    """稳定图床在前，脆弱图床垫后；有稳定源时首张就不会卡 TLS。"""
    good = [u for u in urls if u and not _is_flaky_cover_host(u)]
    flaky = [u for u in urls if u and _is_flaky_cover_host(u)]
    return good + flaky


def _append_cover_fallbacks(
    prev: list[str], nxt: list[str], *, code: str = ""
) -> list[str]:
    from app.search.pack_bleed import image_url_matches_maker_code, is_jacket_cover_url

    out = list(prev)
    seen = set(out)
    for u in nxt:
        if not u or u in seen:
            continue
        # 合集帖备用图：拒其它番号的 DMM/netcdn 夹克
        if (
            code
            and is_jacket_cover_url(u)
            and not image_url_matches_maker_code(u, code)
        ):
            continue
        seen.add(u)
        out.append(u)
        if len(out) >= 6:
            break
    # 合并后再把脆弱图床沉底，保证 coverUrl 优先稳图
    return _prefer_stable_cover_urls(out)


def _strip_shared_junk_covers(items: list[dict[str, Any]]) -> None:
    url_codes: dict[str, set[str]] = {}
    for it in items:
        for u in it.get("coverUrls") or []:
            if not u:
                continue
            url_codes.setdefault(u, set()).add(it["code"])
    junk = {url for url, codes in url_codes.items() if len(codes) >= 4}
    if not junk:
        return
    for it in items:
        nxt = [u for u in (it.get("coverUrls") or []) if u not in junk]
        if len(nxt) == len(it.get("coverUrls") or []):
            continue
        it["coverUrls"] = nxt[:6]
        it["coverUrl"] = it["coverUrls"][0] if it["coverUrls"] else None


def _prefix_tile_covers(
    code: str, images: Any, *, pack: bool = False
) -> list[str]:
    """番号格封面：按番号过滤片商夹克（防合集串图），静图优先，脆弱图床后置。"""
    from app.search.pack_bleed import image_url_matches_maker_code, pick_covers_for_code

    ordered = pick_covers_for_code(str(code or ""), images, limit=4)
    if pack:
        # 合集帖预览常混多番号：只留能对上本番号的夹克，避免锁死错图
        matched = [
            u for u in ordered if image_url_matches_maker_code(u, str(code or ""))
        ]
        ordered = matched
    if not ordered:
        return []
    stills = [u for u in ordered if not _is_gif_url(u)]
    pool = stills or ordered
    return _prefer_stable_cover_urls(pool)[:4]


def _has_still_cover(urls: list[str] | None) -> bool:
    return any(u and not _is_gif_url(u) for u in (urls or []))


def _is_domestic_or_clear_uncensored_row(row: dict[str, Any]) -> bool:
    """有码风格前缀：封面只取日本有码白名单内的帖。"""
    from app.core.region_board_allowlist import board_fid_allowed

    fid = str(row.get("board_fid") or "").strip()
    if not board_fid_allowed(fid, "japan_censored"):
        return True
    return False
