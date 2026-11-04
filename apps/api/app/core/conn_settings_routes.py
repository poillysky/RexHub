"""115 / TMDB / forum / library display settings (Postgres meta)."""

from __future__ import annotations

import json
import logging
import os
import re
import time
from pathlib import Path
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.auth.routes import get_optional_user, require_user
import app.p115.client as p115_client
import app.p115.extract as p115_extract
import app.p115.relocate as p115_relocate
import app.core.settings_store as settings_store
import app.p115.offline as p115_offline_svc
import app.p115.qrlogin as p115_qrlogin_svc
import app.p115.share as p115_share_svc
import app.p115.upload as p115_upload
from app.core.db import ROOT
from app.core.outbound_http import normalize_proxy_url

log = logging.getLogger(__name__)

_ARCHIVE_EXT_RE = re.compile(r"\.(zip|rar|7z)(?:\.[a-z0-9]+)?$", re.I)

router = APIRouter(prefix="/settings", tags=["settings"])

DEFAULT_LIBRARY_REL = "data/library"
_LIBRARY_SKIP_DIRS = frozenset()




def _normalize_library_rel(raw: str | None) -> str:
    """容器内相对路径（POSIX）；绝对路径若落在项目 data/ 下则收成相对。"""
    s = str(raw or "").strip().replace("\\", "/")
    if not s:
        return DEFAULT_LIBRARY_REL
    try:
        p = Path(s)
        if p.is_absolute():
            root = ROOT.resolve()
            try:
                rel = p.resolve().relative_to(root)
                s = rel.as_posix()
            except ValueError:
                # 不在项目内：忽略，回默认
                return DEFAULT_LIBRARY_REL
        s = s.lstrip("/")
        if s.startswith("./"):
            s = s[2:]
        if not s.startswith("data/"):
            # 仅允许 data/ 下
            if s == "data":
                return DEFAULT_LIBRARY_REL
            return DEFAULT_LIBRARY_REL
        # 禁止逃逸
        if ".." in Path(s).parts:
            return DEFAULT_LIBRARY_REL
        return s
    except Exception:
        return DEFAULT_LIBRARY_REL


def _library_abs(rel: str) -> str:
    return str((ROOT / rel).resolve())


def _safe_data_rel(raw: str | None, *, default: str = "data") -> str:
    """浏览用：限制在项目 data/ 下的相对路径。"""
    s = str(raw or "").strip().replace("\\", "/").strip("/")
    if not s:
        return default
    try:
        p = Path(s)
        if p.is_absolute():
            try:
                s = p.resolve().relative_to(ROOT.resolve()).as_posix()
            except ValueError:
                return default
        if s.startswith("./"):
            s = s[2:]
        if s != "data" and not s.startswith("data/"):
            return default
        if ".." in Path(s).parts:
            return default
        return s
    except Exception:
        return default



def _normalize_proxy_url(raw: str | None) -> str:
    """裸 host:port → http://；非法则空串。（唯一实现见 app.core.outbound_http）"""
    return normalize_proxy_url(raw)


class Envelope(BaseModel):
    data: Any = None
    message: str = "ok"
    status: int = 200


_COVER_DOWNLOAD_STRATEGIES = frozenset({"priority", "size"})

_FORUM_REGIONS = frozenset({"japan", "china", "western", "mixed", "other"})


class ForumSehuatangConfig(BaseModel):
    """色花堂子板地区覆盖：key = fid:typeid（整板 typeid 为空）。
    地区：japan|china|western|mixed|other"""

    region_by_key: dict[str, str] = Field(default_factory=dict, alias="regionByKey")

    model_config = {"populate_by_name": True}


def _forum_sehuatang_public(raw: Any) -> dict[str, Any]:
    region_by_key: dict[str, str] = {}
    if isinstance(raw, dict):
        src = raw.get("regionByKey") or raw.get("region_by_key") or {}
        if isinstance(src, dict):
            for k, v in src.items():
                key = str(k or "").strip()
                region = str(v or "").strip().lower()
                if key and region in _FORUM_REGIONS:
                    region_by_key[key] = region
    return {"regionByKey": region_by_key}


class P115TargetFolder(BaseModel):
    folder_cid: str = Field(default="0", alias="folderCid")
    folder_name: str = Field(default="", alias="folderName")

    model_config = {"populate_by_name": True}


class P115Config(BaseModel):
    enabled: bool = False
    cookie: str = ""
    folder_cid: str = Field(default="0", alias="folderCid")
    folder_name: str = Field(default="", alias="folderName")
    label: str = ""
    targets: dict[str, P115TargetFolder] | None = None
    do_validate: bool = Field(default=True, alias="validate")

    model_config = {"populate_by_name": True}


class P115FoldersBody(BaseModel):
    cid: str = "0"
    cookie: str | None = None


class P115ValidateBody(BaseModel):
    cookie: str | None = None
    folder_cid: str = Field(default="0", alias="folderCid")

    model_config = {"populate_by_name": True}


class P115OfflineBody(BaseModel):
    urls: list[str] = Field(min_length=1, max_length=50)
    folder_cid: str | None = Field(default=None, alias="folderCid")
    source: str | None = None
    password: str | None = None
    title_hint: str | None = Field(default=None, alias="titleHint")
    auto_extract: bool | None = Field(default=None, alias="autoExtract")

    model_config = {"populate_by_name": True}


class P115ShareBody(BaseModel):
    urls: list[str] = Field(min_length=1, max_length=20)
    folder_cid: str | None = Field(default=None, alias="folderCid")
    source: str | None = None
    password: str | None = None

    model_config = {"populate_by_name": True}


