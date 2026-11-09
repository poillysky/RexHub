"""MorePlay (CatPawOpen) 影视在线播放服务：设置、猫源搜索与播放流代理。

服务侧公开接口：
- ``GET /health`` 返回 ``{"ok": true, "name": "CatVodSpiderios"}``
- ``GET /t4/config.json`` 返回 TVBox 站点配置
- ``GET {站点 api}?wd=<关键词>`` 搜索；``&ac=detail&ids=<id>`` 详情
- ``GET /t4/vod?play=<token>`` 解析播放地址与请求头

播放地址来自夸克/百度等网盘 CDN，必须携带解析结果里的 ``header``（含 Cookie）
才能通过防盗链，因此播放流统一由本服务代理，Cookie 不下发到客户端。
"""


import asyncio
import hashlib
import json
import re
import time
from collections.abc import AsyncIterator, Callable
from typing import Any
from urllib.parse import parse_qs, quote_plus, urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

import app.core.settings_store as settings_store
from app.auth.routes import require_admin
from app.core.service_config import normalize_base, read_service
from app.core.stream_proxy import proxy_media_stream
from app.rexhub.auth_guard import require_session

router = APIRouter(tags=["moreplay"])

MOREPLAY_KEY = "moreplay"
DEFAULT_BASE_URL = ""
DEFAULT_SEARCH_SITE = ""
DEFAULT_TIMEOUT_S = 15.0

_PLAY_CACHE_TTL_S = 900.0
# 单站点最多返回的线路数；同一网盘最多保留几条（避免百度把其它网盘挤掉）
_MAX_SITE_SOURCES = 6
_MAX_PER_DRIVE = 2
_DRIVE_KEYS = ("百度", "115", "夸克", "uc", "天翼", "阿里", "迅雷", "123", "移动", "pikpak")
_SEARCH_BUDGET_S = 30.0

_sites_cache: tuple[str, float, list[dict[str, str]]] | None = None
_play_cache: dict[str, tuple[float, dict[str, Any]]] = {}


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
    # 自定义搜索站源顺序（最多 3 个，靠前优先）
    searchSites: list[str] = Field(default_factory=list)


class MorePlayTestBody(BaseModel):
    baseUrl: str = Field(default="", max_length=300)
    timeoutSec: float | None = Field(default=None, ge=5, le=120)


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


def _clean_search_sites(values: Any) -> list[str]:
    """去重保序，最多保留 3 个站源 ID。"""
    out: list[str] = []
    for value in values if isinstance(values, list) else []:
        sid = str(value or "").strip()
        if sid and sid not in out:
            out.append(sid)
        if len(out) >= 3:
            break
    return out


def get_config() -> dict[str, Any]:
    raw, cfg = read_service(
        MOREPLAY_KEY,
        default_timeout=DEFAULT_TIMEOUT_S,
        timeout_min=5.0,
        timeout_max=120.0,
    )
    cfg["baseUrl"] = normalize_base(cfg["baseUrl"])
    cfg["searchSite"] = str(raw.get("searchSite") or "").strip()
    # 兼容旧配置：只存了单个 searchSite 时当作唯一站源
    cfg["searchSites"] = _clean_search_sites(raw.get("searchSites")) or (
        [cfg["searchSite"]] if cfg["searchSite"] else []
    )
    return cfg


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
    if not isinstance(payload, dict):
        return {"ok": False, "message": "健康检查响应格式异常"}
    if not payload.get("ok"):
        return {"ok": False, "message": str(payload.get("message") or "服务未就绪")}
    name = str(payload.get("name") or "")
    site_count = 0
    if sites.status_code < 400:
        try:
            raw_sites = sites.json().get("sites")
            if isinstance(raw_sites, list):
                site_count = len(raw_sites)
        except (ValueError, AttributeError):
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
        payload = resp.json()
        raw = payload.get("sites") if isinstance(payload, dict) else None
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


def _drive_of(label: str) -> str:
    """从线路名里识别网盘（百度/UC/夸克/115…），识别不出时退回整条名。"""
    low = label.lower()
    for key in _DRIVE_KEYS:
        if key in low:
            return key
    return re.sub(r"（[^）]*）|\([^)]*\)", "", label).strip()


