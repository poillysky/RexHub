"""115 网盘浏览与播放直链。

App 只拿文件列表和临时直链，Cookie 始终留在服务端；播放时视频流量直连 115 CDN，
不经过本地服务中转。
"""


import asyncio
import json
import os
import re
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
import app.p115.client as p115_client
import app.p115.extract as p115_extract
import app.p115.offline as p115_offline
import app.p115.relocate as p115_relocate
import app.p115.share as p115_share_svc
from app.core.envelope import Envelope
from app.rexhub import pan115, progress_store
from app.rexhub.auth_guard import require_session
from app.rexhub.pan_targets import _resolve_p115_folder, _use_receive_inbox

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


class CloudClearBody(BaseModel):
    mode: str = "done"


class P115OfflineBody(BaseModel):
    urls: list[str] = Field(min_length=1, max_length=50)
    folder_cid: str | None = Field(default=None, alias="folderCid")
    source: str | None = None
    password: str | None = None
    region: str | None = None
    title_hint: str | None = Field(default=None, alias="titleHint")
    auto_extract: bool | None = Field(default=None, alias="autoExtract")

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



def _upstream_error(exc: Exception) -> HTTPException:
    detail = str(exc) or "115 网盘请求失败"
    if "尚未绑定" in detail:
        return HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=detail)


_ARCHIVE_EXT_RE = re.compile(r"\.(zip|rar|7z)(?:\.[a-z0-9]+)?$", re.I)


def _is_offline_url(link: str) -> bool:
    lower = (link or "").strip().lower()
    if not lower or lower.startswith("unavailable://"):
        return False
    if lower.startswith("ed2k://") or lower.startswith("magnet:"):
        return True
    if "115cdn.com/s/" in lower or "115.com/s/" in lower:
        return False
    return bool(re.match(r"^(https?://|ftp://)", lower))


def _looks_archive_link(link: str) -> bool:
    lower = (link or "").strip().lower()
    # ed2k://|file|name.zip|size|hash|/ — 取文件名段再测扩展名
    if lower.startswith("ed2k://"):
        parts = (link or "").split("|")
        if len(parts) >= 3:
            return bool(_ARCHIVE_EXT_RE.search(parts[2].strip()))
    return bool(_ARCHIVE_EXT_RE.search(lower))


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


@router.post("/cloud/clear")
async def cloud_clear(
    request: Request,
    body: CloudClearBody,
) -> dict:
    """批量清理离线任务：done（已完成）/ failed（已失败）/ all。"""
    require_session(request)
    result = await asyncio.to_thread(
        p115_offline.clear_offline_tasks, pan115.cookie_string(), body.mode
    )
    if not result.get("ok"):
        detail = str(result.get("message") or "清理离线任务失败")
        if "Cookie" in detail or "登录" in detail:
            raise HTTPException(status_code=409, detail=detail)
        raise HTTPException(status_code=502, detail=detail)
    pan115._invalidate_cloud_cache()
    return result


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


