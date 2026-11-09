"""刮削后元数据优化（色花堂中文标题 / 演员·标签映射 / 简介换行）。"""


import json
import re
import unicodedata
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.core.maps_paths import load_str_map

MAPPING_LANGS = frozenset({"zh-CN", "zh-TW", "ja", "en"})
# 色花堂字段偶发装饰：首尾 +/-/~ / 全角～
_ACTOR_DIRTY_RE = re.compile(r"^[\+\-\~\～\s　]+|[\+\-\~\～\s　]+$")

# 繰り返し記号「々」(U+3005)：表示前一个字符重复。日文源写 `佐々波綾`，
# 中文映射表键/标准名写 `佐佐波綾` / `佐佐波绫`——不做字形归一就永远对不上，
# 表现为「overview 有中文候选但合并非中文」之类的假阴性（表内含 `々` 的键 117 个）。
# 归一为「前字重复」是确定性且无损的（々 永远只表示重复），故作为通用规则前置。
_ITER_MARK = "\u3005"


def _iter_fold(s: str) -> str:
    """`々` → 重复前一个字符：`佐々波綾` → `佐佐波綾`。"""
    s = str(s or "")
    if _ITER_MARK not in s:
        return s
    out: list[str] = []
    for ch in s:
        if ch == _ITER_MARK and out:
            out.append(out[-1])
        else:
            out.append(ch)
    return "".join(out)





# 繁 / 日 → 简 常用变体对（空格分隔，每对 2 字）。仅作**映射兜底**：精确命中仍优先，
# 故不会改变既有正确结果；但能根治「繁简分裂」——映射表只写了 `義母` 时，源站的
# `义母` 也能收敛到同一标准名，不必逐字往表里补（历史反复踩此坑）。

_TAG_VARIANT_FOLD: dict[str, str] = load_str_map("tags.variant-fold.zh-CN.json")
_TAG_VARIANT_TRANS = str.maketrans(_TAG_VARIANT_FOLD) if _TAG_VARIANT_FOLD else {}


DEFAULT_METADATA_OPTIMIZE: dict[str, Any] = {
    "useForumZhTitle": False,
    "enableActorMapping": True,
    "enableTagMapping": True,
    "compactOutlineNewlines": True,
    "mappingLanguage": "zh-CN",
}


def _clean_actor_raw(name: str) -> str:
    s = str(name or "").strip()
    if not s:
        return ""
    # 半角片假名等：倉本ｽﾐﾚ → 倉本すみれ，便于映射命中
    s = unicodedata.normalize("NFKC", s)
    # 繰り返し記号归一：佐々波綾 → 佐佐波綾（否则永不命中只写 `佐佐…` 的表键）
    s = _iter_fold(s)
    s = _ACTOR_DIRTY_RE.sub("", s).strip()
    # 完整括号备注：愛染恭子（青山涼子）
    s = re.sub(r"\s*[\(（][^)）]*[\)）]\s*$", "", s).strip()
    # 半截开括号（JavBus span 截断）：愛染恭子（
    s = re.sub(r"\s*[\(（][^)）]*$", "", s).strip()
    s = s.rstrip("（(").strip()
    return re.sub(r"\s+", " ", s)


_CACHED_MAPPING_LANG: str | None = None
_SETTING_MAP_ENABLED: bool | None = None


def mapping_language_from_settings() -> str:
    """读 library / 旧 scrape 配置里的 mappingLanguage，失败则 zh-CN。"""
    global _CACHED_MAPPING_LANG
    if _CACHED_MAPPING_LANG is not None:
        return _CACHED_MAPPING_LANG
    try:
        import app.core.settings_store as settings_store

        raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
        if not isinstance(raw, dict):
            lang = str(DEFAULT_METADATA_OPTIMIZE["mappingLanguage"])
        else:
            opt = normalize_metadata_optimize(
                raw.get("metadataOptimize") or raw.get("metadata_optimize")
            )
            lang = str(opt["mappingLanguage"])
    except Exception:
        lang = str(DEFAULT_METADATA_OPTIMIZE["mappingLanguage"])
    _CACHED_MAPPING_LANG = lang
    return lang


