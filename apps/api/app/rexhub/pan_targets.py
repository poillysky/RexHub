"""115 保存目录与来源解析。

settings 配置端点（/api/settings/p115*）与网盘转存端点（/api/pan/offline、/api/pan/share）
共用的纯逻辑：来源 → 目标目录映射、最近接收判定。放中立模块避免两端互相 import。
"""


from typing import Any


P115_MAKER_REGION_SOURCES = (
    "japan_censored",
    "japan_uncensored",
    "japan_amateur",
    "fc2",
    "china",
    "western",
)

P115_SOURCES = (
    "warehouse",
    "movie",
    "tv",
    *P115_MAKER_REGION_SOURCES,
)

# 先入「最近接收」、再移到指定目录：仅影视 + 片商六区
# 仓库（ed2k/磁力）直存 warehouse 目录（云下载），不经「最近接收」
P115_INBOX_RELOCATE_SOURCES = frozenset(
    {"movie", "tv", "makers", "media", *P115_MAKER_REGION_SOURCES}
)


def _use_receive_inbox(source: str | None) -> bool:
    """影视/片商走中转；warehouse / 未知默认直存目标目录。"""
    key = (source or "warehouse").strip().lower()
    if key == "media":
        key = "movie"
    if key == "warehouse":
        return False
    return key in P115_INBOX_RELOCATE_SOURCES


def _normalize_target_folder(raw: Any) -> dict[str, str]:
    if not isinstance(raw, dict):
        return {"folderCid": "0", "folderName": ""}
    cid = str(raw.get("folder_cid") or raw.get("folderCid") or "0").strip() or "0"
    name = str(raw.get("folder_name") or raw.get("folderName") or "").strip()
    return {"folderCid": cid, "folderName": name}


def _target_usable(item: Any) -> bool:
    return isinstance(item, dict) and (
        item.get("folder_cid") is not None
        or item.get("folderCid") is not None
        or item.get("folder_name") is not None
        or item.get("folderName") is not None
    )


def _p115_targets(raw: dict[str, Any] | None) -> dict[str, dict[str, str]]:
    """Per-entry save dirs: warehouse / movie / tv / 片商六区.

    Legacy ``folder_*`` → warehouse. Legacy ``targets.media`` → movie & tv.
    Legacy ``targets.makers`` → 六区共用（直至分别配置）。
    """
    legacy_cid = str((raw or {}).get("folder_cid") or (raw or {}).get("folderCid") or "0").strip() or "0"
    legacy_name = str((raw or {}).get("folder_name") or (raw or {}).get("folderName") or "").strip()
    warehouse_fallback = {"folderCid": legacy_cid, "folderName": legacy_name}
    src = (raw or {}).get("targets") if isinstance(raw, dict) else None
    legacy_media = (
        _normalize_target_folder(src.get("media"))
        if isinstance(src, dict) and _target_usable(src.get("media"))
        else None
    )
    legacy_makers = (
        _normalize_target_folder(src.get("makers"))
        if isinstance(src, dict) and _target_usable(src.get("makers"))
        else None
    )
    out: dict[str, dict[str, str]] = {}
    for key in P115_SOURCES:
        item = src.get(key) if isinstance(src, dict) else None
        if _target_usable(item):
            out[key] = _normalize_target_folder(item)
        elif key == "warehouse":
            out[key] = warehouse_fallback
        elif key in ("movie", "tv") and legacy_media is not None:
            out[key] = dict(legacy_media)
        elif key in P115_MAKER_REGION_SOURCES and legacy_makers is not None:
            out[key] = dict(legacy_makers)
        else:
            out[key] = dict(warehouse_fallback)
    return out


def _region_folder_label(region: str | None) -> str:
    """刮削区 id / 中文标签 → 115 子目录名（日本有码 / 日本无码 / …）。"""
    from app.core.region_meta import REGION_META, resolve_fs_region

    raw = str(region or "").strip()
    if not raw:
        return ""
    for meta in REGION_META.values():
        label = str(meta.get("label") or "")
        if raw == label or raw.casefold() == label.casefold():
            return label
    key = resolve_fs_region(raw) or (raw if raw in REGION_META else "")
    if key and key in REGION_META:
        return str(REGION_META[key].get("label") or key)
    return ""


def _maker_source_from_region(region: str | None) -> str | None:
    """region / 中文标签 → 片商六区 source；无法识别则 None。"""
    from app.core.region_meta import resolve_fs_region

    rid = str(region or "").strip()
    if not rid:
        return None
    mapped = (resolve_fs_region(rid) or rid).strip().lower()
    if mapped in P115_MAKER_REGION_SOURCES:
        return mapped
    label = _region_folder_label(rid)
    for mid in P115_MAKER_REGION_SOURCES:
        if label and _region_folder_label(mid) == label:
            return mid
    low = rid.casefold()
    if "fc2" in low:
        return "fc2"
    if "素人" in rid or "amateur" in low:
        return "japan_amateur"
    if "国产" in rid or low in {"china", "domestic"}:
        return "china"
    if "欧美" in rid or low in {"western", "europe"}:
        return "western"
    if "有码" in rid:
        return "japan_censored"
    if "无码" in rid:
        return "japan_uncensored"
    return None


def _resolve_p115_folder(
    raw: dict[str, Any] | None,
    *,
    source: str | None = None,
    folder_cid: str | None = None,
    region: str | None = None,
) -> tuple[str, str]:
    """Return (cid, name). Explicit folder_cid wins; else targets[source].

    片商跳转后若前端 source 丢失为 warehouse，仍可用 region 映射到六区目录。
    """
    targets = _p115_targets(raw)
    if folder_cid is not None and str(folder_cid).strip() != "":
        cid = str(folder_cid).strip() or "0"
        for t in targets.values():
            if t["folderCid"] == cid and t["folderName"]:
                return cid, t["folderName"]
        return cid, ""
    key = (source or "warehouse").strip().lower()
    # legacy aliases
    if key == "media":
        key = "movie"
    if key == "makers":
        key = "japan_censored"
    # source 未带分区时，用 region / 中文标签兜底
    if key == "warehouse" or key not in P115_SOURCES:
        mapped = _maker_source_from_region(region)
        if mapped:
            key = mapped
    if key not in P115_SOURCES:
        key = "warehouse"
    t = targets[key]
    return t["folderCid"], t["folderName"]
