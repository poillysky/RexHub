"""App 端外观配置：图标库地址列表与 GitHub 仓库预览。

配置统一由服务端保存，App 负责管理，避免每台设备各存一份。
预览请求也走服务端，才能复用面板里配置的代理。
"""

import asyncio
import ipaddress
import json
import socket
import time
from collections import OrderedDict
from urllib.parse import quote, urljoin, urlparse

import httpx
from fastapi import Request, APIRouter, HTTPException, Response, status
from pydantic import BaseModel, Field

from app.core.outbound_http import resolve_proxy_url
from app.rexhub import appearance_store, network_store
from app.rexhub.auth_guard import require_admin, require_session

router = APIRouter(prefix="/api/settings", tags=["settings"])

GITHUB_RAW = "https://raw.githubusercontent.com"
JSDELIVR_DATA = "https://data.jsdelivr.com/v1/packages/gh"
JSDELIVR_CDN = "https://cdn.jsdelivr.net/gh"
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".svg", ".webp", ".gif")
PREVIEW_LIMIT = 1000  # 只做安全上限，翻页交给前端
# 图标库清单允许代理的图片来源，避免变成任意地址转发器
ASSET_HOSTS = {"raw.githubusercontent.com", "cdn.jsdelivr.net", "github.com"}
# JSON 清单体积上限：内容只有图标名与地址，2MB 足够；防止被恶意大文件拖死
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_REDIRECTS = 3
# 图片字节缓存：预览网格会反复请求同一批缩略图，避免每次都回源
MEDIA_CACHE_MAX = 256
_media_cache: "OrderedDict[tuple[str, ...], tuple[bytes, str]]" = OrderedDict()
# 清单与仓库介绍都是慢请求，缓存 10 分钟：面板一次打开会同时取封面和介绍
META_TTL = 600
_json_docs: dict[str, tuple[float, dict]] = {}
_repo_descs: dict[str, tuple[float, str]] = {}


class IconLibrariesPayload(BaseModel):
    urls: list[str] = Field(default_factory=list)


class IconLibrariesResponse(BaseModel):
    urls: list[str]
    # 推荐列表随配置一起下发，前端「恢复推荐」不用再抄一份默认值
    defaults: list[str] = Field(default_factory=list)


@router.get("/icon-libraries", response_model=IconLibrariesResponse)
async def get_icon_libraries(
    request: Request,
) -> IconLibrariesResponse:
    require_session(request)
    return IconLibrariesResponse(
        urls=appearance_store.icon_libraries(),
        defaults=appearance_store.default_icon_libraries(),
    )


@router.put("/icon-libraries", response_model=IconLibrariesResponse)
async def put_icon_libraries(
    payload: IconLibrariesPayload,
    request: Request,
) -> IconLibrariesResponse:
    require_admin(request)
    try:
        urls = appearance_store.save_icon_libraries(payload.urls)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc
    return IconLibrariesResponse(
        urls=urls,
        defaults=appearance_store.default_icon_libraries(),
    )


def _is_json_library(url: str) -> bool:
    """JSON 清单型图标库：文件里直接给出 name + url 列表。"""
    try:
        path = urlparse(url.strip()).path.lower()
    except ValueError:
        return False
    return path.endswith(".json")


def _github_repo(url: str) -> tuple[str, str] | None:
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        return None
    if parsed.hostname not in ("github.com", "www.github.com"):
        return None
    parts = [p for p in parsed.path.split("/") if p]
    if len(parts) < 2:
        return None
    return parts[0], parts[1].removesuffix(".git")


def _outbound_client(*, follow_redirects: bool = True) -> httpx.AsyncClient:
    """预览与缩略图统一走面板代理，否则国内直连 GitHub 会失败。

    读取用户提供的地址时关闭自动跳转，逐跳校验目标，避免公网域名 302 到内网。
    """
    kwargs: dict = {
        "timeout": httpx.Timeout(15.0, connect=6.0),
        "trust_env": False,
        "follow_redirects": follow_redirects,
        "headers": {"User-Agent": "RexHub", "Accept": "application/vnd.github+json"},
    }
    proxy = resolve_proxy_url()
    if proxy:
        kwargs["proxy"] = proxy
    return httpx.AsyncClient(**kwargs)


async def _ensure_public_url(url: str) -> None:
    """只允许访问公网 http(s) 地址，防止预览接口被当作内网探测器。"""
    try:
        parsed = urlparse(url.strip())
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="图标库地址不合法") from exc
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise HTTPException(status_code=400, detail="图标库地址必须是 http 或 https 开头的完整链接")
    try:
        infos = await asyncio.get_running_loop().getaddrinfo(
            parsed.hostname, port, type=socket.SOCK_STREAM
        )
    except OSError as exc:
        raise HTTPException(status_code=502, detail="无法解析图标库域名") from exc
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="图标库地址不合法") from exc
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
            or ip.is_unspecified
        ):
            raise HTTPException(status_code=400, detail="图标库地址不能指向本机或内网")