def normalize_actor_names(
    actors: list[str] | None,
    *,
    lang: str | None = None,
    enable: bool | None = None,
) -> list[str]:
    """索引/聚合后把女优名规范成映射表标准名（去重保序）。

    enable=None 时跟刮削「启用演员映射」；索引展示默认开映射。
    """
    raw_list = [str(a).strip() for a in (actors or []) if str(a or "").strip()]
    if not raw_list:
        return []

    use_map = True if enable is None else bool(enable)
    if enable is None:
        try:
            import app.core.settings_store as settings_store

            raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
            if isinstance(raw, dict):
                opt = normalize_metadata_optimize(
                    raw.get("metadataOptimize") or raw.get("metadata_optimize")
                )
                use_map = bool(opt["enableActorMapping"])
        except Exception:
            use_map = True

    if not use_map:
        # 仍清脏装饰并去重
        out: list[str] = []
        seen: set[str] = set()
        for a in raw_list:
            name = _clean_actor_raw(a) or a
            if name in seen:
                continue
            seen.add(name)
            out.append(name)
        return out

    return polish_actress_names(
        raw_list, lang=lang or mapping_language_from_settings(), enable_mapping=True
    )


def normalize_metadata_optimize(raw: Any) -> dict[str, Any]:
    src = raw if isinstance(raw, dict) else {}
    lang = str(
        src.get("mappingLanguage")
        or src.get("mapping_language")
        or DEFAULT_METADATA_OPTIMIZE["mappingLanguage"]
    ).strip()
    if lang in {"zh", "zh_cn", "zh-cn", "cn", "hans", "简体", "简体中文"}:
        lang = "zh-CN"
    elif lang in {"zh_tw", "zh-tw", "tw", "hant", "繁体", "繁體", "繁体中文"}:
        lang = "zh-TW"
    elif lang in {"jp", "japanese", "日文", "日本語"}:
        lang = "ja"
    elif lang in {"eng", "english", "英文"}:
        lang = "en"
    if lang not in MAPPING_LANGS:
        lang = "zh-CN"

    def _b(key: str, *alts: str, default: bool = True) -> bool:
        for k in (key, *alts):
            if k in src and src[k] is not None:
                return bool(src[k])
        return default

    return {
        "useForumZhTitle": _b(
            "useForumZhTitle", "use_forum_zh_title", "useSehuatangTitle", default=True
        ),
        "enableActorMapping": _b(
            "enableActorMapping", "enable_actor_mapping", default=True
        ),
        "enableTagMapping": _b(
            "enableTagMapping", "enable_tag_mapping", default=True
        ),
        "compactOutlineNewlines": _b(
            "compactOutlineNewlines",
            "compact_outline_newlines",
            "trimOutlineNewlines",
            default=True,
        ),
        "mappingLanguage": lang,
    }


def _lang_file_stem(lang: str) -> str:
    return {
        "zh-CN": "zh-CN",
        "zh-TW": "zh-TW",
        "ja": "ja",
        "en": "en",
    }.get(lang, "zh-CN")


@lru_cache(maxsize=16)
def _load_json_map(path_str: str) -> dict[str, Any]:
    path = Path(path_str)
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


# 索引缓存：`id(table)` → (table, index)。
# ⚠️ 必须把 table 自身也存进来当强引用：否则表对象一旦被 GC，
# 其 `id` 可能被**另一个表**复用，查到的就是过期索引 → 静默错误映射。
# 同时用 `hit[0] is table` 做身份校验作双保险。
_CASEFOLD_INDEX: dict[int, tuple[dict[str, Any], dict[str, Any]]] = {}


_SETTING_MAP_ENABLED: bool | None = None


