"""MorePlay (CatPawOpen) 影视在线播放服务：设置、猫源搜索与播放流代理。

服务侧公开接口：
- ``GET /health`` 返回 ``{"ok": true, "name": "CatVodSpiderios"}``
- ``GET /t4/config.json`` 返回 TVBox 站点配置
- ``GET {站点 api}?wd=<关键词>`` 搜索；``&ac=detail&ids=<id>`` 详情
- ``GET /t4/vod?play=<token>`` 解析播放地址与请求头

播放地址来自夸克/百度等网盘 CDN，必须携带解析结果里的 ``header``（含 Cookie）
才能通过防盗链，因此播放流统一由本服务代理，Cookie 不下发到客户端。
"""


import hashlib
import ipaddress
import re
import socket
import time
from typing import Any
from urllib.parse import parse_qs, quote_plus, urljoin, urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

import app.core.settings_store as settings_store
from app.rexhub.auth_guard import require_session
from app.search.pansou_client import _normalize_base

router = APIRouter(tags=["moreplay"])

MOREPLAY_KEY = "moreplay"
DEFAULT_BASE_URL = "http://192.168.2.38:2233"
DEFAULT_SEARCH_SITE = "nodejs_wogg"
DEFAULT_TIMEOUT_S = 15.0

_PLAY_CACHE_TTL_S = 900.0
_MAX_PLAY_SOURCES = 4
_SEARCH_BUDGET_S = 30.0
_REDIRECT_LIMIT = 3
_ALLOWED_MEDIA_TYPES = (
    "video/",
    "audio/",
    "application/vnd.apple.mpegurl",
    "application/x-mpegurl",
    "application/dash+xml",
    "application/octet-stream",
    "binary/octet-stream",
)

_sites_cache: tuple[str, float, list[dict[str, str]]] | None = None
_play_cache: dict[str, tuple[float, dict[str, Any]]] = {}


def _is_public_host(host: str) -> bool:
    """主机名/IP 必须是公网地址：拦掉内网、回环、链路本地与保留段。"""
    if not host:
        return False
    try:
        return bool(ipaddress.ip_address(host).is_global)
    except ValueError:
        pass
    if host.lower().endswith(".localhost"):
        return False
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except OSError:
        return False
    if not infos:
        return False
    for info in infos:
        ip_text = str(info[4][0]).split("%")[0]
        try:
            if not ipaddress.ip_address(ip_text).is_global:
                return False
        except ValueError:
            return False
    return True


def _is_safe_media_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return False
    return _is_public_host(parsed.hostname or "")


def _time_left(deadline: float) -> bool:
    return deadline - time.monotonic() > 0.5


def _remaining(deadline: float, cap: float) -> float:
    return max(0.5, min(cap, deadline - time.monotonic()))


def _title_extra_ok(extra: str) -> bool:
    """只接受画质/语言/季数/年份这类版本后缀，避免把续集当同一部。"""
    if re.fullmatch(r"第[一二三四五六七八九十0-9]+季", extra):
        return True
    if re.fullmatch(r"(19|20)\d{2}", extra):
        return True
    markers = (
        "导演剪辑版",
        "加长版",
        "完整版",
        "未删减",
        "国语版",
        "粤语版",
        "国语",
        "粤语",
        "臻彩",
        "蓝光",
        "高清",
        "杜比",
        "双语",
        "中字",
        "remux",
        "4k",
        "hdr",
        "dv",
        "hd",
        "tc",
    )
    rest = extra
    while rest:
        for marker in markers:
            if rest.startswith(marker):
                rest = rest[len(marker) :]
                break
        else:
            return False
    return True


class MorePlayConfigBody(BaseModel):
    enabled: bool = True
    baseUrl: str = Field(default=DEFAULT_BASE_URL, max_length=300)
    timeoutSec: float = Field(default=DEFAULT_TIMEOUT_S, ge=5, le=120)
    searchSite: str = Field(default=DEFAULT_SEARCH_SITE, max_length=80)


class MorePlayStreamItem(BaseModel):
    addon: str = ""
    addonSlug: str = ""
    name: str = ""
    title: str = ""
    url: str = ""
    externalUrl: str = ""
    infoHash: str = ""
    fileIdx: int | None = None
    filename: str = ""
    size: int | None = None
    kind: str = ""
    playable: bool = False


class MorePlayStreamsResponse(BaseModel):
    streams: list[MorePlayStreamItem]
    total: int = 0
    addons: int = 0
    reason: str = ""