class P115TasksClearBody(BaseModel):
    """mode: done | failed | all — maps to 115 task_clear flag 0/2/1."""

    mode: str = "done"


class P115TaskDeleteBody(BaseModel):
    info_hash: str = Field(min_length=1, alias="infoHash")

    model_config = {"populate_by_name": True}


class P115QrStartBody(BaseModel):
    app: str = "alipaymini"


class P115QrStatusBody(BaseModel):
    uid: str
    time: str | int
    sign: str


class P115QrCompleteBody(BaseModel):
    uid: str
    app: str = "alipaymini"
    """若 true，登录成功后直接写入已存目录配置。"""
    save: bool = True


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


def _targets_for_store(
    body_targets: dict[str, P115TargetFolder] | None,
    prev: dict[str, Any] | None,
    *,
    fallback_cid: str,
    fallback_name: str,
) -> dict[str, dict[str, str]]:
    merged = _p115_targets(prev)
    # Ensure warehouse reflects legacy fields when body omits targets
    if not body_targets:
        merged["warehouse"] = {
            "folderCid": fallback_cid,
            "folderName": fallback_name,
        }
        return {
            k: {"folder_cid": v["folderCid"], "folder_name": v["folderName"]}
            for k, v in merged.items()
        }
    for key in P115_SOURCES:
        item = body_targets.get(key)
        if item is None:
            continue
        merged[key] = {
            "folderCid": (item.folder_cid or "0").strip() or "0",
            "folderName": (item.folder_name or "").strip(),
        }
    return {
        k: {"folder_cid": v["folderCid"], "folder_name": v["folderName"]}
        for k, v in merged.items()
    }


def _is_offline_url(link: str) -> bool:
    lower = (link or "").strip().lower()
    if not lower or lower.startswith("unavailable://"):
        return False
    if lower.startswith("ed2k://") or lower.startswith("magnet:"):
        return True
    if "115cdn.com/s/" in lower or "115.com/s/" in lower:
        return False
    return bool(re.match(r"^(https?://|ftp://)", lower))


def _looks_archive_link(link: str) -> bool:
    lower = (link or "").strip().lower()
    # ed2k://|file|name.zip|size|hash|/ — 取文件名段再测扩展名
    if lower.startswith("ed2k://"):
        parts = (link or "").split("|")
        if len(parts) >= 3:
            return bool(_ARCHIVE_EXT_RE.search(parts[2].strip()))
    return bool(_ARCHIVE_EXT_RE.search(lower))


def _cookie_hint(cookie: str) -> str:
    for part in (cookie or "").split(";"):
        p = part.strip()
        if p.upper().startswith("UID="):
            return p.split("=", 1)[-1][:16]
    return ""






def _p115_public(raw: dict[str, Any] | None, *, include_cookie: bool = False) -> dict[str, Any]:
    # raw uses snake_case from meta store
    cookie = str((raw or {}).get("cookie") or "").strip()
    configured = bool(cookie and "UID=" in cookie.upper())
    targets = _p115_targets(raw)
    warehouse = targets["warehouse"]
    data = {
        "enabled": bool((raw or {}).get("enabled")),
        "folderCid": warehouse["folderCid"],
        "folderName": warehouse["folderName"],
        "label": str((raw or {}).get("label") or ""),
        "targets": targets,
        "hasCookie": bool(cookie),
        "cookieHint": _cookie_hint(cookie) if configured else "",
        "configured": configured,
    }
    if include_cookie:
        data["cookie"] = cookie
    return data


def _tmdb_public(raw: dict[str, Any] | None, *, include_key: bool = False) -> dict[str, Any]:
    import os

    env_key = os.environ.get("TMDB_API_KEY", "").strip()
    stored = str((raw or {}).get("apiKey") or (raw or {}).get("api_key") or "").strip()
    effective = env_key or stored
    hint = ""
    if effective:
        hint = f"{effective[:4]}…{effective[-4:]}" if len(effective) > 10 else "****"
    data: dict[str, Any] = {
        "configured": bool(effective),
        "fromEnv": bool(env_key),
        "apiKeyHint": hint,
    }
    if include_key and stored and not env_key:
        data["apiKey"] = stored
    return data


@router.get("/forum/sehuatang", response_model=Envelope)
def get_forum_sehuatang(
    _user: dict[str, Any] | None = Depends(get_optional_user),
) -> Envelope:
    data = _forum_sehuatang_public(
        settings_store.get_setting(settings_store.FORUM_SEHUATANG_KEY)
    )
    return Envelope(data=data, message="ok")