@router.post("/offline")
def post_p115_offline(
    body: P115OfflineBody,
    request: Request,
) -> JSONResponse:
    """离线转存：影视/片商先入「最近接收」再归位；仓库直存目标目录（云下载）。"""
    require_session(request)
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

        # 最终目录：影视→movie/tv；片商六区→对应配置目录（source 丢失时用 region 兜底）
        dest_cid, dest_name = _resolve_p115_folder(
            prev,
            source=body.source,
            folder_cid=body.folder_cid,
            region=body.region,
        )

        # 影视 / 片商：先入「最近接收」；仓库：直存 dest（云下载）
        want_inbox = _use_receive_inbox(body.source)
        inbox = (
            p115_client.ensure_receive_inbox(cookie) if want_inbox else {"ok": False}
        )
        use_inbox = bool(want_inbox and inbox.get("ok") and inbox.get("cid"))
        inbox_cid = str(inbox.get("cid") or "") if use_inbox else dest_cid
        save_cid = inbox_cid if use_inbox else dest_cid

        result = p115_offline.add_offline_tasks(cookie, urls, save_cid)
        password = (body.password or "").strip()
        looks_archive = any(_looks_archive_link(u) for u in urls)
        # 补齐 infoHashes（ed2k 文件 hash），避免后台轮询匹配不到、不解压
        info_hashes = [
            str(h).lower()
            for h in (result.get("infoHashes") or [])
            if h
        ]
        for h in p115_offline.hashes_from_offline_urls(urls):
            if h not in info_hashes:
                info_hashes.append(h)
        result["infoHashes"] = info_hashes

        added_n = int(result.get("added") or 0)
        # 任务已存在(10008)时 added 也可能为 0，但仍需解压/归位
        actionable = bool(result.get("ok")) and (added_n > 0 or bool(info_hashes))
        want_extract = (
            actionable
            and body.auto_extract is not False
            and (bool(password) or looks_archive or body.auto_extract is True)
        )

        relocate_scheduled = False
        extract_scheduled = False
        if (
            actionable
            and use_inbox
            and dest_cid not in {"", "0"}
            and inbox_cid != dest_cid
        ):
            p115_relocate.schedule_deferred_relocate(
                {
                    "cookie": cookie,
                    "inboxCid": inbox_cid,
                    "destCid": dest_cid,
                    "password": password,
                    "infoHashes": info_hashes,
                    "titleHint": body.title_hint or "",
                    "wantExtract": want_extract,
                }
            )
            relocate_scheduled = True
        elif want_extract:
            # 仓库直存：在目标目录内轮询完成后云解压（不经最近接收）
            p115_extract.schedule_deferred_extract(
                {
                    "cookie": cookie,
                    "folderCid": dest_cid,
                    "password": password,
                    "infoHashes": info_hashes,
                    "titleHint": body.title_hint or "",
                }
            )
            extract_scheduled = True


        message = str(result.get("message") or "")
        dest_label = dest_name or "指定目录"
        if use_inbox:
            message = f"{message} · 已入「最近接收」"
        else:
            message = f"{message} · 直存「{dest_label}」"
        if relocate_scheduled:
            message = (
                f"{message} · 后台等待完成后移到「{dest_label}」"
                + ("（含云解压）" if want_extract else "")
            )
        elif extract_scheduled:
            message = f"{message} · 后台完成后在「{dest_label}」内云解压"

        status = 200 if result.get("ok") else 400
        return _p115_json_response(
            result=result,
            message=message,
            status=status,
            extra={
                "inboxCid": inbox_cid if use_inbox else None,
                "destCid": dest_cid,
                "destName": dest_name,
                "relocateScheduled": relocate_scheduled,
                "extractScheduled": extract_scheduled
                or (relocate_scheduled and want_extract),
                "extractMode": (
                    "poll-relocate"
                    if relocate_scheduled
                    else ("poll" if extract_scheduled else None)
                ),
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
    """分享转存：影视/片商先入「最近接收」再归位；仓库直存目标目录。"""
    require_session(request)
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

        # 影视 / 片商：先入「最近接收」；仓库：直存 dest
        want_inbox = _use_receive_inbox(body.source)
        inbox = (
            p115_client.ensure_receive_inbox(cookie) if want_inbox else {"ok": False}
        )
        use_inbox = bool(want_inbox and inbox.get("ok") and inbox.get("cid"))
        inbox_cid = str(inbox.get("cid") or "") if use_inbox else dest_cid
        save_cid = inbox_cid if use_inbox else dest_cid

        before_ids: set[str] = set()
        if (
            use_inbox
            and dest_cid not in {"", "0"}
            and inbox_cid != dest_cid
        ):
            before_ids = p115_relocate._snapshot_ids(cookie, inbox_cid)

        result = p115_share_svc.receive_115_shares(
            cookie,
            urls,
            save_cid,
            (body.password or "").strip(),
        )

        relocate_info = None
        if (
            result.get("ok")
            and use_inbox
            and dest_cid not in {"", "0"}
            and inbox_cid != dest_cid
        ):
            relocate_info = p115_relocate.relocate_share_new_items(
                cookie,
                inbox_cid=inbox_cid,
                dest_cid=dest_cid,
                before_ids=before_ids,
            )

        message = str(result.get("message") or "")
        if use_inbox:
            message = f"{message} · 已入「最近接收」"
        else:
            message = f"{message} · 直存「{dest_name or '指定目录'}」"
        if relocate_info and relocate_info.get("ok") and relocate_info.get("moved"):
            message = (
                f"{message} · 已移到「{dest_name or '指定目录'}」"
                f"（{relocate_info.get('moved')}）"
            )
        elif relocate_info and not relocate_info.get("ok"):
            message = f"{message} · 移动：{relocate_info.get('message') or '未移到指定目录'}"
        status = 200 if result.get("ok") else 400
        return _p115_json_response(
            result=result,
            message=message,
            status=status,
            extra={
                "inboxCid": inbox_cid if use_inbox else None,
                "destCid": dest_cid,
                "destName": dest_name,
                "relocate": relocate_info,
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
