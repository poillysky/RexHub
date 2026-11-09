"""六区元数据与番号前缀规范化（供 prefix 扫库 / 搜索共用）。"""


from app.core.maps_paths import regions_doc

_REGION_DOC = regions_doc()
REGION_META: dict[str, dict[str, str]] = {
    str(k): {str(sk): str(sv) for sk, sv in dict(v).items()}
    for k, v in dict(_REGION_DOC.get("regions") or {}).items()
}

# 仅日本有码把女优名写入索引副文案；其它区只保留标题
# （原 japan_gravure / 日本写真已并入 japan_censored）
FORUM_ACTORS_INDEX_REGIONS = frozenset({"japan_censored"})

# 旧区 id / 中文标签 → 现 canonical（写真并入有码）
_LEGACY_REGION_REDIRECT: dict[str, str] = {
    "japan_gravure": "japan_censored",
    "gravure": "japan_censored",
    "写真": "japan_censored",
    "日本写真": "japan_censored",
}


def resolve_fs_region(region: str | None) -> str | None:
    """前端 / 白名单 region → 六区 id（写真已并入有码）。"""
    raw = str(region or "").strip()
    if not raw:
        return None
    key = raw.lower()
    # 别名表（含 japan_gravure → japan_censored）
    aliases = {
        str(k).strip().lower(): str(v).strip()
        for k, v in dict(_REGION_DOC.get("aliases") or {}).items()
        if str(k).strip() and str(v).strip()
    }
    if key in aliases:
        mapped = aliases[key]
        if mapped in REGION_META:
            return mapped
        # aliases 里 japan → japan（粗粒度）等：再走下面
        key = mapped.lower()
    if raw in _LEGACY_REGION_REDIRECT:
        return _LEGACY_REGION_REDIRECT[raw]
    if key in _LEGACY_REGION_REDIRECT:
        return _LEGACY_REGION_REDIRECT[key]
    if key in ("amateur", "素人"):
        return "japan_amateur"
    if key in ("fc2ppv",):
        return "fc2"
    if key in REGION_META:
        return key
    # 中文全称
    for rid, meta in REGION_META.items():
        label = str(meta.get("label") or "")
        if raw == label or key == label.casefold():
            return rid
    return None


def indexes_forum_actors(region: str | None) -> bool:
    """是否索引女优（日本有码，含原写真前缀）。"""
    rid = resolve_fs_region(region)
    return bool(rid and rid in FORUM_ACTORS_INDEX_REGIONS)


