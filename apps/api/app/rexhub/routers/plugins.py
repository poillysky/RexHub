"""插件分发接口：供 Rex / ForwardWidget 订阅索引与拉取模块。"""


from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse, Response

from app.rexhub import plugins_store

router = APIRouter(prefix="/plugins", tags=["plugins"])

NO_CACHE = {"Cache-Control": "no-cache"}


@router.get("/forward-widgets.fwd")
async def widget_index(request: Request) -> JSONResponse:
    return JSONResponse(
        plugins_store.build_index(str(request.base_url)),
        headers=NO_CACHE,
    )


@router.get("/{filename}")
async def widget_module(filename: str) -> Response:
    if not filename.endswith(".js"):
        raise HTTPException(status_code=404, detail="Not Found")
    row = plugins_store.find_by_slug(filename[: -len(".js")])
    if row is None:
        raise HTTPException(status_code=404, detail="插件不存在或已停用")
    body = row.get("source") or ""
    return Response(
        body,
        media_type="application/javascript; charset=utf-8",
        headers=NO_CACHE,
    )