def _actor_mapping_enabled() -> bool:
    global _SETTING_MAP_ENABLED
    if _SETTING_MAP_ENABLED is not None:
        return _SETTING_MAP_ENABLED
    use_map = True
    try:
        import app.core.settings_store as settings_store

        raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
        if isinstance(raw, dict):
            opt = normalize_metadata_optimize(
                raw.get("metadataOptimize") or raw.get("metadata_optimize")
            )
            use_map = bool(opt["enableActorMapping"])
    except Exception:
        use_map = True
    _SETTING_MAP_ENABLED = use_map
    return use_map


def _actor_maps(lang: str) -> dict[str, Any]:
    stem = _lang_file_stem(lang)
    from app.core.maps_paths import scrape_maps_seed_dir

    root = scrape_maps_seed_dir()
    for name in (f"actors.{stem}.json", "actors.json"):
        m = _load_json_map(str(root / name))
        if m:
            return m
    return {}


def _casefold_index(table: dict[str, Any]) -> dict[str, Any]:
    tid = id(table)
    hit = _CASEFOLD_INDEX.get(tid)
    if hit is not None and hit[0] is table:
        return hit[1]
    idx: dict[str, Any] = {}
    for k, v in table.items():
        raw = str(k).strip()
        if not raw:
            continue
        idx[raw.casefold()] = v
        folded = _kana_fold(raw)
        if folded and folded.casefold() not in idx:
            idx[folded.casefold()] = v
    _CASEFOLD_INDEX[tid] = (table, idx)
    return idx


# ⚠️ 折叠链必须记忆化：这三个函数只依赖入参 + 模块常量（`_TAG_VARIANT_TRANS`
# 在 import 时由 `load_str_map` 建好，运行期不变）→ **纯函数**，且被 `_merge_got`
# 的标签/女优路径按**每标签 × 每形态**反复调用（第九轮实测单番号
# `_kana_fold` 141458 次 / `_fold_variant` 156678 次，占 `_merge_got` CPU 的 ~2/3）。
# 缓存后同样输入只算一次，语义零变化。
@lru_cache(maxsize=16384)
def _kana_fold(s: str) -> str:
    """片假名 → 平假名，便于 倉本スミレ / 倉本すみれ 命中同一映射。"""
    out: list[str] = []
    for ch in str(s or ""):
        o = ord(ch)
        if 0x30A1 <= o <= 0x30F6:  # ァ-ヶ
            out.append(chr(o - 0x60))
        else:
            out.append(ch)
    return "".join(out)


@lru_cache(maxsize=16384)
def _fold_variant(s: str) -> str:
    """繁/日 → 简 折叠（仅用于映射兜底，解繁简分裂）。

    先做 `々` 重复记号归一（`佐々波綾` → `佐佐波綾`），再做繁简折叠
    （→ `佐佐波绫`），使表键 / 标准名 / 源站名三侧都能收敛到同一字形。
    """
    s = _iter_fold(str(s or ""))
    if not _TAG_VARIANT_TRANS:
        return s
    return s.translate(_TAG_VARIANT_TRANS)


_VARIANT_INDEX: dict[int, tuple[dict[str, Any], dict[str, Any]]] = {}


def _variant_index(table: dict[str, Any]) -> dict[str, Any]:
    """折叠索引：键与标准名（value）都折叠后建索引，供模糊兜底命中。

    先索引键（原始/折叠/假名折叠），再索引标准名——故「键」优先级始终高于
    「别的条目的标准名」，不会误改既有正确结果。
    """
    tid = id(table)
    hit = _VARIANT_INDEX.get(tid)
    if hit is not None and hit[0] is table:
        return hit[1]
    idx: dict[str, Any] = {}
    for k in table:
        raw = str(k).strip()
        if not raw:
            continue
        v = table[k]
        idx.setdefault(raw.casefold(), v)
        idx.setdefault(_fold_variant(raw).casefold(), v)
        idx.setdefault(_kana_fold(_fold_variant(raw)).casefold(), v)
    # 标准名（如 `继母` 是 `義母` 的目标）也纳入，使 繁/日 写法都能收敛
    for v in table.values():
        name = v
        if isinstance(v, dict):
            name = v.get("name") or v.get("zh") or v.get("title") or ""
        if isinstance(name, str) and name.strip():
            idx.setdefault(_fold_variant(name).casefold(), v)
            idx.setdefault(_kana_fold(_fold_variant(name)).casefold(), v)
    _VARIANT_INDEX[tid] = (table, idx)
    return idx


