"""App 端服务管理：只读展示 NAS 服务卡片与在线状态。

凭据字段（用户名 / 密码 / 数据库 / API Key）只在 Web 管理台维护，不下发到 App。
"""


import asyncio

from fastapi import Request, APIRouter
from pydantic import BaseModel

from app.rexhub import services_store
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/services", tags=["services"])


class ServiceCard(BaseModel):
    id: str
    name: str
    category: str
    categoryLabel: str
    host: str
    port: int
    url: str
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
                host=str(item.get("host") or ""),
                port=int(item.get("port") or 0),
                url=str(item.get("url") or ""),
                notes=str(item.get("notes") or ""),
                online=probe.get("online"),
                latency=probe.get("latency"),
            )
        )

    return ServiceListResponse(items=cards)