async def _read_json_library(client: httpx.AsyncClient, url: str) -> dict:
    """逐跳校验后读取 JSON 清单，并限制体积。"""
    current = url.strip()
    for _ in range(MAX_REDIRECTS + 1):
        await _ensure_public_url(current)
        async with client.stream("GET", current) as res:
            if res.status_code in (301, 302, 303, 307, 308):
                location = res.headers.get("location")
                if not location:
                    raise HTTPException(status_code=502, detail=f"图标库返回 HTTP {res.status_code}")
                current = urljoin(current, location)
                continue
            if res.status_code >= 400:
                raise HTTPException(status_code=502, detail=f"图标库返回 HTTP {res.status_code}")
            payload = bytearray()
            async for chunk in res.aiter_bytes():
                payload.extend(chunk)
                if len(payload) > MAX_JSON_BYTES:
                    raise HTTPException(status_code=400, detail="图标库文件过大（上限 2MB）")
            try:
                return json.loads(bytes(payload))
            except ValueError as exc:
                raise HTTPException(status_code=400, detail="图标库不是有效的 JSON") from exc
    raise HTTPException(status_code=502, detail="图标库跳转次数过多")


def _cached_media(key: tuple[str, ...]) -> tuple[bytes, str] | None:
    hit = _media_cache.get(key)
    if hit:
        _media_cache.move_to_end(key)
    return hit


def _remember_media(key: tuple[str, ...], data: bytes, media_type: str) -> None:
    _media_cache[key] = (data, media_type)
    _media_cache.move_to_end(key)
    while len(_media_cache) > MEDIA_CACHE_MAX:
        _media_cache.popitem(last=False)


def _image_response(data: bytes, media_type: str) -> Response:
    return Response(
        content=data,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )


async def _contents(
    client: httpx.AsyncClient, owner: str, repo: str, path: str = ""
) -> list[dict]:
    url = f"{network_store.github_api()}/repos/{owner}/{repo}/contents"
    if path:
        url = f"{url}/{quote(path)}"
    res = await client.get(url, headers=network_store.github_headers())
    if res.status_code == 404:
        raise HTTPException(status_code=404, detail="仓库不存在或无法访问")
    if res.status_code == 403:
        raise HTTPException(status_code=429, detail="GitHub 接口限流，请稍后重试")
    if res.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"GitHub 返回 {res.status_code}")
    data = res.json()
    return data if isinstance(data, list) else []


def _pick_images(entries: list[dict]) -> list[str]:
    return [
        str(e["path"])
        for e in entries
        if e.get("type") == "file"
        and str(e.get("name", "")).lower().endswith(IMAGE_EXT)
    ]


def _flatten(files: list[dict], prefix: str = "") -> list[str]:
    out: list[str] = []
    for entry in files:
        name = str(entry.get("name") or "")
        if not name:
            continue
        path = f"{prefix}/{name}" if prefix else name
        if entry.get("type") == "directory":
            out.extend(_flatten(entry.get("files") or [], path))
        else:
            out.append(path)
    return out


async def _icons_via_jsdelivr(
    client: httpx.AsyncClient, owner: str, repo: str
) -> tuple[list[str], str] | None:
    """jsDelivr 的包索引没有限流，优先用它列文件；失败再回退 GitHub API。

    返回 (图标路径, 版本号)。版本号必须带回去拼缩略图：
    仓库默认分支可能已经重构，只有打标签的快照里还有这些文件。
    """
    try:
        meta = await client.get(f"{JSDELIVR_DATA}/{owner}/{repo}")
        if meta.status_code >= 400:
            return None
        versions = meta.json().get("versions") or []
        if not versions:
            return None
        # 包根路径只给版本列表，文件树要按具体版本再取一次
        version = versions[0].get("version")
        if not version:
            return None
        res = await client.get(f"{JSDELIVR_DATA}/{owner}/{repo}@{version}")
        if res.status_code >= 400:
            return None
        data = res.json()
    except Exception:
        return None
    files = _flatten(data.get("files") or [])
    return [p for p in files if p.lower().endswith(IMAGE_EXT)], str(version)


def _json_icons(data: object) -> list[dict]:
    """把 JSON 清单归一成图标条目，图片字节仍走 asset 代理。"""
    entries = data.get("icons") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        raise HTTPException(status_code=400, detail="JSON 里没有 icons 列表")
    icons: list[dict] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        src = str(entry.get("url") or "").strip()
        if not src.startswith(("http://", "https://")):
            continue
        icons.append(
            {
                "name": name or src.rsplit("/", 1)[-1],
                "repo": "",
                "path": src,
                # 浏览器直连 GitHub 会被墙，统一由服务端代理字节
                "src": f"/settings/icon-libraries/asset?url={quote(src, safe='')}",
            }
        )
    return icons


