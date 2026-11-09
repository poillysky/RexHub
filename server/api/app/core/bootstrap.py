"""Startup: seed default settings from config → Postgres meta."""


import logging
from typing import Any

import app.core.settings_store as settings_store
from app.core.config_loader import config_paths, load_config

log = logging.getLogger("rexhub.bootstrap")

SETTINGS_SEED_META_KEY = "bootstrap_settings"


def seed_settings_from_config(*, force: bool | None = None) -> dict[str, Any]:
    """把 config.app.json / app.local.json 的 settings 写入元库（SQLite）。

    默认：仅当 key 不存在时填入（不覆盖用户已改配置）。
    force=True 或 config.seed_settings_on_boot=true：强制覆盖写入。
    """
    cfg = load_config()
    raw = cfg.get("settings")
    if not isinstance(raw, dict) or not raw:
        return {"seeded": [], "skipped": [], "forced": False}

    if force is None:
        force = bool(cfg.get("seed_settings_on_boot"))

    seeded: list[str] = []
    skipped: list[str] = []
    for key, value in raw.items():
        k = str(key or "").strip()
        if not k or value is None:
            continue
        existing = settings_store.get_setting(k)
        if existing is not None and not force:
            skipped.append(k)
            continue
        settings_store.put_setting(k, value)
        seeded.append(k)
        log.info("settings seeded from config → sqlite: %s", k)

    meta = {
        "seeded": seeded,
        "skipped": skipped,
        "forced": force,
        "source": [str(p) for p in config_paths()],
    }
    settings_store.put_setting(SETTINGS_SEED_META_KEY, meta)
    if seeded:
        log.info(
            "settings seed done: wrote %s, skipped %s (force=%s)",
            ",".join(seeded) or "-",
            len(skipped),
            force,
        )
    else:
        log.info(
            "settings seed: nothing to write (skipped %s existing keys, force=%s)",
            len(skipped),
            force,
        )
    return meta
