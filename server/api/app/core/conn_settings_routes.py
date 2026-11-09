"""115 / TMDB / forum / library display settings (Postgres meta)."""


import logging
import re
import threading
from typing import Any
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.auth.routes import get_optional_user, require_admin, require_user
import app.p115.client as p115_client
import app.core.settings_store as settings_store
import app.p115.qrlogin as p115_qrlogin_svc
from app.core.envelope import Envelope
from app.core.outbound_http import normalize_proxy_url
from app.rexhub import network_store
from app.rexhub.pan_targets import P115_SOURCES, _p115_targets

log = logging.getLogger(__name__)

router = APIRouter(prefix="/settings", tags=["settings"])






def _normalize_proxy_url(raw: str | None) -> str:
    """裸 host:port → http://；非法则空串。（唯一实现见 app.core.outbound_http）"""
    return normalize_proxy_url(raw)



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


def _targets_for_store(
    body_targets: dict[str, P115TargetFolder] | None,
    prev: dict[str, Any] | None,
    *,
    fallback_cid: str,
    fallback_name: str,
) -> dict[str, dict[str, str]]:
    merged = _p115_targets(prev)
    # 旧版顶层 folder_* 落到 search 目录
    if not body_targets:
        merged["search"] = {
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
    search = targets["search"]
    data = {
        "folderCid": search["folderCid"],
        "folderName": search["folderName"],
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
    stored = str((raw or {}).get("apiKey") or (raw or {}).get("api_key") or "").strip()
    hint = ""
    if stored:
        hint = f"{stored[:4]}…{stored[-4:]}" if len(stored) > 10 else "****"
    data: dict[str, Any] = {
        "configured": bool(stored),
        "fromEnv": False,
        "apiKeyHint": hint,
    }
    if include_key and stored:
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
    _user: dict[str, Any] = Depends(require_admin),
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
    key = body.api_key.strip()
    if not key:
        stored = settings_store.get_setting(settings_store.TMDB_KEY) or {}
        key = str(stored.get("apiKey") or stored.get("api_key") or "").strip()
    if not key:
        raise HTTPException(status_code=400, detail="请先填写 TMDB API Key")
    from app.core.outbound_http import resolve_proxy_url

    client_kw: dict[str, Any] = {
        "timeout": httpx.Timeout(12.0, connect=4.0),
        "trust_env": False,
        "follow_redirects": True,
    }
    proxy = resolve_proxy_url()
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
def get_p115(_user: dict[str, Any] = Depends(require_user)) -> Envelope:
    raw = settings_store.get_setting(settings_store.P115_KEY)
    data = _p115_public(raw)
    return Envelope(
        data=data,
        message="configured" if data["configured"] else "not_configured",
    )


@router.get("/p115/status", response_model=Envelope)
def get_p115_status(_user: dict[str, Any] = Depends(require_user)) -> Envelope:
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


@router.post("/p115/qrcode/start", response_model=Envelope)
def post_p115_qrcode_start(
    body: P115QrStartBody | None = None,
    _user: dict[str, Any] = Depends(require_admin),
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
    _user: dict[str, Any] = Depends(require_admin),
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
    _user: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    result = p115_qrlogin_svc.complete_qrlogin(body.uid, body.app)
    if not result.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=str(result.get("message") or "扫码登录失败"),
        )
    cookie = str(result.get("cookie") or "").strip()
    # Cookie 只在服务端保存，绝不回传给客户端
    data: dict[str, Any] = {
        "app": result.get("app"),
        "hasCookie": bool(cookie),
        "saved": False,
    }
    if body.save and cookie:
        prev = settings_store.get_setting(settings_store.P115_KEY) or {}
        # 扫码只是换账号，已有的转存目录要原样保留
        prev_search = _p115_targets(prev)["search"]
        targets = _targets_for_store(
            None,
            prev,
            fallback_cid=prev_search["folderCid"],
            fallback_name=prev_search["folderName"],
        )
        value = {
            "cookie": cookie,
            "folder_cid": prev_search["folderCid"],
            "folder_name": prev_search["folderName"],
            "label": str(prev.get("label") or ""),
            "targets": targets,
        }
        saved = settings_store.update_setting(
            settings_store.P115_KEY,
            lambda cur: {**cur, **value},
        )
        public = _p115_public(saved["value"])
        public["updated_at"] = saved["updated_at"]
        public["saved"] = True
        return Envelope(data=public, message="扫码登录成功，已保存 Cookie")

    return Envelope(data=data, message=str(result.get("message") or "扫码登录成功"))


@router.put("/p115", response_model=Envelope)
def put_p115(
    body: P115Config,
    _user: dict[str, Any] = Depends(require_admin),
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
    # 顶层 folder_* 与 targets.search 是同一份数据（旧字段只是镜像）
    search = stored_targets["search"]
    folder_cid = str(search.get("folderCid") or "0").strip() or "0"
    folder_name = str(search.get("folderName") or "").strip()
    # label 是可选展示名：未提交时保留旧值，避免保存目录时把名称清空
    label = (body.label or "").strip() or str(prev.get("label") or "").strip()

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
            stored_targets["search"] = {
                "folderCid": folder_cid,
                "folderName": folder_name,
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
        "cookie": cookie,
        "folder_cid": folder_cid,
        "folder_name": folder_name,
        "label": label,
        "targets": stored_targets,
    }
    saved = settings_store.update_setting(
        settings_store.P115_KEY,
        lambda cur: {**cur, **value},
    )
    data = _p115_public(saved["value"])
    data["updated_at"] = saved["updated_at"]
    data["quota"] = quota
    data["quotaTotal"] = quota_total
    data.update(extra)
    return Envelope(data=data, message=message)


@router.post("/p115/folders", response_model=Envelope)
def p115_folders(
    body: P115FoldersBody,
    _user: dict[str, Any] = Depends(require_admin),
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
    _user: dict[str, Any] = Depends(require_admin),
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


def _proxy_host_port(raw: str | None) -> str:
    """规范化后的代理 → 展示用 host:port；不返回 user:pass 凭据。"""
    full = _normalize_proxy_url(raw)
    if not full:
        return ""
    parsed = urlparse(full)
    host = parsed.hostname or ""
    if not host:
        return ""
    if ":" in host:
        host = f"[{host}]"
    try:
        port = parsed.port
    except ValueError:
        port = None
    return f"{host}:{port}" if port else host


def _keep_proxy_auth(previous: str, current: str) -> str:
    """面板只展示 host:port；同主机端口的新地址未带凭据时沿用旧 user:pass。"""
    if not current or "@" in current or not previous:
        return current
    old = urlparse(previous)
    new = urlparse(current)
    if not old.username:
        return current
    try:
        if (old.hostname, old.port) != (new.hostname, new.port):
            return current
    except ValueError:
        return current
    auth = old.username + (f":{old.password}" if old.password else "")
    return new._replace(netloc=f"{auth}@{new.netloc}").geturl()



def _flare_host_port(raw: str | None) -> str:
    """FlareSolverr 基址 → 展示用 host:port；不返回凭据。"""
    from app.core.outbound_http import normalize_flaresolverr_url

    full = normalize_flaresolverr_url(raw)
    if not full:
        return ""
    parsed = urlparse(full)
    host = parsed.hostname or ""
    if not host:
        return ""
    if ":" in host:
        host = f"[{host}]"
    try:
        port = parsed.port
    except ValueError:
        port = None
    return f"{host}:{port}" if port else host


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
    # 有地址且未写开关时默认启用
    enabled = _as_bool(enabled_raw, default=bool(stored))
    active = bool(stored and enabled)
    flare_enabled = _as_bool(flare_enabled_raw, default=bool(flare_stored))
    flare_active = bool(flare_stored and flare_enabled)
    gh = network_store.github_settings()
    return {
        "proxyUrl": _proxy_host_port(stored),
        "proxyEnabled": active,
        "configured": active,
        "flareSolverrUrl": _flare_host_port(flare_stored),
        "flareSolverrEnabled": flare_active,
        "flareSolverrConfigured": flare_active,
        "githubApiUrl": gh["api_url"],
        "githubTokenSet": gh["token_set"],
        "githubMirror": gh["mirror"],
        "githubMirrorPresets": gh["mirror_presets"],
    }


class NetworkConfig(BaseModel):
    proxy_url: str | None = Field(default=None, alias="proxyUrl")
    proxy_enabled: bool | None = Field(default=None, alias="proxyEnabled")
    flare_solverr_url: str | None = Field(default=None, alias="flareSolverrUrl")
    flare_solverr_enabled: bool | None = Field(default=None, alias="flareSolverrEnabled")
    github_api_url: str | None = Field(default=None, alias="githubApiUrl")
    github_token: str | None = Field(default=None, alias="githubToken")
    github_mirror: str | None = Field(default=None, alias="githubMirror")

    model_config = {"populate_by_name": True}


# 代理/过盾地址错误文本与前端预校验保持一致
PROXY_URL_ERROR = "代理地址需为 http(s):// 或 socks5:// 开头的有效地址"
FLARE_URL_ERROR = "FlareSolverr 地址需为 http:// 开头的有效地址"


def _valid_host_port(normalized: str) -> bool:
    """归一化后的地址必须带合法端口，避免 host:abc 之类被静默落库。"""
    parsed = urlparse(normalized)
    if not parsed.hostname:
        return False
    try:
        port = parsed.port
    except ValueError:
        return False
    return port is not None and 1 <= port <= 65535


def _draft_proxy_url(raw: str | None) -> str | None:
    """草稿地址校验：None = 未提交；"" = 清空；非法 → 400。"""
    if raw is None:
        return None
    if not str(raw).strip():
        return ""
    normalized = _normalize_proxy_url(raw)
    if not normalized or not _valid_host_port(normalized):
        raise HTTPException(status_code=400, detail=PROXY_URL_ERROR)
    return normalized


def _draft_flare_url(raw: str | None) -> str | None:
    from app.core.outbound_http import normalize_flaresolverr_url

    if raw is None:
        return None
    if not str(raw).strip():
        return ""
    normalized = normalize_flaresolverr_url(raw)
    if not normalized or not _valid_host_port(normalized):
        raise HTTPException(status_code=400, detail=FLARE_URL_ERROR)
    return normalized


_CRED_RE = re.compile(r"(://)[^/@\s]+@")


def _friendly_probe_error(exc: BaseException) -> str:
    msg = _CRED_RE.sub(r"\1***@", str(exc).strip() or exc.__class__.__name__)
    low = msg.lower()
    if "connect" in low or "timeout" in low:
        return "无法连接代理或目标站超时"
    if "proxy" in low:
        return f"代理错误：{msg}"
    return msg


def _restart_proxied_plugins() -> None:
    """代理配置变化后重启走代理的插件，让其进程拿到新的代理环境变量。

    插件进程只在启动时读取一次代理地址；不重启会一直用旧配置，表现为
    某些站点（如野果短剧）直连被重置、页面一直不加载。
    """
    from app.rexhub.plugin_framework import manager, store

    def run() -> None:
        for row in store.list_plugins():
            if not row.get("enabled") or not row.get("proxy"):
                continue
            try:
                manager.restart(str(row["id"]))
            except Exception:  # noqa: BLE001 - 单个插件失败不影响保存
                continue

    threading.Thread(target=run, name="restart-proxied-plugins", daemon=True).start()


@router.get("/network", response_model=Envelope)
def get_network(_user: dict[str, Any] = Depends(require_user)) -> Envelope:
    data = _network_public(settings_store.get_setting(settings_store.LIBRARY_KEY))
    return Envelope(
        data=data,
        message="configured" if data["configured"] else "not_configured",
    )


@router.put("/network", response_model=Envelope)
def put_network(
    body: NetworkConfig,
    _user: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    # 先校验草稿地址，避免「非法地址被静默当成清空」
    proxy_new = _draft_proxy_url(body.proxy_url)
    flare_new = _draft_flare_url(body.flare_solverr_url)

    try:
        network_store.save_github(
            api_url=body.github_api_url,
            token=body.github_token,
            mirror=body.github_mirror,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    def mutate(prev: dict[str, Any]) -> dict[str, Any]:
        next_val = dict(prev)
        if proxy_new is not None:
            # 面板只展示 host:port，同主机端口的旧凭据要保留
            previous = _normalize_proxy_url(
                str(prev.get("proxyUrl") or prev.get("proxy_url") or "")
            )
            next_val["proxyUrl"] = _keep_proxy_auth(previous, proxy_new)
            next_val.pop("proxy_url", None)
        if body.proxy_enabled is not None:
            next_val["proxyEnabled"] = bool(body.proxy_enabled)
        elif proxy_new == "":
            next_val["proxyEnabled"] = False
        elif proxy_new is not None and (
            "proxyEnabled" not in next_val and "proxy_enabled" not in next_val
        ):
            next_val["proxyEnabled"] = bool(next_val.get("proxyUrl"))
        next_val.pop("proxy_enabled", None)

        if flare_new is not None:
            next_val["flareSolverrUrl"] = flare_new
            next_val.pop("flare_solverr_url", None)
        if body.flare_solverr_enabled is not None:
            next_val["flareSolverrEnabled"] = bool(body.flare_solverr_enabled)
        elif flare_new == "":
            next_val["flareSolverrEnabled"] = False
        elif flare_new is not None and (
            "flareSolverrEnabled" not in next_val
            and "flare_solverr_enabled" not in next_val
        ):
            next_val["flareSolverrEnabled"] = bool(next_val.get("flareSolverrUrl"))
        next_val.pop("flare_solverr_enabled", None)
        return next_val

    before_proxy = network_store.proxy_url()
    saved = settings_store.update_setting(settings_store.LIBRARY_KEY, mutate)
    if network_store.proxy_url() != before_proxy:
        _restart_proxied_plugins()
    data = _network_public(saved["value"])
    data["updated_at"] = saved["updated_at"]
    return Envelope(data=data, message="saved")


@router.post("/network/test", response_model=Envelope)
def test_network(
    body: NetworkConfig,
    _user: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
    stored = _normalize_proxy_url(
        str(
            (raw.get("proxyUrl") or raw.get("proxy_url") or "")
            if isinstance(raw, dict)
            else ""
        )
    )
    # 草稿留空时用已保存地址测试；非法草稿由 _draft_proxy_url 统一 400
    proxy = _draft_proxy_url(body.proxy_url) or stored
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
    _user: dict[str, Any] = Depends(require_admin),
) -> Envelope:
    from app.core.outbound_http import flaresolverr_ping, normalize_flaresolverr_url

    raw = settings_store.get_setting(settings_store.LIBRARY_KEY) or {}
    stored = ""
    if isinstance(raw, dict):
        stored = normalize_flaresolverr_url(
            str(
                raw.get("flareSolverrUrl")
                or raw.get("flare_solverr_url")
                or ""
            )
        )
    # 草稿留空时用已保存地址测试；非法草稿由 _draft_flare_url 统一 400
    flare = _draft_flare_url(body.flare_solverr_url) or stored
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


