"""115 网盘浏览与播放直链。

App 只拿文件列表和临时直链，Cookie 始终留在服务端；播放时视频流量直连 115 CDN，
不经过本地服务中转。
"""


import asyncio
import json
import os
import re
import shutil
import tempfile
from typing import Any

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
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import app.core.settings_store as settings_store
import app.p115.extract_jobs as p115_extract_jobs
import app.p115.offline as p115_offline
import app.p115.rename_after_save as p115_rename
import app.p115.share as p115_share_svc
from app.core.envelope import Envelope
from app.rexhub import pan115, progress_store
from app.rexhub.auth_guard import require_session
from app.rexhub.pan_targets import _resolve_p115_folder

router = APIRouter(prefix="/api/pan", tags=["pan"])

# 上传要先落盘再转给 115：限制单文件体积，并给临时目录留出安全余量
UPLOAD_MAX_BYTES = 20 * 1024 * 1024 * 1024
UPLOAD_MIN_FREE_BYTES = 1 * 1024 * 1024 * 1024


class CloudAddBody(BaseModel):
    urls: list[str] = Field(default_factory=list)
    cid: str = "0"


class SaveBody(BaseModel):
    urls: list[str] = Field(default_factory=list)
    password: str = ""
    cid: str = "0"


class CloudTaskBody(BaseModel):
    info_hash: str = ""


class CloudClearBody(BaseModel):
    mode: str = "done"


class P115OfflineBody(BaseModel):
    urls: list[str] = Field(min_length=1, max_length=50)
    folder_cid: str | None = Field(default=None, alias="folderCid")
    source: str | None = None
    password: str | None = None
    region: str | None = None
    title_hint: str | None = Field(default=None, alias="titleHint")

    model_config = {"populate_by_name": True}


class P115ShareBody(BaseModel):
    urls: list[str] = Field(min_length=1, max_length=20)
    folder_cid: str | None = Field(default=None, alias="folderCid")
    source: str | None = None
    password: str | None = None
    region: str | None = None

    model_config = {"populate_by_name": True}


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


class ExtractConfigBody(BaseModel):
    folder_cid: str = Field(default="0", alias="folderCid")
    folder_name: str = Field(default="", alias="folderName")
    password: str = ""

    model_config = {"populate_by_name": True}



def _require_admin(request: Request) -> dict:
    """115 是全服共享的一份账号，目录增删改与解压只允许管理员操作。"""
    user = require_session(request)
    if not user.get("is_admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="需要管理员权限")
    return user


def _upstream_error(exc: Exception) -> HTTPException:
    detail = str(exc) or "115 网盘请求失败"
    if "尚未绑定" in detail:
        return HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=detail)


def _is_offline_url(link: str) -> bool:
    lower = (link or "").strip().lower()
    if not lower or lower.startswith("unavailable://"):
        return False
    if lower.startswith("ed2k://") or lower.startswith("magnet:"):
        return True
    if "115cdn.com/s/" in lower or "115.com/s/" in lower:
        return False
    return bool(re.match(r"^(https?://|ftp://)", lower))


def _p115_public_result(result: dict[str, Any]) -> dict[str, Any]:
    """Strip non-JSON-safe fields (e.g. raw bytes from 115) before responding."""
    out = dict(result or {})
    out.pop("raw", None)
    # Ensure failed rows are plain {url, message}
    failed = out.get("failed")
    if isinstance(failed, list):
        clean: list[dict[str, str]] = []
        for row in failed:
            if not isinstance(row, dict):
                continue
            clean.append(
                {
                    "url": str(row.get("url") or ""),
                    "message": str(row.get("message") or "失败"),
                }
            )
        out["failed"] = clean
    hashes = out.get("infoHashes")
    if isinstance(hashes, list):
        out["infoHashes"] = [str(h) for h in hashes if h]
    per_url = out.get("perUrl")
    if isinstance(per_url, list):
        out["perUrl"] = [
            {
                "url": str(row.get("url") or ""),
                "message": str(row.get("message") or ""),
            }
            for row in per_url
            if isinstance(row, dict)
        ]
    return out