def _paren_name_candidates(raw: str) -> list[str]:
    """从 `别名(标准名)` / `A（B）` 中取出括号内的名字，作为末位兜底候选。

    只剥**结尾**的括号组（与 `_clean_actor_raw` 的剥离位置逐一对应，可连续多层）；
    括号里是备注（`着エロ` / `HEYZO・天然むすめ`）时会查不中表，自然被忽略。
    """
    s = str(raw or "").strip()
    out: list[str] = []
    while True:
        m = re.search(r"[\(（]([^)）]+)[\)）]\s*$", s)
        if m is None:
            break
        inner = str(m.group(1) or "").strip()
        if inner and inner not in out:
            out.append(inner)
        s = s[: m.start()].strip()
    return out


def _lookup_actor_hit(raw_name: str, table: dict[str, Any]) -> Any:
    key = str(raw_name or "").strip()
    if not key:
        return None
    cleaned = _clean_actor_raw(key)
    variants: list[str] = []
    for cand in (key, cleaned, _kana_fold(key), _kana_fold(cleaned)):
        c = str(cand or "").strip()
        if c and c not in variants:
            variants.append(c)
    for cand in variants:
        hit = table.get(cand)
        if hit is not None:
            return hit
    low = _casefold_index(table)
    for cand in variants:
        hit = low.get(cand.casefold())
        if hit is not None:
            return hit
    # 繁/日 折叠兜底：表里只有 `藤宮櫻花` 时，`藤宫樱花` 也能命中（解女优名繁简分裂）
    vidx = _variant_index(table)
    for cand in variants:
        hit = vidx.get(_fold_variant(cand).casefold())
        if hit is not None:
            return hit
    # 末位兜底：`别名(标准名)` 写法。部分源（如 airav_io `小那海绫(佐佐波绫)`）把
    # **标准中文名放在括号里**、别名放前面；_clean_actor_raw 会把括号剥掉只留别名，
    # 于是永远漏映射。此处把括号内名字也当候选再查一次——**只在前面全部落空时**才走，
    # 故不会改变任何已能命中的结果（零回归），属通用规则而非逐条补表。
    for inner in _paren_name_candidates(key):
        for cand in (inner, _kana_fold(inner)):
            c = str(cand or "").strip()
            if not c:
                continue
            hit = table.get(c) or low.get(c.casefold()) or vidx.get(_fold_variant(c).casefold())
            if hit is not None:
                return hit
    return None


def _actor_should_drop(hit: Any) -> bool:
    """映射表标记男优 / 导演 / 原作等非女优 → 丢弃。"""
    if hit is None or isinstance(hit, str):
        return False
    if not isinstance(hit, dict):
        return False
    if hit.get("drop") is True or hit.get("exclude") is True:
        return True
    role = str(hit.get("role") or hit.get("type") or "").strip().casefold()
    if role in {
        "director",
        "导演",
        "監督",
        "male",
        "男优",
        "男優",
        "author",
        "writer",
        "原作",
        "漫画家",
        "artist",
        "作画",
        "staff",
    }:
        return True
    sex = str(hit.get("sex") or hit.get("gender") or "").strip().casefold()
    if sex in {"m", "male", "man", "男"}:
        return True
    return False


