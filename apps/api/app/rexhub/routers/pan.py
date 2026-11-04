"""115 网盘浏览与播放直链。

App 只拿文件列表和临时直链，Cookie 始终留在服务端；播放时视频流量直连 115 CDN，
不经过本地服务中转。
"""


import asyncio
import os
import tempfile

from fastapi import (
    Request,
    APIRouter,
    File,
    Form,
    HTTPException,
    Query,
    Response,
    UploadFile,
    status,
)
from pydantic import BaseModel, Field

from app.rexhub import pan115, progress_store
from app.rexhub.auth_guard import require_session

router = APIRouter(prefix="/api/pan", tags=["pan"])


class CloudAddBody(BaseModel):
    urls: list[str] = Field(default_factory=list)
    cid: str = "0"


class SaveBody(BaseModel):
    urls: list[str] = Field(default_factory=list)
    password: str = ""
    cid: str = "0"


class CloudTaskBody(BaseModel):
    info_hash: str = ""


class FolderBody(BaseModel):
    cid: str = "0"
    name: str = ""


class DeleteBody(BaseModel):
    ids: list[str] = Field(default_factory=list)


class RenameBody(BaseModel):
    id: str = ""
    name: str = ""


class RenamePair(BaseModel):
    id: str = ""
    name: str = ""


class RenameBatchBody(BaseModel):
    items: list[RenamePair] = Field(default_factory=list)


class TransferBody(BaseModel):
    ids: list[str] = Field(default_factory=list)
    cid: str = "0"


class ProgressBody(BaseModel):
    pickcode: str = ""
    position: float = 0
    duration: float = 0



def _upstream_error(exc: Exception) -> HTTPException:
    detail = str(exc) or "115 网盘请求失败"
    if "尚未绑定" in detail:
        return HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=detail)


@router.get("/account")
async def account(request: Request) -> dict:
    """115 账号快照：头像、用户名、VIP 与容量，Cookie 不出服务端。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.check)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.get("/cloud")
async def cloud(
    request: Request,
    stat: int = Query(default=0),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=30, ge=1, le=200),
) -> dict:
    """云下载任务列表：stat 0 全部 / 9 失败 / 11 已完成 / 12 进行中。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.cloud_tasks, stat, page, page_size)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/cloud")
async def cloud_add(
    request: Request,
    body: CloudAddBody,
) -> dict:
    """添加云下载任务：支持 HTTP / HTTPS / FTP / 磁力 / 电驴链接。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.cloud_add, body.urls, body.cid)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/save")
async def save_to_drive(
    body: SaveBody,
    request: Request,
) -> dict:
    """资源转存：115 分享链接走接收分享，其余链接走云下载。"""
    require_session(request)
    try:
        return await asyncio.to_thread(
            pan115.save_to_drive, body.urls, body.password, body.cid
        )
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/cloud/retry")
async def cloud_retry(
    body: CloudTaskBody,
    request: Request,
) -> dict:
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.cloud_retry, body.info_hash)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/cloud/delete")
async def cloud_delete(
    body: CloudTaskBody,
    request: Request,
) -> dict:
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.cloud_delete, body.info_hash)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.get("/list")
async def list_dir(
    request: Request,
    cid: str = "0",
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=200, ge=1, le=1150),
) -> dict:
    """列目录：cid=0 为根目录。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.list_files, cid, offset, limit)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/folder")
async def folder_create(
    request: Request,
    body: FolderBody,
) -> dict:
    """在当前目录新建文件夹。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.create_folder, body.cid, body.name)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/delete")
async def delete(
    body: DeleteBody,
    request: Request,
) -> dict:
    """批量删除（移入 115 回收站）。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.delete_items, body.ids)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/rename")
async def rename(
    body: RenameBody,
    request: Request,
) -> dict:
    """重命名单个文件 / 文件夹。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.rename_item, body.id, body.name)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/rename-batch")
async def rename_batch(
    body: RenameBatchBody,
    request: Request,
) -> dict:
    """批量重命名，一次请求提交多组新名称。"""
    require_session(request)
    pairs = [(pair.id, pair.name) for pair in body.items]
    try:
        return await asyncio.to_thread(pan115.rename_items, pairs)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/move")
async def move(
    body: TransferBody,
    request: Request,
) -> dict:
    """批量移动到指定目录。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.move_items, body.ids, body.cid)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/copy")
async def copy(
    body: TransferBody,
    request: Request,
) -> dict:
    """批量复制到指定目录。"""
    require_session(request)
    try:
        return await asyncio.to_thread(pan115.copy_items, body.ids, body.cid)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/upload")
async def upload(
    request: Request,
    cid: str = Form(default="0"),
    file: UploadFile = File(...),
) -> dict:
    """上传文件：先落到服务端临时文件，再交给 115 上传，完成后立即删除。"""
    require_session(request)
    filename = os.path.basename((file.filename or "").strip()) or "未命名文件"

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".upload")
    path = tmp.name
    try:
        with tmp:
            while chunk := await file.read(1 << 20):
                tmp.write(chunk)
        return await asyncio.to_thread(pan115.upload_file, path, cid, filename)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
        await file.close()


@router.get("/play")
async def play(
    request: Request,
    pickcode: str,
) -> dict:
    """解析播放直链：只返回 URL 与所需请求头，不代理字节流。"""
    require_session(request)
    if not pickcode.strip():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少 pickcode")
    try:
        return await asyncio.to_thread(pan115.play_url, pickcode)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.get("/progress")
async def progress_list(request: Request) -> dict:
    """跨设备观看进度：一次返回全部记录，App 拉取后合并到本地缓存。"""
    require_session(request)
    return {"items": await asyncio.to_thread(progress_store.all_entries)}


@router.put("/progress")
async def progress_save(
    body: ProgressBody,
    request: Request,
) -> dict:
    """上报单个文件的观看进度；位置过小或已到片尾视为看完，服务端直接删除记录。"""
    require_session(request)
    if not body.pickcode.strip():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少 pickcode")
    try:
        item = await asyncio.to_thread(
            progress_store.save, body.pickcode, body.position, body.duration
        )
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="进度保存失败"
        ) from exc
    return {"item": item}


@router.get("/thumb")
async def thumb(
    request: Request,
    sha1: str = Query(default=""),
) -> Response:
    """按文件 sha1 代理 115 缩略图，App 无需持有 Cookie。"""
    require_session(request)
    if not sha1.strip():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少 sha1")
    try:
        data, media_type = await asyncio.to_thread(pan115.thumbnail, sha1)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc
    return Response(
        content=data,
        media_type=media_type,
        headers={"Cache-Control": "private, max-age=86400"},
    )