def _p115_json_response(
    *,
    result: dict[str, Any],
    message: str,
    status: int,
    extra: dict[str, Any] | None = None,
) -> JSONResponse:
    data = _p115_public_result(result)
    if extra:
        data.update(extra)
    payload = Envelope(data=data, message=message or "", status=status)
    try:
        content = payload.model_dump()
        # Hard fallback: never 500 on serialization
        json.dumps(content, ensure_ascii=False, default=str)
    except Exception:
        content = {
            "data": {
                "ok": bool(result.get("ok")),
                "added": int(result.get("added") or 0),
                "failed": [],
                "infoHashes": [],
            },
            "message": message or ("转存成功" if result.get("ok") else "转存失败"),
            "status": status,
        }
    return JSONResponse(status_code=status, content=content)


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
    _require_admin(request)
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
    _require_admin(request)
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
    _require_admin(request)
    try:
        return await asyncio.to_thread(pan115.cloud_retry, body.info_hash)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/cloud/clear")
async def cloud_clear(
    request: Request,
    body: CloudClearBody,
) -> dict:
    """批量清理离线任务：done（已完成）/ failed（已失败）/ all。"""
    _require_admin(request)
    result = await asyncio.to_thread(
        p115_offline.clear_offline_tasks, pan115.cookie_string(), body.mode
    )
    if not result.get("ok"):
        detail = str(result.get("message") or "清理离线任务失败")
        if "Cookie" in detail or "登录" in detail:
            raise HTTPException(status_code=409, detail=detail)
        raise HTTPException(status_code=502, detail=detail)
    pan115._invalidate_cloud_cache()
    return _p115_public_result(result)


@router.post("/cloud/delete")
async def cloud_delete(
    body: CloudTaskBody,
    request: Request,
) -> dict:
    _require_admin(request)
    try:
        return await asyncio.to_thread(pan115.cloud_delete, body.info_hash)
    except pan115.Pan115Error as exc:
        raise _upstream_error(exc) from exc
    except Exception as exc:
        raise _upstream_error(exc) from exc