@router.put("/forum/sehuatang", response_model=Envelope)
def put_forum_sehuatang(
    body: ForumSehuatangConfig,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    cleaned: dict[str, str] = {}
    for k, v in (body.region_by_key or {}).items():
        key = str(k or "").strip()
        region = str(v or "").strip().lower()
        if key and region in _FORUM_REGIONS:
            cleaned[key] = region
    saved = settings_store.put_setting(
        settings_store.FORUM_SEHUATANG_KEY,
        {"regionByKey": cleaned},
    )
    try:
        from app.search.forum_region_tags import invalidate_forum_region_cache

        invalidate_forum_region_cache()
    except Exception:
        pass
    data = _forum_sehuatang_public(saved["value"])
    data["updated_at"] = saved["updated_at"]
    return Envelope(data=data, message="saved")


class TmdbConfig(BaseModel):
    api_key: str = Field(default="", alias="apiKey")

    model_config = {"populate_by_name": True}


@router.get("/tmdb", response_model=Envelope)
def get_tmdb(_user: dict[str, Any] | None = Depends(get_optional_user)) -> Envelope:
    data = _tmdb_public(settings_store.get_setting(settings_store.TMDB_KEY))
    return Envelope(
        data=data,
        message="configured" if data["configured"] else "not_configured",
    )


@router.put("/tmdb", response_model=Envelope)
def put_tmdb(
    body: TmdbConfig,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    prev = settings_store.get_setting(settings_store.TMDB_KEY) or {}
    prev_key = str(prev.get("apiKey") or prev.get("api_key") or "").strip()
    next_key = body.api_key.strip()
    # 已有 key 时，空提交不允许覆盖清空；只有明确输入新 key 才替换
    key = next_key or prev_key
    saved = settings_store.put_setting(
        settings_store.TMDB_KEY,
        {"apiKey": key},
    )
    data = _tmdb_public(saved["value"])
    data["updated_at"] = saved["updated_at"]
    return Envelope(data=data, message="saved")


@router.post("/tmdb/test", response_model=Envelope)
async def test_tmdb(
    body: TmdbConfig,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    import os

    key = body.api_key.strip() or os.environ.get("TMDB_API_KEY", "").strip()
    if not key:
        stored = settings_store.get_setting(settings_store.TMDB_KEY) or {}
        key = str(stored.get("apiKey") or stored.get("api_key") or "").strip()
    if not key:
        raise HTTPException(status_code=400, detail="请先填写 TMDB API Key")
    from app.core.outbound_http import resolve_scrape_proxy_url

    client_kw: dict[str, Any] = {
        "timeout": httpx.Timeout(12.0, connect=4.0),
        "trust_env": False,
        "follow_redirects": True,
    }
    proxy = resolve_scrape_proxy_url()
    if proxy:
        client_kw["proxy"] = proxy
    try:
        async with httpx.AsyncClient(**client_kw) as client:
            r = await client.get(
                "https://api.themoviedb.org/3/search/multi",
                params={
                    "api_key": key,
                    "query": "超人",
                    "language": "zh-CN",
                    "include_adult": "false",
                },
            )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"无法连接 TMDB: {e}") from e
    if r.status_code == 401:
        raise HTTPException(status_code=400, detail="API Key 无效")
    if not r.is_success:
        raise HTTPException(status_code=502, detail=f"TMDB 返回 {r.status_code}")
    total = int((r.json() or {}).get("total_results") or 0)
    return Envelope(
        data={"ok": True, "totalResults": total},
        message=f"测试成功，命中约 {total} 条",
    )


@router.get("/p115", response_model=Envelope)
def get_p115(_user: dict[str, Any] | None = Depends(get_optional_user)) -> Envelope:
    raw = settings_store.get_setting(settings_store.P115_KEY)
    data = _p115_public(raw)
    return Envelope(
        data=data,
        message="configured" if data["configured"] else "not_configured",
    )


@router.get("/p115/status", response_model=Envelope)
def get_p115_status(_user: dict[str, Any] | None = Depends(get_optional_user)) -> Envelope:
    """115 实时状态：额度 / 空间 / 单任务上限。用于设置页异步补状态，避免首屏阻塞。"""
    raw = settings_store.get_setting(settings_store.P115_KEY)
    data = _p115_public(raw)
    data["authOk"] = False
    data["authError"] = ""
    if not data.get("configured"):
        return Envelope(data=data, message="not_configured")

    cookie = str((raw or {}).get("cookie") or "").strip()
    if not cookie:
        return Envelope(data=data, message="not_configured")

    # Cookie 是否仍然有效：以目录可读为准（115 失效时会返回 state=false / errno）
    auth_res = p115_client.validate_p115(cookie, data.get("folderCid") or "0")
    if not auth_res.get("ok"):
        data["authError"] = str(auth_res.get("message") or "Cookie 无效或已过期")
        data["quota"] = None
        data["quotaTotal"] = None
        return Envelope(data=data, message="auth_failed")
    data["authOk"] = True

    quota_res = p115_client.fetch_offline_quota(cookie)
    if quota_res.get("ok"):
        data["quota"] = quota_res.get("quota")
        data["quotaTotal"] = quota_res.get("quotaTotal")
    else:
        data["quota"] = None
        data["quotaTotal"] = None
        data["quotaError"] = str(quota_res.get("message") or "额度读取失败")

    space_res = p115_client.fetch_space_info(cookie)
    if space_res.get("ok"):
        data["spaceTotal"] = space_res.get("spaceTotal")
        data["spaceTotalText"] = space_res.get("spaceTotalText")
        data["spaceUsed"] = space_res.get("spaceUsed")
        data["spaceUsedText"] = space_res.get("spaceUsedText")
        data["spaceRemain"] = space_res.get("spaceRemain")
        data["spaceRemainText"] = space_res.get("spaceRemainText")
    elif auth_res.get("spaceTotalText"):
        # 空间接口偶发失败时，退回校验阶段已取到的容量
        for key in ("spaceTotal", "spaceTotalText", "spaceUsed", "spaceUsedText",
                    "spaceRemain", "spaceRemainText"):
            if auth_res.get(key) is not None:
                data[key] = auth_res.get(key)

    sign_res = p115_client.fetch_offline_sign(cookie)
    if sign_res.get("ok") and sign_res.get("offlineLimit") is not None:
        data["offlineLimit"] = sign_res.get("offlineLimit")

    return Envelope(data=data, message="ok")


@router.get("/p115/tasks", response_model=Envelope)
def get_p115_tasks(
    page: int = 1,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    """离线云下载任务列表（转存工作台）。"""
    prev = settings_store.get_setting(settings_store.P115_KEY) or {}
    cookie = str(prev.get("cookie") or "").strip()
    if not cookie:
        raise HTTPException(status_code=400, detail="尚未配置 115，请先填写 Cookie")
    result = p115_offline_svc.list_offline_tasks(cookie, page=max(1, int(page or 1)))
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "获取任务失败"),
        )
    return Envelope(
        data={
            "tasks": result.get("tasks") or [],
            "page": result.get("page"),
            "pageCount": result.get("pageCount"),
            "count": result.get("count"),
            "quota": result.get("quota"),
            "quotaTotal": result.get("quotaTotal"),
        },
        message=str(result.get("message") or "ok"),
    )


@router.post("/p115/tasks/clear", response_model=Envelope)
def post_p115_tasks_clear(
    body: P115TasksClearBody,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    """清理离线任务：done / failed / all（不删盘内源文件）。"""
    prev = settings_store.get_setting(settings_store.P115_KEY) or {}
    cookie = str(prev.get("cookie") or "").strip()
    if not cookie:
        raise HTTPException(status_code=400, detail="尚未配置 115，请先填写 Cookie")
    mode = (body.mode or "done").strip().lower()
    result = p115_offline_svc.clear_offline_tasks(cookie, mode)
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "清理失败"),
        )
    # 清理后顺带回传最新列表与额度，减少前端往返
    listed = p115_offline_svc.list_offline_tasks(cookie, page=1)
    data: dict[str, Any] = {
        "ok": True,
        "mode": result.get("mode") or mode,
        "message": result.get("message"),
    }
    if listed.get("ok"):
        data.update(
            {
                "tasks": listed.get("tasks") or [],
                "count": listed.get("count"),
                "quota": listed.get("quota"),
                "quotaTotal": listed.get("quotaTotal"),
            }
        )
    return Envelope(data=data, message=str(result.get("message") or "已清理"))