async def _read_json_library_file(url: str) -> dict:
    cached = _json_docs.get(url)
    if cached and cached[0] > time.monotonic():
        return cached[1]
    try:
        async with _outbound_client(follow_redirects=False) as client:
            data = await _read_json_library(client, url)
    except HTTPException:
        raise
    except Exception as exc:  # 代理 / DNS 等网络异常
        raise HTTPException(status_code=502, detail=f"无法读取图标库：{exc}") from exc
    _json_docs[url] = (time.monotonic() + META_TTL, data)
    return data


# 图标合集/雪碧图：整张图放在网格和 30px 封面里只会糊成一团，直接排除
AGGREGATE_NAMES = {"icons.svg", "sprite.svg", "all.svg", "icon-set.svg"}


def _is_aggregate(path: str) -> bool:
    lower = path.lower()
    return lower.rsplit("/", 1)[-1] in AGGREGATE_NAMES or lower.startswith("icon-set/")


async def _github_icon_paths(
    client: httpx.AsyncClient, owner: str, repo: str
) -> tuple[list[str], str]:
    """列出仓库图标路径与版本号；jsDelivr 优先，失败回退 GitHub API。"""
    found = await _icons_via_jsdelivr(client, owner, repo)
    if found:
        icons, version = found
        icons = [p for p in icons if not _is_aggregate(p)]
        if not icons:
            return [], version
        buckets: dict[int, list[str]] = {}
        for p in icons:
            buckets.setdefault(p.count("/"), []).append(p)
        # 根目录通常只放横幅，优先挑图标最集中的那一层
        depth = max(buckets, key=lambda d: len(buckets[d]) if d > 0 else 0)
        return sorted(buckets[depth]), version
    entries = await _contents(client, owner, repo)
    paths = [p for p in _pick_images(entries) if not _is_aggregate(p)]
    if paths:
        return sorted(paths), "HEAD"
    # 根目录只有图片时优先 svg/png/icons 目录；否则逐个目录试，跳过 .github 这类
    dirs = [
        e for e in entries
        if e.get("type") == "dir" and not str(e.get("name", "")).startswith(".")
    ]
    dirs.sort(key=lambda e: str(e.get("name", "")).lower() not in ("svg", "png", "webp", "icons", "icon"))
    for entry in dirs[:6]:
        try:
            found_paths = await _contents(client, owner, repo, str(entry.get("path")))
        except HTTPException:
            continue
        paths = [p for p in _pick_images(found_paths) if not _is_aggregate(p)]
        if paths:
            return sorted(paths), "HEAD"
    return [], "HEAD"


async def _preview_json_library(url: str) -> dict:
    """读取 JSON 清单（如 GG-Icon.json）并给出可直接加载的图片地址。"""
    icons = _json_icons(await _read_json_library_file(url))
    return {"total": len(icons), "version": "JSON", "icons": icons[:PREVIEW_LIMIT]}


@router.get("/icon-libraries/preview")
async def preview_icon_library(url: str, request: Request) -> dict:
    """列出仓库里的图标；优先根目录，根目录没有图时取最浅一层分类目录。"""
    require_session(request)
    if _is_json_library(url):
        return await _preview_json_library(url.strip())
    repo = _github_repo(url)
    if repo is None:
        raise HTTPException(status_code=400, detail="仅支持 GitHub 仓库或 JSON 清单在线预览")
    owner, name = repo
    try:
        async with _outbound_client() as client:
            paths, version = await _github_icon_paths(client, owner, name)
    except HTTPException:
        raise
    except Exception as exc:  # 网络 / 代理 / DNS
        raise HTTPException(status_code=502, detail=f"无法连接 GitHub：{exc}") from exc
    return {
        "total": len(paths),
        "version": version,
        "icons": [
            {"name": p.rsplit("/", 1)[-1], "repo": f"{owner}/{name}", "path": p}
            for p in paths[:PREVIEW_LIMIT]
        ],
    }


async def _thumb_bytes(owner: str, name: str, path: str, ref: str) -> tuple[bytes, str]:
    """取仓库图片字节：jsDelivr CDN 优先，失败回退 GitHub raw。"""
    encoded = quote(path)
    encoded_ref = quote(ref.strip() or "HEAD")
    key = ("thumb", owner, name, path, encoded_ref)
    cached = _cached_media(key)
    if cached:
        return cached
    sources = (
        f"{JSDELIVR_CDN}/{owner}/{name}@{encoded_ref}/{encoded}",
        f"{GITHUB_RAW}/{owner}/{name}/{encoded_ref}/{encoded}",
    )
    last_error = "图片获取失败"
    try:
        async with _outbound_client() as client:
            for src in sources:
                res = await client.get(src)
                if res.status_code < 400:
                    data = res.content
                    media_type = res.headers.get("content-type", "image/png")
                    _remember_media(key, data, media_type)
                    return data, media_type
                last_error = f"图片获取失败（HTTP {res.status_code}）"
    except Exception as exc:
        last_error = f"图片获取失败：{exc}"
    raise HTTPException(status_code=502, detail=last_error)