def _map_actor_entry(raw_name: str, table: dict[str, Any]) -> tuple[str, str]:
    """返回 (显示名, javdb链接)。drop 条目返回空名。"""
    key = str(raw_name or "").strip()
    if not key:
        return "", ""
    cleaned = _clean_actor_raw(key)
    display_fallback = cleaned or key
    hit = _lookup_actor_hit(key, table)
    if _actor_should_drop(hit):
        return "", ""
    if hit is None:
        return display_fallback, ""
    if isinstance(hit, str):
        return (hit.strip() or display_fallback), ""
    if isinstance(hit, dict):
        name = str(
            hit.get("name") or hit.get("zh") or hit.get("title") or ""
        ).strip()
        link = str(
            hit.get("javdb")
            or hit.get("javdbUrl")
            or hit.get("url")
            or hit.get("link")
            or ""
        ).strip()
        return (name or display_fallback), link
    return display_fallback, ""


def _actor_identity_key(name: str) -> str:
    """同人身份键：NFKC + 繁简/假名折叠；不强制中文，只收敛别名写法。"""
    import unicodedata

    s = unicodedata.normalize("NFKC", str(name or "").strip())
    if not s:
        return ""
    return _kana_fold(_fold_variant(s)).casefold()


def polish_actress_names(
    names: list[str] | None,
    *,
    exclude: list[str] | None = None,
    lang: str | None = None,
    enable_mapping: bool | None = None,
) -> list[str]:
    """女优名单优化：身份/别名收敛 + 排除导演/男优/映射 drop。

    有映射表则落到 canon（可中可日）；无表则折叠字形去重。不强制输出中文。
    """
    raw_list = [str(a).strip() for a in (names or []) if str(a or "").strip()]
    if not raw_list:
        return []

    ban = {
        str(x).strip().casefold()
        for x in (exclude or [])
        if str(x or "").strip()
    }
    ban_id = {_actor_identity_key(x) for x in ban if _actor_identity_key(x)}

    use_map = True if enable_mapping is None else bool(enable_mapping)
    if enable_mapping is None:
        use_map = _actor_mapping_enabled()

    table = _actor_maps(lang or mapping_language_from_settings()) if use_map else {}
    out: list[str] = []
    seen: set[str] = set()
    for raw in raw_list:
        cleaned = _clean_actor_raw(raw) or raw
        if cleaned.casefold() in ban or _actor_identity_key(cleaned) in ban_id:
            continue
        hit = None
        if use_map and table:
            # 传 **raw**（而非已剥括号的 cleaned）：`别名(标准名)` 只在 raw 上才看得到
            # 括号，_lookup_actor_hit 的末位兜底才有机会命中标准名。
            hit = _lookup_actor_hit(raw, table)
            if _actor_should_drop(hit):
                continue
            name, _ = _map_actor_entry(raw, table)
            if hit is None:
                # 未入表 → 输出按 繁/日 → 简 折叠字形。
                # 中文源与日文源对同一人常只差一个字形（BMW-311 `乃木蛍`+`乃木萤`、
                # KMHR-050 `水樹璃子`+`水树璃子`），不折叠就会在同号里出两条 → 人数虚高。
                # 注意：未命中时先折；命中后再统一对纯汉字 fold（见下）
                name = _fold_variant(name) or name
                key = _actor_identity_key(name)
            else:
                # 已映射：以 canon 展示键去重（同人别名已落到同一 name）
                key = str(name or "").strip().casefold() or _actor_identity_key(name)
        else:
            name = cleaned
            key = _actor_identity_key(name)
        name = str(name or "").strip()
        # 表内 canon 偶有繁体（青葉春）；展示统一折简，避免标题简/女优繁打架
        if name and not re.search(r"[\u3040-\u30ff]", name):
            folded = _fold_variant(name) or name
            if folded != name:
                name = folded
                if use_map and table and hit is not None:
                    key = name.casefold() or _actor_identity_key(name)
                else:
                    key = _actor_identity_key(name)
        if not name or name.casefold() in ban or _actor_identity_key(name) in ban_id:
            continue
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(name)
    return out