@router.post("/p115/tasks/delete", response_model=Envelope)
def post_p115_task_delete(
    body: P115TaskDeleteBody,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    """删除单条离线任务（只清队列，不删网盘文件）。"""
    prev = settings_store.get_setting(settings_store.P115_KEY) or {}
    cookie = str(prev.get("cookie") or "").strip()
    if not cookie:
        raise HTTPException(status_code=400, detail="尚未配置 115，请先填写 Cookie")
    result = p115_offline_svc.delete_offline_task(cookie, body.info_hash)
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "删除失败"),
        )
    listed = p115_offline_svc.list_offline_tasks(cookie, page=1)
    data: dict[str, Any] = {
        "ok": True,
        "infoHash": result.get("infoHash") or body.info_hash,
        "message": result.get("message") or "已删除任务",
    }
    if listed.get("ok"):
        data.update(
            {
                "tasks": listed.get("tasks") or [],
                "count": listed.get("count"),
                "quota": listed.get("quota"),
                "quotaTotal": listed.get("quotaTotal"),
            }
        )
    return Envelope(data=data, message=str(data.get("message") or "已删除任务"))


@router.post("/p115/qrcode/start", response_model=Envelope)
def post_p115_qrcode_start(
    body: P115QrStartBody | None = None,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    app = (body.app if body else None) or "alipaymini"
    result = p115_qrlogin_svc.start_qrlogin(app)
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "获取二维码失败"),
        )
    return Envelope(
        data={
            "uid": result.get("uid"),
            "time": result.get("time"),
            "sign": result.get("sign"),
            "qrImage": result.get("qrImage"),
            "qrcode": result.get("qrcode"),
            "app": result.get("app"),
            "apps": result.get("apps") or p115_qrlogin_svc.qr_apps(),
        },
        message=str(result.get("message") or "ok"),
    )


@router.post("/p115/qrcode/status", response_model=Envelope)
def post_p115_qrcode_status(
    body: P115QrStatusBody,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    result = p115_qrlogin_svc.poll_qrlogin_status(body.uid, body.time, body.sign)
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "查询扫码状态失败"),
        )
    return Envelope(
        data={
            "status": result.get("status"),
            "statusLabel": result.get("statusLabel"),
            "done": bool(result.get("done")),
            "expired": bool(result.get("expired")),
        },
        message=str(result.get("message") or "ok"),
    )


@router.post("/p115/qrcode/complete", response_model=Envelope)
def post_p115_qrcode_complete(
    body: P115QrCompleteBody,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    result = p115_qrlogin_svc.complete_qrlogin(body.uid, body.app)
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "扫码登录失败"),
        )
    cookie = str(result.get("cookie") or "").strip()
    data: dict[str, Any] = {
        "cookie": cookie,
        "app": result.get("app"),
        "saved": False,
    }
    if body.save and cookie:
        prev = settings_store.get_setting(settings_store.P115_KEY) or {}
        targets = _targets_for_store(
            None,
            prev,
            fallback_cid=str(prev.get("folder_cid") or "0"),
            fallback_name=str(prev.get("folder_name") or ""),
        )
        warehouse = targets.get("warehouse") or {
            "folder_cid": "0",
            "folder_name": "",
        }
        value = {
            "enabled": True,
            "cookie": cookie,
            "folder_cid": str(warehouse.get("folder_cid") or "0"),
            "folder_name": str(warehouse.get("folder_name") or ""),
            "label": str(prev.get("label") or ""),
            "targets": targets,
        }
        saved = settings_store.put_setting(settings_store.P115_KEY, value)
        public = _p115_public(saved["value"])
        public["updated_at"] = saved["updated_at"]
        public["saved"] = True
        return Envelope(data=public, message="扫码登录成功，已保存 Cookie")

    return Envelope(data=data, message=str(result.get("message") or "扫码登录成功"))


