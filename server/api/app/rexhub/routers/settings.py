"""App 端外观配置：图标库地址列表与 GitHub 仓库预览。

配置统一由服务端保存，App 负责管理，避免每台设备各存一份。
预览请求也走服务端，才能复用面板里配置的代理。
"""

from urllib.parse import quote, urlparse

import httpx
from fastapi import Request, APIRouter, HTTPException, Response, status
from pydantic import BaseModel, Field

from app.core.outbound_http import resolve_scrape_proxy_url
from app.rexhub import appearance_store, network_store
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/settings", tags=["settings"])

GITHUB_RAW = "https://raw.githubusercontent.com"
JSDELIVR_DATA = "https://data.jsdelivr.com/v1/packages/gh"
JSDELIVR_CDN = "https://cdn.jsdelivr.net/gh"
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".svg", ".webp", ".gif")
PREVIEW_LIMIT = 1000  # 只做安全上限，翻页交给前端
# 图标库清单允许代理的图片来源，避免变成任意地址转发器
ASSET_HOSTS = {"raw.githubusercontent.com", "cdn.jsdelivr.net", "github.com"}


class IconLibrariesPayload(BaseModel):
    urls: list[str] = Field(default_factory=list)


class IconLibrariesResponse(BaseModel):
    urls: list[str]



@router.get("/icon-libraries", response_model=IconLibrariesResponse)
async def get_icon_libraries(
    request: Request,
) -> IconLibrariesResponse:
    require_session(request)
    return IconLibrariesResponse(urls=appearance_store.icon_libraries())


@router.put("/icon-libraries", response_model=IconLibrariesResponse)
async def put_icon_libraries(
    payload: IconLibrariesPayload,
    request: Request,
) -> IconLibrariesResponse:
    require_session(request)
    try:
        urls = appearance_store.save_icon_libraries(payload.urls)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc
    return IconLibrariesResponse(urls=urls)


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


def _outbound_client() -> httpx.AsyncClient:
    """预览与缩略图统一走面板代理，否则国内直连 GitHub 会失败。"""
    kwargs: dict = {
        "timeout": httpx.Timeout(15.0, connect=6.0),
        "trust_env": False,
        "follow_redirects": True,
        "headers": {"User-Agent": "RexHub", "Accept": "application/vnd.github+json"},
    }
    proxy = resolve_scrape_proxy_url()
    if proxy:
        kwargs["proxy"] = proxy
    return httpx.AsyncClient(**kwargs)


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


async def _preview_json_library(url: str) -> dict:
    """读取 JSON 清单（如 GG-Icon.json）并给出可直接加载的图片地址。"""
    try:
        async with _outbound_client() as client:
            res = await client.get(url)
    except Exception as exc:  # 网络 / 代理 / DNS
        raise HTTPException(status_code=502, detail=f"无法读取图标库：{exc}") from exc
    if res.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"图标库返回 HTTP {res.status_code}")
    try:
        data = res.json()
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="图标库不是有效的 JSON") from exc
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
    paths: list[str] = []
    version = "HEAD"
    try:
        async with _outbound_client() as client:
            found = await _icons_via_jsdelivr(client, owner, name)
            if found:
                icons, version = found
                buckets: dict[int, list[str]] = {}
                for p in icons:
                    buckets.setdefault(p.count("/"), []).append(p)
                # 根目录通常只放横幅，优先挑图标最集中的那一层
                depth = max(buckets, key=lambda d: len(buckets[d]) if d > 0 else 0)
                paths = buckets[depth]
            else:
                entries = await _contents(client, owner, name)
                paths = _pick_images(entries)
                if not paths:
                    dirs = [e for e in entries if e.get("type") == "dir"]
                    if dirs:
                        paths = _pick_images(await _contents(client, owner, name, dirs[0]["path"]))
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
    encoded = quote(path)
    encoded_ref = quote(ref.strip() or "HEAD")
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
                    return Response(
                        content=res.content,
                        media_type=res.headers.get("content-type", "image/png"),
                        headers={"Cache-Control": "public, max-age=86400"},
                    )
                last_error = f"图片获取失败（HTTP {res.status_code}）"
    except Exception as exc:
        last_error = f"图片获取失败：{exc}"
    raise HTTPException(status_code=502, detail=last_error)


@router.get("/icon-libraries/asset")
async def icon_library_asset(url: str, request: Request) -> Response:
    """代理 JSON 清单里的图片字节，并限制来源域名防止成为任意转发器。"""
    require_session(request)
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        raise HTTPException(status_code=400, detail="参数不合法")
    if parsed.scheme not in ("http", "https") or parsed.hostname not in ASSET_HOSTS:
        raise HTTPException(status_code=400, detail="不支持的图标地址")
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
    return Response(
        content=res.content,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )
