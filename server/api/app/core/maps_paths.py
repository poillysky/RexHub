"""Committed map seeds live in ``server/maps/<category>/``.

Layout::

    server/maps/
      makers/     av-makers.*.json
      prefixes/   code-*.json
      scrape/     actors / tags variant-fold（唯一完整表）
      regions/    regions.json
      sites/      sehuatang-forum.json

Runtime overlays (writable) for prefix catalog etc. stay under ``server/data/``.
"""


import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.core.db import ROOT
MAPS_SEED_DIR = ROOT / "maps"

# logical name (callers / load_json_map) → path under server/maps/
_SEED_REL: dict[str, str] = {
    "av-makers.japan.json": "makers/av-makers.japan.json",
    "av-makers.china.json": "makers/av-makers.china.json",
    "av-makers.western.json": "makers/av-makers.western.json",
    "prefix-code-ranges.json": "prefixes/code-ranges.json",
    "prefix-code-shapes.json": "prefixes/code-shapes.json",
    "prefix-code-read.json": "prefixes/code-read.json",
    "regions.json": "regions/regions.json",
    "sehuatang-forum.json": "sites/sehuatang-forum.json",
    "tags.variant-fold.zh-CN.json": "scrape/tags.variant-fold.zh-CN.json",
}


def maps_seed(name: str) -> Path:
    """Resolve a map seed path.

    Accepts logical names (``regions.json``), relative paths
    (``regions/regions.json``), or scrape filenames (``actors.zh-CN.json``).
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


@lru_cache(maxsize=64)
def load_json_map(name: str) -> Any:
    """Load a JSON document from ``server/maps`` (cached)."""
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
def regions_doc() -> dict[str, Any]:
    return dict(load_json_map("regions.json") or {})