def get_config() -> dict[str, Any]:
    raw = settings_store.get_setting(MOREPLAY_KEY) or {}
    if not isinstance(raw, dict):
        raw = {}
    base = _normalize_base(str(raw.get("baseUrl") or "")) or DEFAULT_BASE_URL
    enabled = raw.get("enabled")
    if enabled is None:
        enabled = True
    search_site = str(raw.get("searchSite") or "").strip() or DEFAULT_SEARCH_SITE
    return {
        "enabled": bool(enabled),
        "baseUrl": base,
        "timeoutSec": max(5.0, min(float(raw.get("timeoutSec") or DEFAULT_TIMEOUT_S), 120.0)),
        "searchSite": search_site,
    }


def _wrap(data: Any, message: str = "ok", status: int = 200) -> dict[str, Any]:
    return {"data": data, "message": message, "status": status}


def _probe(base: str, timeout: float) -> dict[str, Any]:
    try:
        with httpx.Client(
            timeout=timeout, trust_env=False, follow_redirects=True
        ) as client:
            health = client.get(f"{base}/health")
            sites = client.get(f"{base}/t4/config.json")
    except Exception as e:
        return {"ok": False, "message": f"连接失败: {e}"}
    if health.status_code >= 400:
        return {"ok": False, "message": f"健康检查 HTTP {health.status_code}"}
    try:
        payload = health.json()
    except ValueError:
        return {"ok": False, "message": "健康检查响应不是 JSON"}
    if not payload.get("ok"):
        return {"ok": False, "message": str(payload.get("message") or "服务未就绪")}
    name = str(payload.get("name") or "")
    site_count = 0
    if sites.status_code < 400:
        try:
            raw_sites = sites.json().get("sites")
            if isinstance(raw_sites, list):
                site_count = len(raw_sites)
        except ValueError:
            site_count = 0
    return {
        "ok": True,
        "message": "连接成功",
        "serviceName": name,
        "siteCount": site_count,
    }


def _site_id(api: str) -> str:
    try:
        return parse_qs(urlparse(api).query).get("site", [""])[0]
    except Exception:
        return ""


def _load_sites(base: str, timeout: float, *, force: bool = False) -> list[dict[str, str]]:
    """读取 T4 站点配置，仅保留可搜索站点。"""
    global _sites_cache
    now = time.monotonic()
    if not force and _sites_cache and _sites_cache[0] == base and _sites_cache[1] > now:
        return _sites_cache[2]
    with httpx.Client(timeout=timeout, trust_env=False) as client:
        resp = client.get(f"{base}/t4/config.json")
        resp.raise_for_status()
        raw = resp.json().get("sites")
        allowed: set[str] | None = None
        try:
            catalog = client.get(f"{base}/bridge/catalog").json()
            allowed = {
                str(site.get("id") or "")
                for site in catalog.get("sites", [])
                if site.get("searchable")
                and not site.get("utility")
                and site.get("status") == "ready"
            }
        except Exception:
            allowed = None
    sites: list[dict[str, str]] = []
    for row in raw if isinstance(raw, list) else []:
        api = str(row.get("api") or "").strip()
        sid = _site_id(api)
        if not api or not sid or not row.get("searchable"):
            continue
        if allowed is not None and sid not in allowed:
            continue
        name = str(row.get("name") or sid)
        if any(mark in name for mark in ("｜首页", "日期:", "配置｜")):
            continue
        sites.append({"id": sid, "name": name})
    _sites_cache = (base, now + 300.0, sites)
    return sites


def _norm_title(value: Any) -> str:
    return re.sub(r"[^\u4e00-\u9fff0-9A-Za-z]+", "", str(value or "")).lower()


def _title_match(name: Any, title: str) -> bool:
    """同名或「主标题 + 短后缀」（如 臻彩）算命中，续集数字不算。"""
    left, right = _norm_title(name), _norm_title(title)
    if not left or not right:
        return False
    if left == right:
        return True
    if left.startswith(right):
        return _title_extra_ok(left[len(right) :])
    return False


_SEASON_EPISODE_RE = re.compile(r"[Ss](\d{1,2})\s*[-_]?\s*[Ee](\d{1,2})")
_EPISODE_RE = re.compile(r"第\s*0*(\d{1,3})\s*集")