def _pick_tokens(tokens: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """跳过转码线路，按网盘去重，并保证各网盘都有机会出现。

    同一网盘的「无限」线路只保留一条（与普通线路同名）；但百度不能把
    UC/夸克/115 的名额全占掉，否则用户看到的就只剩百度。
    """
    picked: list[tuple[str, str]] = []
    seen: set[str] = set()
    counts: dict[str, int] = {}
    for label, token in tokens:
        low = label.lower()
        if any(mark in low for mark in ("极速", "转码", "m3u8")):
            continue
        base = re.sub(r"（[^）]*）|\([^)]*\)", "", label).strip()
        if base in seen:
            continue
        seen.add(base)
        drive = _drive_of(label)
        if counts.get(drive, 0) >= _MAX_PER_DRIVE:
            continue
        counts[drive] = counts.get(drive, 0) + 1
        picked.append((label, token))
        if len(picked) >= _MAX_SITE_SOURCES:
            break
    return picked


async def _search_site(
    client: httpx.AsyncClient, api: str, keyword: str, timeout: float
) -> list[dict[str, Any]]:
    resp = await client.get(f"{api}&wd={quote_plus(keyword)}", timeout=timeout)
    resp.raise_for_status()
    rows = resp.json().get("list")
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


async def _fetch_detail(
    client: httpx.AsyncClient, api: str, vod_id: str, timeout: float
) -> dict[str, Any]:
    resp = await client.get(f"{api}&ac=detail&ids={quote_plus(vod_id)}", timeout=timeout)
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


async def _resolve_play(
    client: httpx.AsyncClient, base: str, token: str, timeout: float
) -> tuple[str, dict[str, str]]:
    resp = await client.get(f"{base}/t4/vod?play={quote_plus(token)}", timeout=timeout)
    resp.raise_for_status()
    payload = resp.json()
    if not isinstance(payload, dict):
        return "", {}
    url = str(payload.get("url") or "").strip()
    header = payload.get("header")
    headers = {
        str(key): str(value)
        for key, value in (header.items() if isinstance(header, dict) else [])
        if value
    }
    return url, headers


async def _collect_site(
    client: httpx.AsyncClient,
    base: str,
    site: dict[str, str],
    title: str,
    year: str,
    is_tv: bool,
    season_no: int,
    ep: int,
    deadline: float,
    timeout: float,
    emit: Callable[[MorePlayStreamItem], None],
) -> None:
    """搜索并解析单个站点，每解析出一条线路就立刻 ``emit``。"""
    api = f"{base}/t4/vod?site={site['id']}"
    rows = await _search_site(client, api, title, _remaining(deadline, timeout))
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
        return
    # 只取最匹配的一条，避免同一部剧重复解析拖慢整站
    matched.sort(
        key=lambda row: 0 if _norm_title(row.get("vod_name")) == _norm_title(title) else 1
    )
    vod_id = str(matched[0].get("vod_id") or "").strip()
    if not vod_id:
        return
    detail = await _fetch_detail(client, api, vod_id, _remaining(deadline, timeout))
    vod_name = str(detail.get("vod_name") or matched[0].get("vod_name") or title)
    tokens = _pick_tokens(_play_tokens(detail, is_tv, season_no, ep))
    if not tokens:
        return
    # 同站多条线路并发解析，谁先解析出来先展示；单条失败不影响其它线路
    tasks = {
        asyncio.create_task(
            _resolve_play(client, base, token, _remaining(deadline, timeout))
        ): (label, token)
        for label, token in tokens
    }
    pending = set(tasks)
    try:
        while pending:
            done, pending = await asyncio.wait(
                pending,
                timeout=max(0.1, deadline - time.monotonic()),
                return_when=asyncio.FIRST_COMPLETED,
            )
            if not done:
                break
            for task in done:
                label, token = tasks.pop(task)
                try:
                    url, headers = task.result()
                except Exception:
                    continue
                # 转码线路是 m3u8，v1 只接原画 MP4（m3u8 需要重写分片地址）
                if not url or ".m3u8" in url.lower():
                    continue
                emit(
                    MorePlayStreamItem(
                        addon=site["name"],
                        addonSlug=site["id"],
                        name=label,
                        title=f"{vod_name} · {label}",
                        url=f"/api/media/moreplay-proxy?key={_cache_play(token, url, headers)}",
                        filename=vod_name,
                        kind="moreplay",
                        playable=True,
                    )
                )
    finally:
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)


