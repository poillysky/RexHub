"""Committed map seeds live in ``apps/maps/<category>/``.

Layout::

    apps/maps/
      makers/     makers.json, av-makers.*.json
      prefixes/   prefixes.json, catalog.seed.json, code-*.json
      scrape/     actors / tags / code-titles / variant-fold（唯一完整表）
      regions/    regions.json
      sites/      DMM / R18 / ThePornDB / 色花堂

Runtime overlays (writable) for prefix catalog etc. stay under repo-root ``data/``.
Actors / tags / code-titles are NOT dual-homed under data/scrape_maps.
"""


import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.core.db import ROOT
MAPS_SEED_DIR = ROOT / "apps" / "maps"

# logical name (callers / load_json_map) → path under apps/maps/
_SEED_REL: dict[str, str] = {
    "makers.json": "makers/makers.json",
    "av-makers.japan.json": "makers/av-makers.japan.json",
    "av-makers.china.json": "makers/av-makers.china.json",
    "av-makers.western.json": "makers/av-makers.western.json",
    "prefixes.json": "prefixes/prefixes.json",
    "prefix-catalog.seed.json": "prefixes/catalog.seed.json",
    "prefix-code-ranges.json": "prefixes/code-ranges.json",
    "prefix-code-shapes.json": "prefixes/code-shapes.json",
    "prefix-code-read.json": "prefixes/code-read.json",
    "regions.json": "regions/regions.json",
    "dmm-series-digit.json": "sites/dmm-series-digit.json",
    "r18-content-id-prefixes.json": "sites/r18-content-id-prefixes.json",
    "western-studio-search-aliases.json": "sites/western-studio-search-aliases.json",
    "sehuatang-forum.json": "sites/sehuatang-forum.json",
    "sehuatang-forum-prefix-map.json": "sites/sehuatang-forum-prefix-map.json",
    "sehuatang-forum-skip-names.json": "sites/sehuatang-forum-skip-names.json",
    "tags.variant-fold.zh-CN.json": "scrape/tags.variant-fold.zh-CN.json",
    "code-titles.json": "scrape/code-titles.json",
}


def maps_seed(name: str) -> Path:
    """Resolve a map seed path.

    Accepts logical names (``makers.json``), relative paths
    (``makers/makers.json``), or scrape filenames (``actors.zh-CN.json``).
    """
    key = str(name or "").replace("\\", "/").lstrip("/")
    if key in _SEED_REL:
        return MAPS_SEED_DIR / _SEED_REL[key]
    if "/" in key:
        return MAPS_SEED_DIR / key
    if key.startswith("actors.") or key.startswith("tags."):
        return MAPS_SEED_DIR / "scrape" / key
    # fallback: flat under maps root (compat)
    return MAPS_SEED_DIR / key


def scrape_maps_seed_dir() -> Path:
    return MAPS_SEED_DIR / "scrape"


def prefix_code_ranges_seed() -> Path:
    return maps_seed("prefix-code-ranges.json")


def av_makers(region: str) -> Path:
    """region: japan | china | western"""
    return maps_seed(f"av-makers.{region}.json")


def av_makers_all() -> tuple[Path, Path, Path]:
    return av_makers("japan"), av_makers("china"), av_makers("western")


def code_titles_seed() -> Path:
    return maps_seed("scrape/code-titles.json")


def code_titles_runtime() -> Path:
    """Compat alias — code-titles live in apps/maps/scrape/."""
    return code_titles_seed()


_CODE_TITLE_REGION_RE = re.compile(
    r"^(?:有码|无码|素人|写真|FC2|国产|欧美)\s*[|｜·\-—]\s*"
)


def strip_code_title_region(title: str) -> str:
    """剥掉 code-titles 上的区域代号前缀（写入 NFO 时用净标题）。"""
    t = str(title or "").strip()
    if not t:
        return ""
    return _CODE_TITLE_REGION_RE.sub("", t).strip() or t


@lru_cache(maxsize=1)
def load_code_titles() -> dict[str, str]:
    path = code_titles_runtime()
    if not path.is_file():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        return {}
    return {str(k).strip().upper(): str(v).strip() for k, v in raw.items() if str(k).strip() and str(v).strip()}


def lookup_code_title(code: str, *, keep_region: bool = False) -> str:
    key = str(code or "").strip().upper()
    if not key:
        return ""
    table = load_code_titles()
    title = ""
    if key in table:
        title = table[key]
    else:
        # 兼容无横杠 / 下划线
        compact = key.replace("_", "-")
        if compact in table:
            title = table[compact]
    if not title:
        return ""
    return title if keep_region else strip_code_title_region(title)


@lru_cache(maxsize=64)
def load_json_map(name: str) -> Any:
    """Load a JSON document from ``apps/maps`` (cached)."""
    path = maps_seed(name)
    if not path.is_file():
        raise FileNotFoundError(f"missing map seed: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def load_str_map(name: str) -> dict[str, str]:
    raw = load_json_map(name)
    if not isinstance(raw, dict):
        raise TypeError(f"{name}: expected object, got {type(raw).__name__}")
    return {str(k): "" if v is None else str(v) for k, v in raw.items()}


@lru_cache(maxsize=1)
def makers_doc() -> dict[str, Any]:
    return dict(load_json_map("makers.json") or {})


@lru_cache(maxsize=1)
def regions_doc() -> dict[str, Any]:
    return dict(load_json_map("regions.json") or {})


def studio_alias_map() -> dict[str, str]:
    raw = makers_doc().get("aliases") or {}
    return {str(k): str(v) for k, v in dict(raw).items()}