def _episode_token(group: str, is_tv: bool, season: int, episode: int) -> str:
    items = [item for item in group.split("#") if item]
    if not items:
        return ""
    if not is_tv:
        return items[0].partition("$")[2]
    explicit = False
    for item in items:
        label = item.partition("$")[0]
        found = _SEASON_EPISODE_RE.search(label)
        if not found:
            continue
        explicit = True
        if int(found.group(1)) == season and int(found.group(2)) == episode:
            return item.partition("$")[2]
    # 有明确 SxxExx 但季节不匹配（如第 2 季的整季包），直接跳过
    if explicit:
        return ""
    for item in items:
        label = item.partition("$")[0]
        found = _EPISODE_RE.search(label)
        if found and int(found.group(1)) == episode:
            return item.partition("$")[2]
    if 0 < episode <= len(items):
        return items[episode - 1].partition("$")[2]
    return ""


def _play_tokens(
    detail: dict[str, Any], is_tv: bool, season: int, episode: int
) -> list[tuple[str, str]]:
    sources = [x for x in str(detail.get("vod_play_from") or "").split("$$$")]
    groups = [x for x in str(detail.get("vod_play_url") or "").split("$$$")]
    tokens: list[tuple[str, str]] = []
    for index, group in enumerate(groups):
        token = _episode_token(group, is_tv, season, episode)
        if token:
            label = sources[index] if index < len(sources) else "猫源"
            tokens.append((label, token))
    return tokens


def _pick_tokens(tokens: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """跳过转码线路，并按网盘去重（同一网盘的「无限」线路只保留一条）。"""
    picked: list[tuple[str, str]] = []
    seen: set[str] = set()
    for label, token in tokens:
        low = label.lower()
        if any(mark in low for mark in ("极速", "转码", "m3u8")):
            continue
        base = re.sub(r"（[^）]*）|\([^)]*\)", "", label).strip()
        if base in seen:
            continue
        seen.add(base)
        picked.append((label, token))
    return picked


def _search_site(
    client: httpx.Client, api: str, keyword: str, timeout: float
) -> list[dict[str, Any]]:
    resp = client.get(f"{api}&wd={quote_plus(keyword)}", timeout=timeout)
    resp.raise_for_status()
    rows = resp.json().get("list")
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def _fetch_detail(
    client: httpx.Client, api: str, vod_id: str, timeout: float
) -> dict[str, Any]:
    resp = client.get(f"{api}&ac=detail&ids={quote_plus(vod_id)}", timeout=timeout)
    resp.raise_for_status()
    rows = resp.json().get("list")
    return rows[0] if isinstance(rows, list) and rows else {}


def _cache_play(token: str, url: str, headers: dict[str, str]) -> str:
    key = hashlib.sha1(token.encode("utf-8")).hexdigest()[:24]
    _play_cache[key] = (time.time() + _PLAY_CACHE_TTL_S, {"url": url, "headers": headers})
    if len(_play_cache) > 512:
        now = time.time()
        for item_key, (expires, _) in list(_play_cache.items()):
            if expires <= now:
                _play_cache.pop(item_key, None)
        if len(_play_cache) > 512:
            _play_cache.clear()
    return key


def _resolve_play(
    client: httpx.Client, base: str, token: str, timeout: float
) -> tuple[str, dict[str, str]]:
    resp = client.get(f"{base}/t4/vod?play={quote_plus(token)}", timeout=timeout)
    resp.raise_for_status()
    payload = resp.json()
    url = str(payload.get("url") or "").strip()
    header = payload.get("header")
    headers = {
        str(key): str(value)
        for key, value in (header.items() if isinstance(header, dict) else [])
        if value
    }
    return url, headers


@router.get("/settings/moreplay")
def get_moreplay_settings(request: Request) -> dict[str, Any]:
    require_session(request)
    return _wrap(get_config())


@router.put("/settings/moreplay")
def put_moreplay_settings(request: Request, body: MorePlayConfigBody) -> dict[str, Any]:
    require_session(request)
    base = _normalize_base(body.baseUrl)
    if not base:
        raise HTTPException(status_code=400, detail="baseUrl 不能为空")
    settings_store.put_setting(
        MOREPLAY_KEY,
        {
            "enabled": body.enabled,
            "baseUrl": base,
            "timeoutSec": body.timeoutSec,
            "searchSite": body.searchSite.strip() or DEFAULT_SEARCH_SITE,
        },
    )
    return _wrap(get_config(), "saved")


@router.get("/moreplay/health")
def moreplay_health(request: Request) -> dict[str, Any]:
    require_session(request)
    cfg = get_config()
    base = str(cfg["baseUrl"])
    if not cfg["enabled"]:
        return _wrap({"ok": False, "configured": False, "baseUrl": base, "message": "未启用"})
    result = _probe(base, float(cfg["timeoutSec"]))
    return _wrap({"configured": True, "baseUrl": base, **result})


@router.get("/moreplay/sites")
def moreplay_sites(request: Request) -> dict[str, Any]:
    require_session(request)
    cfg = get_config()
    try:
        sites = _load_sites(str(cfg["baseUrl"]), float(cfg["timeoutSec"]))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"读取猫源站点失败: {e}") from e
    return _wrap({"sites": sites})