async def _site_events(
    cfg: dict[str, Any],
    title: str,
    year: str,
    is_tv: bool,
    season_no: int,
    ep: int,
) -> AsyncIterator[dict[str, Any]]:
    """并发搜索多个站点，按完成顺序逐站产出事件（先到先展示）。

    最后一定产出 ``{"type": "done"}``；调用方取消生成器（如客户端断开）
    时，未完成的站点请求会一并取消。
    """
    base = str(cfg["baseUrl"])
    timeout = min(max(float(cfg["timeoutSec"]), 10.0), 20.0)
    try:
        sites = await asyncio.to_thread(_load_sites, base, timeout)
    except Exception as e:
        yield {"type": "done", "reason": f"读取猫源站点失败: {e}", "tried": []}
        return
    if not sites:
        yield {"type": "done", "reason": "MorePlay 没有可搜索站点", "tried": []}
        return

    by_id = {s["id"]: s for s in sites}
    # 按设置页自定义的顺序匹配，最多 3 个；都没配置时退回列表前 3 个
    attempts = [by_id[sid] for sid in cfg["searchSites"] if sid in by_id][:3]
    if not attempts:
        attempts = sites[:3]
    tried = [site["name"] for site in attempts]
    deadline = time.monotonic() + _SEARCH_BUDGET_S

    async with httpx.AsyncClient(
        timeout=timeout, trust_env=False, follow_redirects=True
    ) as client:
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()

        async def worker(site: dict[str, str]) -> None:
            def emit(item: MorePlayStreamItem) -> None:
                queue.put_nowait(
                    {
                        "type": "site",
                        "site": site["name"],
                        "siteId": site["id"],
                        "streams": [item.model_dump()],
                    }
                )

            try:
                await _collect_site(
                    client,
                    base,
                    site,
                    title,
                    year,
                    is_tv,
                    season_no,
                    ep,
                    deadline,
                    timeout,
                    emit,
                )
            except Exception:
                pass
            finally:
                queue.put_nowait({"type": "_finished"})

        workers = [asyncio.create_task(worker(site)) for site in attempts]
        try:
            remaining = len(workers)
            while remaining > 0:
                budget = deadline - time.monotonic()
                if budget <= 0:
                    break
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=budget)
                except asyncio.TimeoutError:
                    break
                if event.get("type") == "_finished":
                    remaining -= 1
                    continue
                yield event
        finally:
            for task in workers:
                task.cancel()
            await asyncio.gather(*workers, return_exceptions=True)
    yield {"type": "done", "tried": tried}


@router.get("/settings/moreplay")
def get_moreplay_settings(request: Request) -> dict[str, Any]:
    require_session(request)
    return _wrap(get_config())


@router.put("/settings/moreplay")
def put_moreplay_settings(request: Request, body: MorePlayConfigBody) -> dict[str, Any]:
    require_admin(request)
    base = normalize_base(body.baseUrl)
    if not base:
        raise HTTPException(status_code=400, detail="地址需为 http(s):// 开头的有效地址")

    def _merge(prev: dict[str, Any]) -> dict[str, Any]:
        ordered = _clean_search_sites(body.searchSites) or _clean_search_sites(
            [body.searchSite]
        )
        return {
            "enabled": body.enabled,
            "baseUrl": base,
            "timeoutSec": body.timeoutSec,
            # searchSite 保留给旧客户端，始终与自定义顺序的第一项一致
            "searchSite": ordered[0] if ordered else "",
            "searchSites": ordered,
        }

    settings_store.update_setting(MOREPLAY_KEY, _merge)
    return _wrap(get_config(), "saved")