@router.put("/p115", response_model=Envelope)
def put_p115(
    body: P115Config,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    prev = settings_store.get_setting(settings_store.P115_KEY) or {}
    cookie = (body.cookie or "").strip()
    if not cookie:
        cookie = str(prev.get("cookie") or "").strip()

    stored_targets = _targets_for_store(
        body.targets,
        prev,
        fallback_cid=(body.folder_cid or "0").strip() or "0",
        fallback_name=(body.folder_name or "").strip(),
    )
    warehouse = stored_targets.get("warehouse") or {
        "folder_cid": "0",
        "folder_name": "",
    }
    folder_cid = str(warehouse.get("folder_cid") or "0").strip() or "0"
    folder_name = str(warehouse.get("folder_name") or "").strip()
    label = (body.label or "").strip()

    if not cookie:
        raise HTTPException(status_code=400, detail="请先填写 Cookie")

    quota = None
    quota_total = None
    message = "已保存"
    extra: dict[str, Any] = {}
    if body.do_validate:
        check = p115_client.validate_p115(cookie, folder_cid)
        if not check.get("ok"):
            raise HTTPException(
                status_code=400,
                detail=str(check.get("message") or "验证失败"),
            )
        if not folder_name:
            folder_name = str(check.get("folderName") or "")
            stored_targets["warehouse"] = {
                "folder_cid": folder_cid,
                "folder_name": folder_name,
            }
        quota = check.get("quota")
        quota_total = check.get("quotaTotal")
        message = str(check.get("message") or "已保存")
        for key in (
            "spaceTotal",
            "spaceTotalText",
            "spaceUsed",
            "spaceUsedText",
            "spaceRemain",
            "spaceRemainText",
            "offlineLimit",
        ):
            if key in check:
                extra[key] = check.get(key)

    value = {
        "enabled": True if cookie else bool(body.enabled),
        "cookie": cookie,
        "folder_cid": folder_cid,
        "folder_name": folder_name,
        "label": label,
        "targets": stored_targets,
    }
    saved = settings_store.put_setting(settings_store.P115_KEY, value)
    data = _p115_public(saved["value"])
    data["updated_at"] = saved["updated_at"]
    data["quota"] = quota
    data["quotaTotal"] = quota_total
    data.update(extra)
    return Envelope(data=data, message=message)


@router.post("/p115/folders", response_model=Envelope)
def p115_folders(
    body: P115FoldersBody,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    prev = settings_store.get_setting(settings_store.P115_KEY) or {}
    cookie = (body.cookie or "").strip() or str(prev.get("cookie") or "").strip()
    if not cookie:
        raise HTTPException(status_code=400, detail="请先配置 115 Cookie")
    result = p115_client.list_folders(cookie, body.cid or "0")
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "获取目录失败"),
        )
    return Envelope(data=result, message=str(result.get("message") or "ok"))


@router.post("/p115/validate", response_model=Envelope)
def p115_validate(
    body: P115ValidateBody,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    prev = settings_store.get_setting(settings_store.P115_KEY) or {}
    cookie = (body.cookie or "").strip() or str(prev.get("cookie") or "").strip()
    folder_cid = (body.folder_cid or str(prev.get("folder_cid") or "0")).strip() or "0"
    if not cookie:
        raise HTTPException(status_code=400, detail="请先填写 115 Cookie")
    result = p115_client.validate_p115(cookie, folder_cid)
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "测试失败"),
        )
    return Envelope(data=result, message=str(result.get("message") or "ok"))


def _p115_public_result(result: dict[str, Any]) -> dict[str, Any]:
    """Strip non-JSON-safe fields (e.g. raw bytes from 115) before responding."""
    out = dict(result or {})
    out.pop("raw", None)
    # Ensure failed rows are plain {url, message}
    failed = out.get("failed")
    if isinstance(failed, list):
        clean: list[dict[str, str]] = []
        for row in failed:
            if not isinstance(row, dict):
                continue
            clean.append(
                {
                    "url": str(row.get("url") or ""),
                    "message": str(row.get("message") or "失败"),
                }
            )
        out["failed"] = clean
    hashes = out.get("infoHashes")
    if isinstance(hashes, list):
        out["infoHashes"] = [str(h) for h in hashes if h]
    per_url = out.get("perUrl")
    if isinstance(per_url, list):
        out["perUrl"] = [
            {
                "url": str(row.get("url") or ""),
                "message": str(row.get("message") or ""),
            }
            for row in per_url
            if isinstance(row, dict)
        ]
    return out


def _p115_json_response(
    *,
    result: dict[str, Any],
    message: str,
    status: int,
    extra: dict[str, Any] | None = None,
) -> JSONResponse:
    data = _p115_public_result(result)
    if extra:
        data.update(extra)
    payload = Envelope(data=data, message=message or "", status=status)
    try:
        content = payload.model_dump()
        # Hard fallback: never 500 on serialization
        json.dumps(content, ensure_ascii=False, default=str)
    except Exception:
        content = {
            "data": {
                "ok": bool(result.get("ok")),
                "added": int(result.get("added") or 0),
                "failed": [],
                "infoHashes": [],
            },
            "message": message or ("转存成功" if result.get("ok") else "转存失败"),
            "status": status,
        }
    return JSONResponse(status_code=status, content=content)