@router.post("/offline")
def post_p115_offline(
    body: P115OfflineBody,
    request: Request,
) -> JSONResponse:
    """离线转存：搜索 / 影视 / 片商三类都直存各自目标目录（云下载）。"""
    _require_admin(request)
    try:
        prev = settings_store.get_setting(settings_store.P115_KEY) or {}
        cookie = str(prev.get("cookie") or "").strip()
        if not cookie:
            raise HTTPException(
                status_code=400,
                detail="尚未配置 115，请先打开「设置」填写 Cookie",
            )

        urls = [
            u.strip()
            for u in body.urls
            if (u or "").strip()
            and _is_offline_url(u)
            and not p115_share_svc.is_115_share_link(u)
        ]
        if not urls:
            raise HTTPException(status_code=400, detail="没有可转存的磁力/ED2K 链接")

        # 三类入口（搜索 / 影视 / 片商）都直存各自目标目录
        dest_cid, dest_name = _resolve_p115_folder(
            prev,
            source=body.source,
            folder_cid=body.folder_cid,
            region=body.region,
        )

        password = (body.password or "").strip()
        # 转存前记下目录现有条目，完成后只给新增的压缩包标注密码
        before_ids = p115_rename.folder_item_ids(dest_cid) if password else None

        result = p115_offline.add_offline_tasks(cookie, urls, dest_cid)
        # 补齐 infoHashes（ed2k 文件 hash），后台轮询据此判断离线任务是否完成
        info_hashes = [
            str(h).lower()
            for h in (result.get("infoHashes") or [])
            if h
        ]
        for h in p115_offline.hashes_from_offline_urls(urls):
            if h not in info_hashes:
                info_hashes.append(h)
        result["infoHashes"] = info_hashes

        # 不再自动解压：有密码时等离线完成，把密码写进压缩包名
        rename_scheduled = False
        if password and before_ids is not None and result.get("ok"):
            p115_rename.schedule_deferred_rename(
                {
                    "cookie": cookie,
                    "folderCid": dest_cid,
                    "password": password,
                    "infoHashes": info_hashes,
                    "titleHint": body.title_hint or "",
                    "beforeIds": sorted(before_ids),
                }
            )
            rename_scheduled = True

        message = str(result.get("message") or "")
        dest_label = dest_name or "指定目录"
        message = f"{message} · 直存「{dest_label}」"
        if rename_scheduled:
            message = f"{message} · 完成后自动给压缩包标注密码"

        status = 200 if result.get("ok") else 400
        return _p115_json_response(
            result=result,
            message=message,
            status=status,
            extra={
                "destCid": dest_cid,
                "destName": dest_name,
                "renameScheduled": rename_scheduled,
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        return _p115_json_response(
            result={"ok": False, "added": 0, "failed": [], "infoHashes": []},
            message=f"转存异常：{type(e).__name__}: {e}",
            status=400,
        )


@router.post("/share")
def post_p115_share(
    body: P115ShareBody,
    request: Request,
) -> JSONResponse:
    """分享转存：搜索/影视/片商三类都直存目标目录。"""
    _require_admin(request)
    try:
        prev = settings_store.get_setting(settings_store.P115_KEY) or {}
        cookie = str(prev.get("cookie") or "").strip()
        if not cookie:
            raise HTTPException(
                status_code=400,
                detail="尚未配置 115，请先打开「设置」填写 Cookie",
            )

        urls = [
            u.strip() for u in body.urls if p115_share_svc.is_115_share_link(u)
        ]
        if not urls:
            raise HTTPException(status_code=400, detail="没有可转存的 115 分享链接")

        dest_cid, dest_name = _resolve_p115_folder(
            prev,
            source=body.source,
            folder_cid=body.folder_cid,
            region=body.region,
        )

        result = p115_share_svc.receive_115_shares(
            cookie,
            urls,
            dest_cid,
            (body.password or "").strip(),
        )

        message = str(result.get("message") or "")
        message = f"{message} · 直存「{dest_name or '指定目录'}」"
        status = 200 if result.get("ok") else 400
        return _p115_json_response(
            result=result,
            message=message,
            status=status,
            extra={
                "destCid": dest_cid,
                "destName": dest_name,
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        return _p115_json_response(
            result={"ok": False},
            message=f"转存异常：{type(e).__name__}: {e}",
            status=400,
        )


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
    _require_admin(request)
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
    _require_admin(request)
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
    _require_admin(request)
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
    _require_admin(request)
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
    _require_admin(request)
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
    _require_admin(request)
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
    _require_admin(request)
    filename = os.path.basename((file.filename or "").strip()) or "未命名文件"

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".upload")
    path = tmp.name
    try:
        # 上传先落盘再转给 115，必须挡住超大文件与磁盘被写满
        if shutil.disk_usage(tempfile.gettempdir()).free < UPLOAD_MIN_FREE_BYTES:
            raise HTTPException(
                status_code=status.HTTP_507_INSUFFICIENT_STORAGE,
                detail="服务端临时空间不足，暂时无法上传",
            )
        written = 0
        with tmp:
            while chunk := await file.read(1 << 20):
                written += len(chunk)
                if written > UPLOAD_MAX_BYTES:
                    raise HTTPException(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        detail=f"文件超过 {UPLOAD_MAX_BYTES // (1 << 30)}GB 上限",
                    )
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


@router.get("/extract/config")
async def extract_config(request: Request) -> dict:
    """解压配置：指定目录与解压密码。"""
    _require_admin(request)
    return await asyncio.to_thread(p115_extract_jobs.get_config)


@router.put("/extract/config")
async def extract_config_save(body: ExtractConfigBody, request: Request) -> dict:
    _require_admin(request)
    return await asyncio.to_thread(
        p115_extract_jobs.save_config,
        body.folder_cid,
        body.folder_name,
        body.password,
    )


@router.get("/extract/preview")
async def extract_preview(request: Request, cid: str = "") -> dict:
    """预览指定目录下待解压的压缩包，不启动队列。"""
    _require_admin(request)
    try:
        return await asyncio.to_thread(p115_extract_jobs.preview, cid)
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.get("/extract/status")
async def extract_status(request: Request) -> dict:
    _require_admin(request)
    return await asyncio.to_thread(p115_extract_jobs.snapshot)


@router.post("/extract/start")
async def extract_start(request: Request) -> dict:
    """启动解压队列：一次只跑一个任务，完成后自动下一个。"""
    _require_admin(request)
    try:
        return await asyncio.to_thread(p115_extract_jobs.start)
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.post("/extract/stop")
async def extract_stop(request: Request) -> dict:
    _require_admin(request)
    return await asyncio.to_thread(p115_extract_jobs.stop)


@router.get("/progress")
async def progress_list(request: Request) -> dict:
    """跨设备观看进度：只返回当前用户的记录，App 拉取后合并到本地缓存。"""
    user = require_session(request)
    owner = str(user.get("id") or user.get("username") or "")
    return {
        "items": await asyncio.to_thread(
            progress_store.all_entries,
            owner,
            include_legacy=bool(user.get("is_admin")),
        )
    }


@router.put("/progress")
async def progress_save(
    body: ProgressBody,
    request: Request,
) -> dict:
    """上报单个文件的观看进度；位置过小或已到片尾视为看完，服务端直接删除记录。"""
    user = require_session(request)
    owner = str(user.get("id") or user.get("username") or "")
    if not body.pickcode.strip():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少 pickcode")
    try:
        item = await asyncio.to_thread(
            progress_store.save, owner, body.pickcode, body.position, body.duration
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
