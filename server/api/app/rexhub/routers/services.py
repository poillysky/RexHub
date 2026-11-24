"""App 端服务管理：只读展示 NAS 服务卡片与在线状态。

凭据字段（用户名 / 密码 / 数据库 / API Key）只在 Web 管理台维护，不下发到 App。
内容源（``source_kind=shortdrama`` 等）也走同一份清单，额外通过
``/api/services/{id}/media`` 代理相对路径的封面等静态资源。
"""


import asyncio
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from app.rexhub import network_store, services_store
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/services", tags=["services"])

MEDIA_TIMEOUT = 15


class ServiceCard(BaseModel):
    id: str
    name: str
    category: str
    categoryLabel: str
    section: str = ""
    host: str
    port: int
    url: str
    api_base: str = ""
    source_kind: str = ""
    enabled: bool = True
    ui: dict = Field(default_factory=dict)
    notes: str
    online: bool | None = None
    latency: int | None = None


class ServiceListResponse(BaseModel):
    items: list[ServiceCard]


@router.get("", response_model=ServiceListResponse)
async def list_services(
    request: Request,
) -> ServiceListResponse:
    require_session(request)

    items = services_store.list_services()
    # 端口探测是阻塞 socket，放到线程池里，避免卡住事件循环。
    probes = await asyncio.to_thread(services_store.statuses, items)

    cards = []
    for item in items:
        probe = probes.get(item.get("id", ""), {})
        cards.append(
            ServiceCard(
                id=str(item.get("id") or ""),
                name=str(item.get("name") or ""),
                category=str(item.get("category") or "other"),
                categoryLabel=services_store.category_label(
                    str(item.get("category") or "other")
                ),
                section=str(item.get("section") or ""),
                host=str(item.get("host") or ""),
                port=int(item.get("port") or 0),
                url=str(item.get("url") or ""),
                api_base=str(item.get("api_base") or ""),
                source_kind=str(item.get("source_kind") or ""),
                enabled=bool(item.get("enabled", True)),
                ui=item.get("ui") if isinstance(item.get("ui"), dict) else {},
                notes=str(item.get("notes") or ""),
                online=probe.get("online"),
                latency=probe.get("latency"),
            )
        )

    return ServiceListResponse(items=cards)


@router.get("/{service_id}/media")
async def service_media(
    service_id: str,
    request: Request,
    path: str = Query(min_length=1, max_length=500),
    token: str | None = Query(default=None),
):
    """代理内容源的相对资源（封面 / logo），避免 App 直接拼接上游地址。"""
    require_session(request, token)
    row = services_store.get_service(service_id)
    base = str((row or {}).get("api_base") or "").strip().rstrip("/")
    if not base:
        raise HTTPException(status_code=404, detail="服务不存在")
    if not path.startswith("/") or path.startswith("//"):
        raise HTTPException(status_code=400, detail="非法资源路径")
    target = base + path

    def open_upstream():
        req = urllib.request.Request(target, method="GET", headers={"Accept": "*/*"})
        return network_store.open_url(req, MEDIA_TIMEOUT, "shortdrama")

    try:
        upstream = await asyncio.to_thread(open_upstream)
    except urllib.error.HTTPError as error:
        error.close()
        raise HTTPException(status_code=404, detail="资源不存在") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise HTTPException(status_code=503, detail="资源暂不可用") from error

    content_type = str(upstream.headers.get("content-type") or "application/octet-stream")

    def chunks():
        try:
            while True:
                chunk = upstream.read(64 * 1024)
                if not chunk:
                    break
                yield chunk
        finally:
            upstream.close()

    return StreamingResponse(chunks(), media_type=content_type)