async def _asset_bytes(url: str) -> tuple[bytes, str]:
    """取 JSON 清单里的图片字节，并限制来源域名防止成为任意转发器。"""
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        raise HTTPException(status_code=400, detail="参数不合法")
    if parsed.scheme not in ("http", "https") or parsed.hostname not in ASSET_HOSTS:
        raise HTTPException(status_code=400, detail="不支持的图标地址")
    key = ("asset", url)
    cached = _cached_media(key)
    if cached:
        return cached
    try:
        async with _outbound_client() as client:
            res = await client.get(url)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"图片获取失败：{exc}") from exc
    if res.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"图片获取失败（HTTP {res.status_code}）")
    media_type = res.headers.get("content-type", "image/png").split(";", 1)[0]
    if not media_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="该地址不是图片资源")
    _remember_media(key, res.content, media_type)
    return res.content, media_type


@router.get("/icon-libraries/thumb")
async def icon_library_thumb(
    repo: str, path: str, request: Request, ref: str = "HEAD"
) -> Response:
    """代理缩略图字节：浏览器直连 GitHub 会被墙，且 jsDelivr CDN 在国内可用。

    ref 用预览时解析到的版本号：仓库默认分支可能已重构，老标签里才有对应文件。
    """
    require_session(request)
    owner, _, name = repo.partition("/")
    if not owner or not name or not path.lower().endswith(IMAGE_EXT):
        raise HTTPException(status_code=400, detail="参数不合法")
    return _image_response(*await _thumb_bytes(owner, name, path, ref))


@router.get("/icon-libraries/asset")
async def icon_library_asset(url: str, request: Request) -> Response:
    """代理 JSON 清单里的图片字节，并限制来源域名防止成为任意转发器。"""
    require_session(request)
    return _image_response(*await _asset_bytes(url))


@router.get("/icon-libraries/cover")
async def icon_library_cover(url: str, request: Request) -> Response:
    """列表封面：取图标库第一个图标；失败由前端回退缩略图。"""
    require_session(request)
    url = url.strip()
    if _is_json_library(url):
        icons = _json_icons(await _read_json_library_file(url))
        if not icons:
            raise HTTPException(status_code=404, detail="图标库没有可用图标")
        return _image_response(*await _asset_bytes(str(icons[0]["path"])))
    repo = _github_repo(url)
    if repo is None:
        raise HTTPException(status_code=400, detail="仅支持 GitHub 仓库或 JSON 清单")
    owner, name = repo
    try:
        async with _outbound_client() as client:
            paths, version = await _github_icon_paths(client, owner, name)
    except HTTPException:
        raise
    except Exception as exc:  # 网络 / 代理 / DNS
        raise HTTPException(status_code=502, detail=f"无法连接 GitHub：{exc}") from exc
    if not paths:
        raise HTTPException(status_code=404, detail="仓库里没有图标")
    return _image_response(*await _thumb_bytes(owner, name, paths[0], version))


async def _repo_description(owner: str, name: str) -> str:
    """GitHub 仓库简介；失败按空处理，介绍只是装饰信息。"""
    key = f"{owner}/{name}".lower()
    cached = _repo_descs.get(key)
    if cached and cached[0] > time.monotonic():
        return cached[1]
    try:
        async with _outbound_client() as client:
            res = await client.get(
                f"{network_store.github_api()}/repos/{owner}/{name}",
                headers=network_store.github_headers(),
            )
        data = res.json() if res.status_code < 400 else {}
    except Exception:
        return ""
    desc = str(data.get("description") or "").strip() if isinstance(data, dict) else ""
    _repo_descs[key] = (time.monotonic() + META_TTL, desc)
    return desc


@router.get("/icon-libraries/info")
async def icon_library_info(url: str, request: Request) -> dict:
    """列表行介绍：GitHub 取仓库描述，JSON 清单取可选的 description 字段。"""
    require_session(request)
    url = url.strip()
    if _is_json_library(url):
        try:
            data = await _read_json_library_file(url)
        except HTTPException:
            return {"description": ""}
        desc = str(data.get("description") or "").strip() if isinstance(data, dict) else ""
        return {"description": desc}
    repo = _github_repo(url)
    if repo is None:
        return {"description": ""}
    return {"description": await _repo_description(*repo)}