@router.post("/moreplay/test")
def test_moreplay_settings(request: Request, body: MorePlayTestBody) -> dict[str, Any]:
    """用请求里的草稿配置探测连接，不落库；地址留空时复用已保存的地址。"""
    require_admin(request)
    prev = get_config()
    if body.baseUrl.strip():
        base = normalize_base(body.baseUrl)
        if not base:
            raise HTTPException(status_code=400, detail="地址需为 http(s):// 开头的有效地址")
    else:
        base = str(prev["baseUrl"])
    if not base:
        raise HTTPException(status_code=400, detail="请填写服务地址")
    timeout = body.timeoutSec or float(prev["timeoutSec"])
    return _wrap(_probe(base, timeout))


@router.get("/moreplay/sites")
def moreplay_sites(request: Request) -> dict[str, Any]:
    require_session(request)
    cfg = get_config()
    if not cfg["baseUrl"]:
        raise HTTPException(status_code=400, detail="请先配置 MorePlay 服务地址")
    try:
        sites = _load_sites(str(cfg["baseUrl"]), float(cfg["timeoutSec"]))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"读取猫源站点失败: {e}") from e
    return _wrap({"sites": sites})


@router.get("/media/moreplay/streams", response_model=MorePlayStreamsResponse)
async def moreplay_streams(
    request: Request,
    title: str = Query(..., min_length=1, max_length=200),
    year: str = Query("", max_length=10),
    mediaType: str = Query("movie", max_length=12),
    season: int = Query(0, ge=0, le=99),
    episode: int = Query(0, ge=0, le=999),
) -> MorePlayStreamsResponse:
    """并发搜索全部站点，合并后一次性返回可直接播放的网盘原画线路。"""
    require_session(request)
    cfg = get_config()
    if not cfg["enabled"]:
        return MorePlayStreamsResponse(streams=[], reason="MorePlay 未启用")
    if not str(cfg["baseUrl"]):
        return MorePlayStreamsResponse(streams=[], reason="MorePlay 未配置服务地址")

    streams: list[MorePlayStreamItem] = []
    reason = ""
    tried: list[str] = []
    async for event in _site_events(
        cfg,
        title,
        year,
        mediaType == "tv",
        max(1, season if season > 0 else 1),
        max(1, episode),
    ):
        if event["type"] == "site":
            streams.extend(MorePlayStreamItem(**item) for item in event["streams"])
        else:
            reason = str(event.get("reason") or "")
            tried = list(event.get("tried") or [])
    return MorePlayStreamsResponse(
        streams=streams,
        total=len(streams),
        addons=len({item.addon for item in streams}),
        reason=""
        if streams
        else (reason or f"已尝试 {'、'.join(tried)}，未找到可播放的原画线路"),
    )


def _ndjson(event: dict[str, Any]) -> bytes:
    return (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


@router.get("/media/moreplay/streams/live")
async def moreplay_streams_live(
    request: Request,
    title: str = Query(..., min_length=1, max_length=200),
    year: str = Query("", max_length=10),
    mediaType: str = Query("movie", max_length=12),
    season: int = Query(0, ge=0, le=99),
    episode: int = Query(0, ge=0, le=999),
) -> StreamingResponse:
    """流式搜索：每命中一个站点就下发一行 NDJSON，客户端断开即取消剩余请求。"""
    require_session(request)
    cfg = get_config()
    is_tv = mediaType == "tv"
    season_no = max(1, season if season > 0 else 1)
    ep = max(1, episode)

    async def body() -> AsyncIterator[bytes]:
        if not cfg["enabled"]:
            yield _ndjson({"type": "done", "reason": "MorePlay 未启用", "tried": []})
            return
        if not str(cfg["baseUrl"]):
            yield _ndjson(
                {"type": "done", "reason": "MorePlay 未配置服务地址", "tried": []}
            )
            return
        async for event in _site_events(cfg, title, year, is_tv, season_no, ep):
            yield _ndjson(event)

    return StreamingResponse(
        body(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


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
    headers = dict(info.get("headers") or {})
    return proxy_media_stream(
        request,
        url,
        headers=headers,
        fallback_content_type="video/mp4",
    )
