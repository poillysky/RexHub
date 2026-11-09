"""已启用 addon 的并发拉取公共骨架（片源 / 字幕共用）。"""

import asyncio
from typing import Any, Awaitable, Callable

import httpx

from app.rexhub import network_store

UA = "RexHub-Stremio/1.0"


def text(value: Any, limit: int = 400) -> str:
    if value is None:
        return ""
    return str(value).strip()[:limit]


def resource_names(manifest: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for item in manifest.get("resources") or []:
        if isinstance(item, dict):
            name = text(item.get("name"), 40)
        elif isinstance(item, str):
            name = text(item, 40)
        else:
            name = ""
        if name:
            names.add(name)
    return names


def candidate(
    row: dict[str, Any],
    media_type: str,
    imdb_id: str,
    resource: str,
) -> bool:
    """addon 是否声明了该类资源，且支持当前媒体类型 / id 前缀。"""
    manifest = row.get("manifest")
    if not isinstance(manifest, dict) or resource not in resource_names(manifest):
        return False
    types = [str(item) for item in manifest.get("types") or []]
    if types and media_type not in types:
        return False
    prefixes = manifest.get("idPrefixes")
    if isinstance(prefixes, list) and prefixes:
        if not any(imdb_id.startswith(str(prefix)) for prefix in prefixes):
            return False
    return True


def addon_names(rows: list[dict[str, Any]]) -> dict[Any, str]:
    return {
        row.get("slug"): (
            text((row.get("manifest") or {}).get("name"), 80)
            or text(row.get("slug"), 80)
        )
        for row in rows
    }


def proxy_url() -> str:
    settings = network_store.proxy_settings()
    if settings.get("enabled") and settings.get("targets", {}).get("plugins"):
        return str(settings.get("url") or "")
    return ""


async def gather(
    rows: list[dict[str, Any]],
    names: dict[Any, str],
    fetcher: Callable[[httpx.AsyncClient, dict[str, Any], str], Awaitable[list[dict[str, Any]]]],
    *,
    timeout: float,
    concurrency: int,
) -> list[dict[str, Any]]:
    """并发请求所有 addon，总超时到点取消未完成请求，单条失败静默跳过。"""
    client_kwargs: dict[str, Any] = {
        "headers": {"User-Agent": UA, "Accept": "application/json, */*"},
        "follow_redirects": True,
        "limits": httpx.Limits(max_connections=concurrency),
    }
    proxy = proxy_url()
    if proxy:
        client_kwargs["proxy"] = proxy

    async with httpx.AsyncClient(**client_kwargs) as client:
        tasks = [
            asyncio.create_task(
                fetcher(client, row, names[row.get("slug")])
            )
            for row in rows
        ]
        done, pending = await asyncio.wait(tasks, timeout=timeout)
        for task in pending:
            task.cancel()
        gathered: list[dict[str, Any]] = []
        for task in done:
            if task.cancelled():
                continue
            try:
                gathered.extend(task.result())
            except (httpx.HTTPError, ValueError, OSError):
                continue
    return gathered