@router.get("/media/moreplay/streams", response_model=MorePlayStreamsResponse)
def moreplay_streams(
    request: Request,
    title: str = Query(..., min_length=1, max_length=200),
    year: str = Query("", max_length=10),
    mediaType: str = Query("movie", max_length=12),
    season: int = Query(0, ge=0, le=99),
    episode: int = Query(0, ge=0, le=999),
) -> MorePlayStreamsResponse:
    """按标题搜索猫源，解析出可直接播放的网盘原画线路。"""
    require_session(request)
    cfg = get_config()
    if not cfg["enabled"]:
        return MorePlayStreamsResponse(streams=[], reason="MorePlay 未启用")
    base = str(cfg["baseUrl"])
    timeout = min(max(float(cfg["timeoutSec"]), 10.0), 20.0)
    is_tv = mediaType == "tv"
    season_no = max(1, season if season > 0 else 1)
    ep = max(1, episode)
    deadline = time.monotonic() + _SEARCH_BUDGET_S
    try:
        sites = _load_sites(base, _remaining(deadline, timeout))
    except Exception as e:
        return MorePlayStreamsResponse(streams=[], reason=f"读取猫源站点失败: {e}")
    if not sites:
        return MorePlayStreamsResponse(streams=[], reason="MorePlay 没有可搜索站点")

    preferred = next((s for s in sites if s["id"] == cfg["searchSite"]), sites[0])
    attempts = [preferred]
    # 首选站源没有可播放线路时，再试两个常见内容站；总时长由 deadline 兜底
    for fallback_id in ("nodejs_huban", "nodejs_duoduo"):
        site = next((s for s in sites if s["id"] == fallback_id), None)
        if site and site["id"] != preferred["id"]:
            attempts.append(site)

    streams: list[MorePlayStreamItem] = []
    tried: list[str] = []
    try:
        with httpx.Client(timeout=timeout, trust_env=False) as client:
            for site in attempts:
                if not _time_left(deadline):
                    break
                tried.append(site["name"])
                api = f"{base}/t4/vod?site={site['id']}"
                try:
                    rows = _search_site(
                        client, api, title, _remaining(deadline, timeout)
                    )
                except Exception:
                    continue
                matched = [
                    row
                    for row in rows
                    if _title_match(row.get("vod_name"), title)
                    and (
                        not year
                        or not str(row.get("vod_year") or "").strip()
                        or str(row.get("vod_year")).strip() == year
                    )
                ]
                if not matched:
                    continue
                # 只取最匹配的一条，避免重复片源拖慢弹层加载
                matched.sort(
                    key=lambda row: 0
                    if _norm_title(row.get("vod_name")) == _norm_title(title)
                    else 1
                )
                for row in matched[:1]:
                    if not _time_left(deadline):
                        break
                    vod_id = str(row.get("vod_id") or "").strip()
                    if not vod_id:
                        continue
                    try:
                        detail = _fetch_detail(
                            client, api, vod_id, _remaining(deadline, timeout)
                        )
                    except Exception:
                        continue
                    vod_name = str(detail.get("vod_name") or row.get("vod_name") or title)
                    tokens = _pick_tokens(_play_tokens(detail, is_tv, season_no, ep))
                    for label, token in tokens:
                        if len(streams) >= _MAX_PLAY_SOURCES or not _time_left(deadline):
                            break
                        try:
                            url, headers = _resolve_play(
                                client, base, token, _remaining(deadline, timeout)
                            )
                        except Exception:
                            continue
                        # 转码线路是 m3u8，v1 只接原画 MP4（m3u8 需要重写分片地址）
                        if not url or ".m3u8" in url.lower():
                            continue
                        key = _cache_play(token, url, headers)
                        streams.append(
                            MorePlayStreamItem(
                                addon=site["name"],
                                addonSlug=site["id"],
                                name=label,
                                title=f"{vod_name} · {label}",
                                url=f"/api/media/moreplay-proxy?key={key}",
                                filename=vod_name,
                                kind="moreplay",
                                playable=True,
                            )
                        )
                    if len(streams) >= _MAX_PLAY_SOURCES:
                        break
                if streams:
                    break
    except Exception as e:
        return MorePlayStreamsResponse(streams=[], reason=f"猫源搜索失败: {e}")

    if streams:
        return MorePlayStreamsResponse(
            streams=streams,
            total=len(streams),
            addons=1,
            reason="",
        )
    return MorePlayStreamsResponse(
        streams=[],
        addons=0,
        reason=f"已尝试 {'、'.join(tried)}，未找到可播放的原画线路",
    )


def _open_stream(
    client: httpx.Client, url: str, headers: dict[str, str]
) -> httpx.Response:
    """手动逐跳跟随重定向，并校验每一跳都是公网 http(s) 地址。"""
    current = url
    for _ in range(_REDIRECT_LIMIT + 1):
        if not _is_safe_media_url(current):
            raise HTTPException(status_code=400, detail="片源地址不安全")
        resp = client.send(
            client.build_request("GET", current, headers=headers), stream=True
        )
        if resp.status_code in (301, 302, 303, 307, 308):
            location = resp.headers.get("location")
            resp.close()
            if not location:
                raise HTTPException(status_code=502, detail="片源重定向地址缺失")
            nxt = urljoin(current, location)
            if not _is_safe_media_url(nxt):
                raise HTTPException(status_code=400, detail="片源重定向到不安全地址")
            if urlparse(nxt).hostname != urlparse(current).hostname:
                # 跨域重定向不把网盘 Cookie 带过去
                for key in ("Cookie", "cookie", "Referer", "referer"):
                    headers.pop(key, None)
            current = nxt
            continue
        return resp
    raise HTTPException(status_code=502, detail="片源重定向次数过多")


@router.get("/media/moreplay-proxy")
def moreplay_proxy(
    request: Request,
    key: str = Query(..., min_length=8, max_length=80),
) -> StreamingResponse:
    """播放流代理：按 key 取回解析结果，带上网盘 Cookie/UA/Referer 拉流。"""
    require_session(request)
    hit = _play_cache.get(key)
    if not hit or hit[0] <= time.time():
        _play_cache.pop(key, None)
        raise HTTPException(status_code=404, detail="片源已过期，请重新加载")
    info = hit[1]
    url = str(info.get("url") or "")
    if not _is_safe_media_url(url):
        raise HTTPException(status_code=400, detail="片源地址不安全")

    headers = dict(info.get("headers") or {})
    range_header = request.headers.get("range")
    if range_header:
        headers["Range"] = range_header

    client = httpx.Client(
        follow_redirects=False,
        timeout=httpx.Timeout(20.0, read=120.0),
        trust_env=False,
    )
    try:
        upstream = _open_stream(client, url, headers)
    except HTTPException:
        client.close()
        raise
    except httpx.HTTPError as exc:
        client.close()
        raise HTTPException(status_code=502, detail="片源拉取失败") from exc

    if upstream.status_code >= 400:
        upstream.close()
        client.close()
        raise HTTPException(
            status_code=502, detail=f"片源直链返回 {upstream.status_code}，可稍后重试"
        )
    content_type = (
        (upstream.headers.get("content-type") or "").split(";")[0].strip().lower()
    )
    if content_type and not content_type.startswith(_ALLOWED_MEDIA_TYPES):
        upstream.close()
        client.close()
        raise HTTPException(
            status_code=502,
            detail=f"片源返回的不是音视频流（{content_type}）",
        )

    def body():
        try:
            for chunk in upstream.iter_bytes(64 * 1024):
                yield chunk
        finally:
            upstream.close()
            client.close()

    passthrough = {
        "Cache-Control": "private, max-age=0",
        "Accept-Ranges": "bytes",
        "X-Content-Type-Options": "nosniff",
    }
    for name in (
        "content-type",
        "content-length",
        "content-range",
        "accept-ranges",
        "etag",
        "last-modified",
    ):
        value = upstream.headers.get(name)
        if value:
            passthrough[name] = value
    # 百度网盘返回 octet-stream / 部分 CDN 不给类型，统一按 MP4 交给浏览器
    if passthrough.get("content-type") in (
        None,
        "",
        "application/octet-stream",
        "binary/octet-stream",
    ):
        passthrough["content-type"] = "video/mp4"
    return StreamingResponse(
        body(), status_code=upstream.status_code, headers=passthrough
    )
