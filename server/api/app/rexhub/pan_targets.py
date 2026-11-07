"""115 保存目录与来源解析。

settings 配置端点（/api/settings/p115*）与网盘转存端点（/api/pan/offline、/api/pan/share）
共用的纯逻辑：来源 → 目标目录映射。
"""


from typing import Any


# 转存入口只有三类：搜索 / 影视 / 片商，全部直存目标目录
P115_SOURCES = ("search", "media", "maker")

# 旧配置键（含片商六区）统一收敛到三类
_LEGACY_SOURCE_ALIASES = {
    "warehouse": "search",
    "movie": "media",
    "tv": "media",
    "makers": "maker",
    "japan_censored": "maker",
    "japan_uncensored": "maker",
    "japan_amateur": "maker",
    "fc2": "maker",
    "china": "maker",
    "western": "maker",
}


def _normalize_source(source: str | None, region: str | None = None) -> str:
    key = str(source or "").strip().lower()
    if key in P115_SOURCES:
        return key
    if key in _LEGACY_SOURCE_ALIASES:
        return _LEGACY_SOURCE_ALIASES[key]
    # 旧版片商入口可能只带 region
    if str(region or "").strip():
        return "maker"
    return "search"


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
    """Per-entry save dirs: search / media / maker.

    Legacy ``folder_*`` → search；``targets.media`` / ``movie`` / ``tv`` → media；
    ``targets.makers`` 或任一旧片商分区键 → maker。
    """
    legacy_cid = str((raw or {}).get("folder_cid") or (raw or {}).get("folderCid") or "0").strip() or "0"
    legacy_name = str((raw or {}).get("folder_name") or (raw or {}).get("folderName") or "").strip()
    fallback = {"folderCid": legacy_cid, "folderName": legacy_name}
    src = (raw or {}).get("targets") if isinstance(raw, dict) else None
    src = src if isinstance(src, dict) else {}

    def legacy(*keys: str) -> dict[str, str] | None:
        for key in keys:
            if _target_usable(src.get(key)):
                return _normalize_target_folder(src.get(key))
        return None

    legacy_media = legacy("media", "movie", "tv")
    legacy_maker = legacy(
        "makers",
        "japan_censored",
        "japan_uncensored",
        "japan_amateur",
        "fc2",
        "china",
        "western",
    )

    out: dict[str, dict[str, str]] = {}
    for key in P115_SOURCES:
        item = src.get(key)
        if _target_usable(item):
            out[key] = _normalize_target_folder(item)
        elif key == "media" and legacy_media is not None:
            out[key] = dict(legacy_media)
        elif key == "maker" and legacy_maker is not None:
            out[key] = dict(legacy_maker)
        else:
            out[key] = dict(fallback)
    return out


def _resolve_p115_folder(
    raw: dict[str, Any] | None,
    *,
    source: str | None = None,
    folder_cid: str | None = None,
    region: str | None = None,
) -> tuple[str, str]:
    """Return (cid, name). Explicit folder_cid wins; else targets[source]."""
    targets = _p115_targets(raw)
    if folder_cid is not None and str(folder_cid).strip() != "":
        cid = str(folder_cid).strip() or "0"
        for t in targets.values():
            if t["folderCid"] == cid and t["folderName"]:
                return cid, t["folderName"]
        return cid, ""
    t = targets[_normalize_source(source, region)]
    return t["folderCid"], t["folderName"]
