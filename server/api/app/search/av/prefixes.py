"""前缀表与规范映射：别名归一 / 欧美厂牌集合 / 番号形态判定。

prefix-code-shapes.json 静态表 + av-makers.western.json 配置按需合并；
模块级 dict/set 为进程内单例，解析（parse）与抽码（extract）共用。
"""


import re
from app.core.maps_paths import load_json_map


_SHAPE_DOC = load_json_map("prefix-code-shapes.json")
WESTERN_STUDIO_PREFIXES = set(_SHAPE_DOC.get("westernPrefixes") or [])
DATE6_PREFIX_LABEL: dict[str, str] = dict(_SHAPE_DOC.get("date6Labels") or {})
PREFIX_CANONICAL: dict[str, str] = dict(_SHAPE_DOC.get("canonical") or {})
PREFIX_SHAPE: dict[str, str] = dict(_SHAPE_DOC.get("shapes") or {})


def _escape_re(s: str) -> str:
    return re.escape(s)


def _prefix_key(prefix: str) -> str:
    return re.sub(r"[_\s]+", "-", (prefix or "").strip().upper())


def _western_key(prefix: str) -> str:
    return re.sub(r"[_\-\s]", "", (prefix or "").strip().upper())


def canonical_prefix(prefix: str) -> str:
    """别名 → 规范前缀（1PONDO→1PON、GACHINCO→GACHI、TOKYO-HOT→TOKYOHOT）。"""
    key = _prefix_key(prefix)
    compact = _western_key(prefix)
    if not key and not compact:
        return ""
    if key in PREFIX_CANONICAL:
        return PREFIX_CANONICAL[key]
    if compact in PREFIX_CANONICAL:
        return PREFIX_CANONICAL[compact]
    return key or compact


def prefixes_equivalent(a: str, b: str) -> bool:
    ca, cb = canonical_prefix(a), canonical_prefix(b)
    return bool(ca) and ca == cb


def prefix_aliases(prefix: str) -> frozenset[str]:
    """与 prefix 同属一组的全部写法（含 canonical）。"""
    can = canonical_prefix(prefix)
    if not can:
        return frozenset()
    out = {can, _prefix_key(prefix), _western_key(prefix)}
    for k, v in PREFIX_CANONICAL.items():
        if v == can:
            out.add(k)
            out.add(_western_key(k))
    return frozenset(x for x in out if x)


_western_config_loaded = False


def _ensure_western_from_config() -> None:
    """把 av-makers.western.json 前缀并入欧美集合（配置为准，硬编码作底）。"""
    global _western_config_loaded
    if _western_config_loaded:
        return
    _western_config_loaded = True
    try:
        from app.core.maps_paths import av_makers

        path = av_makers("western")
        if not path.exists():
            return
        import json

        data = json.loads(path.read_text(encoding="utf-8"))
        for m in data if isinstance(data, list) else []:
            if not isinstance(m, dict):
                continue
            for p in m.get("prefixes") or []:
                wk = _western_key(str(p))
                if not wk:
                    continue
                WESTERN_STUDIO_PREFIXES.add(wk)
                PREFIX_SHAPE[wk] = "western_date"
                PREFIX_SHAPE[_prefix_key(str(p))] = "western_date"
    except Exception:
        pass


def is_western_studio_prefix(prefix: str) -> bool:
    _ensure_western_from_config()
    return _western_key(prefix) in WESTERN_STUDIO_PREFIXES


def resolve_maker_shape(prefix: str) -> str:
    _ensure_western_from_config()
    key = _prefix_key(prefix)
    compact = _western_key(prefix)
    if key in PREFIX_SHAPE:
        return PREFIX_SHAPE[key]
    if compact in PREFIX_SHAPE:
        return PREFIX_SHAPE[compact]
    if key == "FC2-PPV" or compact == "FC2PPV":
        return "fc2ppv"
    if is_western_studio_prefix(prefix):
        return "western_date"
    return "std"


def _china_prefix_set() -> set[str]:
    try:
        from app.prefix.ranges import load_china_prefixes

        return load_china_prefixes()
    except Exception:
        return set()