@router.post("/p115/offline")
def post_p115_offline(
    body: P115OfflineBody,
    _user: dict[str, Any] = Depends(require_user),
) -> JSONResponse:
    """离线转存：影视/片商先入「最近接收」再归位；仓库直存目标目录（云下载）。"""
    try:
        prev = settings_store.get_setting(settings_store.P115_KEY) or {}
        cookie = str(prev.get("cookie") or "").strip()
        if not cookie:
            raise HTTPException(
                status_code=400,
                detail="尚未配置 115，请先打开「设置」填写 Cookie",
            )

        urls = [
            u.strip()
            for u in body.urls
            if (u or "").strip()
            and _is_offline_url(u)
            and not p115_share_svc.is_115_share_link(u)
        ]
        if not urls:
            raise HTTPException(status_code=400, detail="没有可转存的磁力/ED2K 链接")

        # 最终目录：影视→movie/tv；片商六区→对应配置目录（source 丢失时用 region 兜底）
        dest_cid, dest_name = _resolve_p115_folder(
            prev,
            source=body.source,
            folder_cid=body.folder_cid,
            region=body.region,
        )

        # 影视 / 片商：先入「最近接收」；仓库：直存 dest（云下载）
        want_inbox = _use_receive_inbox(body.source)
        inbox = (
            p115_client.ensure_receive_inbox(cookie) if want_inbox else {"ok": False}
        )
        use_inbox = bool(want_inbox and inbox.get("ok") and inbox.get("cid"))
        inbox_cid = str(inbox.get("cid") or "") if use_inbox else dest_cid
        save_cid = inbox_cid if use_inbox else dest_cid

        result = p115_offline_svc.add_offline_tasks(cookie, urls, save_cid)
        password = (body.password or "").strip()
        looks_archive = any(_looks_archive_link(u) for u in urls)
        # 补齐 infoHashes（ed2k 文件 hash），避免后台轮询匹配不到、不解压
        info_hashes = [
            str(h).lower()
            for h in (result.get("infoHashes") or [])
            if h
        ]
        for h in p115_offline_svc.hashes_from_offline_urls(urls):
            if h not in info_hashes:
                info_hashes.append(h)
        result["infoHashes"] = info_hashes

        added_n = int(result.get("added") or 0)
        # 任务已存在(10008)时 added 也可能为 0，但仍需解压/归位
        actionable = bool(result.get("ok")) and (added_n > 0 or bool(info_hashes))
        want_extract = (
            actionable
            and body.auto_extract is not False
            and (bool(password) or looks_archive or body.auto_extract is True)
        )

        relocate_scheduled = False
        extract_scheduled = False
        if (
            actionable
            and use_inbox
            and dest_cid not in {"", "0"}
            and inbox_cid != dest_cid
        ):
            p115_relocate.schedule_deferred_relocate(
                {
                    "cookie": cookie,
                    "inboxCid": inbox_cid,
                    "destCid": dest_cid,
                    "password": password,
                    "infoHashes": info_hashes,
                    "titleHint": body.title_hint or "",
                    "wantExtract": want_extract,
                }
            )
            relocate_scheduled = True
        elif want_extract:
            # 仓库直存：在目标目录内轮询完成后云解压（不经最近接收）
            p115_extract.schedule_deferred_extract(
                {
                    "cookie": cookie,
                    "folderCid": dest_cid,
                    "password": password,
                    "infoHashes": info_hashes,
                    "titleHint": body.title_hint or "",
                }
            )
            extract_scheduled = True


        message = str(result.get("message") or "")
        dest_label = dest_name or "指定目录"
        if use_inbox:
            message = f"{message} · 已入「最近接收」"
        else:
            message = f"{message} · 直存「{dest_label}」"
        if relocate_scheduled:
            message = (
                f"{message} · 后台等待完成后移到「{dest_label}」"
                + ("（含云解压）" if want_extract else "")
            )
        elif extract_scheduled:
            message = f"{message} · 后台完成后在「{dest_label}」内云解压"

        status = 200 if result.get("ok") else 400
        return _p115_json_response(
            result=result,
            message=message,
            status=status,
            extra={
                "inboxCid": inbox_cid if use_inbox else None,
                "destCid": dest_cid,
                "destName": dest_name,
                "relocateScheduled": relocate_scheduled,
                "extractScheduled": extract_scheduled
                or (relocate_scheduled and want_extract),
                "extractMode": (
                    "poll-relocate"
                    if relocate_scheduled
                    else ("poll" if extract_scheduled else None)
                ),
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        return _p115_json_response(
            result={"ok": False, "added": 0, "failed": [], "infoHashes": []},
            message=f"转存异常：{type(e).__name__}: {e}",
            status=400,
        )


@router.post("/p115/share")
def post_p115_share(
    body: P115ShareBody,
    _user: dict[str, Any] = Depends(require_user),
) -> JSONResponse:
    """分享转存：影视/片商先入「最近接收」再归位；仓库直存目标目录。"""
    try:
        prev = settings_store.get_setting(settings_store.P115_KEY) or {}
        cookie = str(prev.get("cookie") or "").strip()
        if not cookie:
            raise HTTPException(
                status_code=400,
                detail="尚未配置 115，请先打开「设置」填写 Cookie",
            )

        urls = [
            u.strip() for u in body.urls if p115_share_svc.is_115_share_link(u)
        ]
        if not urls:
            raise HTTPException(status_code=400, detail="没有可转存的 115 分享链接")

        dest_cid, dest_name = _resolve_p115_folder(
            prev,
            source=body.source,
            folder_cid=body.folder_cid,
            region=body.region,
        )

        # 影视 / 片商：先入「最近接收」；仓库：直存 dest
        want_inbox = _use_receive_inbox(body.source)
        inbox = (
            p115_client.ensure_receive_inbox(cookie) if want_inbox else {"ok": False}
        )
        use_inbox = bool(want_inbox and inbox.get("ok") and inbox.get("cid"))
        inbox_cid = str(inbox.get("cid") or "") if use_inbox else dest_cid
        save_cid = inbox_cid if use_inbox else dest_cid

        before_ids: set[str] = set()
        if (
            use_inbox
            and dest_cid not in {"", "0"}
            and inbox_cid != dest_cid
        ):
            before_ids = p115_relocate._snapshot_ids(cookie, inbox_cid)

        result = p115_share_svc.receive_115_shares(
            cookie,
            urls,
            save_cid,
            (body.password or "").strip(),
        )

        relocate_info = None
        if (
            result.get("ok")
            and use_inbox
            and dest_cid not in {"", "0"}
            and inbox_cid != dest_cid
        ):
            relocate_info = p115_relocate.relocate_share_new_items(
                cookie,
                inbox_cid=inbox_cid,
                dest_cid=dest_cid,
                before_ids=before_ids,
            )

        message = str(result.get("message") or "")
        if use_inbox:
            message = f"{message} · 已入「最近接收」"
        else:
            message = f"{message} · 直存「{dest_name or '指定目录'}」"
        if relocate_info and relocate_info.get("ok") and relocate_info.get("moved"):
            message = (
                f"{message} · 已移到「{dest_name or '指定目录'}」"
                f"（{relocate_info.get('moved')}）"
            )
        elif relocate_info and not relocate_info.get("ok"):
            message = f"{message} · 移动：{relocate_info.get('message') or '未移到指定目录'}"
        status = 200 if result.get("ok") else 400
        return _p115_json_response(
            result=result,
            message=message,
            status=status,
            extra={
                "inboxCid": inbox_cid if use_inbox else None,
                "destCid": dest_cid,
                "destName": dest_name,
                "relocate": relocate_info,
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        return _p115_json_response(
            result={"ok": False},
            message=f"转存异常：{type(e).__name__}: {e}",
            status=400,
        )


def _proxy_host_port(raw: str | None) -> str:
    """规范化后的代理 → 展示用 host:port（可含 user:pass@）。"""
    full = _normalize_proxy_url(raw)
    if not full:
        return ""
    parsed = urlparse(full)
    return parsed.netloc or ""


def _flare_host_port(raw: str | None) -> str:
    """FlareSolverr 基址 → 展示用 host:port。"""
    from app.core.outbound_http import normalize_flaresolverr_url

    full = normalize_flaresolverr_url(raw)
    if not full:
        return ""
    parsed = urlparse(full)
    return parsed.netloc or ""


def _as_bool(raw: Any, *, default: bool = False) -> bool:
    if raw is None:
        return default
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, (int, float)):
        return bool(raw)
    s = str(raw).strip().lower()
    if s in ("1", "true", "yes", "on"):
        return True
    if s in ("0", "false", "no", "off", ""):
        return False
    return default


def _network_public(raw: Any) -> dict[str, Any]:
    from app.core.outbound_http import normalize_flaresolverr_url

    stored = ""
    enabled_raw: Any = None
    flare_stored = ""
    flare_enabled_raw: Any = None
    if isinstance(raw, dict):
        stored = _normalize_proxy_url(
            str(raw.get("proxyUrl") or raw.get("proxy_url") or "")
        )
        enabled_raw = raw.get("proxyEnabled")
        if enabled_raw is None:
            enabled_raw = raw.get("proxy_enabled")
        flare_stored = normalize_flaresolverr_url(
            str(
                raw.get("flareSolverrUrl")
                or raw.get("flare_solverr_url")
                or raw.get("flaresolverrUrl")
                or ""
            )
        )
        flare_enabled_raw = raw.get("flareSolverrEnabled")
        if flare_enabled_raw is None:
            flare_enabled_raw = raw.get("flare_solverr_enabled")
    if not stored:
        legacy = settings_store.get_setting("scrape") or {}
        if isinstance(legacy, dict):
            stored = _normalize_proxy_url(
                str(legacy.get("proxyUrl") or legacy.get("proxy_url") or "")
            )
            if enabled_raw is None:
                enabled_raw = legacy.get("proxyEnabled")
                if enabled_raw is None:
                    enabled_raw = legacy.get("proxy_enabled")
    # 有地址且未写开关时默认启用，兼容旧配置
    enabled = _as_bool(enabled_raw, default=bool(stored))
    active = bool(stored and enabled)
    flare_enabled = _as_bool(flare_enabled_raw, default=bool(flare_stored))
    flare_active = bool(flare_stored and flare_enabled)
    return {
        "proxyUrl": _proxy_host_port(stored),
        "proxyEnabled": enabled,
        "configured": active,
        "fromEnv": False,
        "effectiveProxyUrl": _proxy_host_port(stored if active else ""),
        "flareSolverrUrl": _flare_host_port(flare_stored),
        "flareSolverrEnabled": flare_enabled,
        "flareSolverrConfigured": flare_active,
        "effectiveFlareSolverrUrl": _flare_host_port(flare_stored if flare_active else ""),
    }


class NetworkConfig(BaseModel):
    proxy_url: str = Field(default="", alias="proxyUrl")
    proxy_enabled: bool | None = Field(default=None, alias="proxyEnabled")
    flare_solverr_url: str | None = Field(default=None, alias="flareSolverrUrl")
    flare_solverr_enabled: bool | None = Field(default=None, alias="flareSolverrEnabled")

    model_config = {"populate_by_name": True}


def _friendly_probe_error(exc: BaseException) -> str:
    msg = str(exc).strip() or exc.__class__.__name__
    low = msg.lower()
    if "connect" in low or "timeout" in low:
        return "无法连接代理或目标站超时"
    if "proxy" in low:
        return f"代理错误：{msg}"
    return msg


@router.get("/network", response_model=Envelope)
def get_network(_user: dict[str, Any] | None = Depends(get_optional_user)) -> Envelope:
    data = _network_public(settings_store.get_setting(settings_store.LIBRARY_KEY))
    return Envelope(
        data=data,
        message="configured" if data["configured"] else "not_configured",
    )


@router.put("/network", response_model=Envelope)
def put_network(
    body: NetworkConfig,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    from app.core.outbound_http import normalize_flaresolverr_url

    prev = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
    if not isinstance(prev, dict):
        prev = {}
    next_val = dict(prev)
    # 代理：仅当请求显式带了 proxyUrl 字段时更新（Pydantic 总有默认 ""）
    # 前端保存会整包提交；空串表示清空
    next_val["proxyUrl"] = _normalize_proxy_url(body.proxy_url)
    if body.proxy_enabled is not None:
        next_val["proxyEnabled"] = bool(body.proxy_enabled)
    elif "proxyEnabled" not in next_val and "proxy_enabled" not in next_val:
        next_val["proxyEnabled"] = bool(next_val["proxyUrl"])

    if body.flare_solverr_url is not None:
        next_val["flareSolverrUrl"] = normalize_flaresolverr_url(body.flare_solverr_url)
    if body.flare_solverr_enabled is not None:
        next_val["flareSolverrEnabled"] = bool(body.flare_solverr_enabled)
    elif body.flare_solverr_url is not None and (
        "flareSolverrEnabled" not in next_val and "flare_solverr_enabled" not in next_val
    ):
        next_val["flareSolverrEnabled"] = bool(next_val.get("flareSolverrUrl"))

    saved = settings_store.put_setting(settings_store.LIBRARY_KEY, next_val)
    data = _network_public(saved["value"])
    data["updated_at"] = saved["updated_at"]
    return Envelope(data=data, message="saved")


@router.post("/network/test", response_model=Envelope)
def test_network(
    body: NetworkConfig,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
    proxy = _normalize_proxy_url(
        body.proxy_url
        if body.proxy_url is not None and str(body.proxy_url).strip()
        else (
            (raw.get("proxyUrl") or raw.get("proxy_url"))
            if isinstance(raw, dict)
            else ""
        )
    )
    if not proxy:
        raise HTTPException(status_code=400, detail="请先填写代理地址")

    sample_urls = [
        "https://httpbin.org/ip",
        "https://api.ipify.org?format=json",
        "https://api.themoviedb.org/3",
    ]
    last_err = ""
    try:
        with httpx.Client(timeout=12.0, trust_env=False, proxy=proxy) as client:
            for sample_url in sample_urls:
                try:
                    r = client.get(sample_url)
                    ok = r.status_code < 500
                    detail: Any
                    try:
                        detail = r.json() if r.content else {"status": r.status_code}
                    except Exception:
                        detail = {"status": r.status_code}
                    return Envelope(
                        data={
                            "ok": ok,
                            "proxyUrl": _proxy_host_port(proxy),
                            "detail": detail if isinstance(detail, dict) else {"status": r.status_code},
                        },
                        message="代理正常" if ok else f"代理失败（HTTP {r.status_code}）",
                    )
                except Exception as e:
                    last_err = _friendly_probe_error(e)
                    continue
        raise HTTPException(status_code=502, detail=f"代理测试失败：{last_err}")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=502,
            detail=f"代理测试失败：{_friendly_probe_error(e)}",
        ) from e


@router.post("/network/flare-test", response_model=Envelope)
def test_flaresolverr(
    body: NetworkConfig,
    _user: dict[str, Any] = Depends(require_user),
) -> Envelope:
    from app.core.outbound_http import flaresolverr_ping, normalize_flaresolverr_url

    raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
    flare = ""
    if body.flare_solverr_url is not None and str(body.flare_solverr_url).strip():
        flare = normalize_flaresolverr_url(body.flare_solverr_url)
    elif isinstance(raw, dict):
        flare = normalize_flaresolverr_url(
            str(
                raw.get("flareSolverrUrl")
                or raw.get("flare_solverr_url")
                or ""
            )
        )
    if not flare:
        raise HTTPException(status_code=400, detail="请先填写 FlareSolverr 地址")
    try:
        detail = flaresolverr_ping(flare)
        return Envelope(
            data={
                "ok": True,
                "flareSolverrUrl": _flare_host_port(flare),
                "detail": detail,
            },
            message="FlareSolverr 正常",
        )
    except Exception as e:
        raise HTTPException(
            status_code=502,
            detail=f"FlareSolverr 测试失败：{_friendly_probe_error(e)}",
        ) from e


# —— 片商管理（数据源链接） ——


