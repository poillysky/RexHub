"""115 云解压：转存后轮询离线任务，完成后立即解压。"""


import logging
import re
from typing import Any
from urllib.parse import urlencode

import httpx

from app.p115.client import (
    _read_json,
    encode_form,
    form_headers,
    headers,
    human_error,
)
from app.p115.naming import ARCHIVE_RE, PASSWORD_TAG_RE

log = logging.getLogger("p115-extract")

POLL_MAX_S = 120.0
# 115 云解压不支持分卷；识别后跳过解压、只搬家
MULTIPART_RE = re.compile(
    r"(?:"
    r"\.part\d+\.rar$"
    r"|\.r\d{2,}$"
    r"|\.(?:zip|7z|rar)\.\d{3}$"
    r"|\.z\d{2}$"
    r")",
    re.I,
)
OFFLINE_TASK_MAX_PAGES = 8


def _is_multipart_archive(name: str) -> bool:
    """分卷压缩包：115 云解压不支持。"""
    n = (name or "").strip()
    if not n:
        return False
    if MULTIPART_RE.search(n):
        return True
    # foo.part1.rar 已被 MULTIPART；纯 .rar 单卷不算
    return False


def _same_name_folder_label(archive_name: str, title_hint: str | None = None) -> str:
    base = (archive_name or "").strip()
    if base:
        base = re.sub(r"\.(zip|rar|7z)$", "", base, flags=re.I)
        # 压缩包名里的【密码:xxx】只给解压用，不要带进产物目录名
        base = PASSWORD_TAG_RE.sub("", base).strip()
    if not base:
        base = (title_hint or "").strip() or "解压内容"
    base = re.sub(r'[<>"]', "_", base)
    base = re.sub(r"[/\\:*?|]", "_", base)
    base = re.sub(r"\s+", " ", base).strip()[:200]
    return base or "解压内容"


def _list_folder_files_once(
    client: httpx.Client,
    cookie: str,
    folder_cid: str,
    limit: int = 100,
    offset: int = 0,
) -> list[Any]:
    qs = urlencode(
        {
            "aid": "1",
            "cid": folder_cid or "0",
            "o": "user_ptime",
            "asc": "0",
            "offset": str(max(0, int(offset))),
            "show_dir": "1",
            "limit": str(max(1, min(200, int(limit)))),
            "type": "0",
            "format": "json",
        }
    )
    res = client.get(
        f"https://webapi.115.com/files?{qs}",
        headers=headers(cookie),
    )
    data = _read_json(res)
    return data.get("data") if isinstance(data.get("data"), list) else []


def _list_folder_files_all(
    client: httpx.Client,
    cookie: str,
    folder_cid: str,
    *,
    page_size: int = 200,
    max_pages: int = 20,
) -> list[Any]:
    """分页拉全目录，避免 inbox 内多项时漏压缩包。"""
    out: list[Any] = []
    offset = 0
    for _ in range(max_pages):
        batch = _list_folder_files_once(
            client, cookie, folder_cid, limit=page_size, offset=offset
        )
        if not batch:
            break
        out.extend(batch)
        if len(batch) < page_size:
            break
        offset += page_size
    return out


def _ensure_same_name_folder(
    client: httpx.Client,
    cookie: str,
    parent_cid: str,
    folder_name: str,
) -> dict[str, Any]:
    body = [("pid", parent_cid or "0"), ("cname", folder_name)]
    res = client.post(
        "https://webapi.115.com/files/add",
        content=encode_form(body),
        headers=form_headers(cookie),
    )
    data = _read_json(res)
    cid = str(
        data.get("cid")
        or data.get("file_id")
        or (
            data.get("data", {}).get("cid")
            if isinstance(data.get("data"), dict)
            else ""
        )
        or (
            data.get("data", {}).get("file_id")
            if isinstance(data.get("data"), dict)
            else ""
        )
        or ""
    )
    if (data.get("state") is True or data.get("state") == 1 or data.get("errno") == 0) and cid:
        return {"ok": True, "cid": cid, "name": folder_name}

    try:
        rows = _list_folder_files_all(client, cookie, parent_cid)
        for r in rows:
            if not isinstance(r, dict):
                continue
            if (
                r.get("cid") is not None
                and not r.get("fid")
                and str(r.get("n") or r.get("name") or "").strip() == folder_name
            ):
                return {"ok": True, "cid": str(r["cid"]), "name": folder_name}
    except Exception:
        pass

    return {"ok": False, "message": human_error(data, "创建同名文件夹失败")}


def _list_offline_tasks_pages(
    client: httpx.Client,
    cookie: str,
    *,
    max_pages: int = OFFLINE_TASK_MAX_PAGES,
) -> list[Any]:
    from app.p115.offline import extract_tasks_from_payload, fetch_task_lists_once

    out: list[Any] = []
    seen_hash: set[str] = set()
    for page in range(1, max(1, max_pages) + 1):
        data = fetch_task_lists_once(client, cookie, page=page)
        batch = extract_tasks_from_payload(data)
        if not batch:
            break
        for t in batch:
            if not isinstance(t, dict):
                continue
            h = str(t.get("info_hash") or t.get("infoHash") or "").lower()
            key = h or f"row:{id(t)}"
            if key in seen_hash:
                continue
            seen_hash.add(key)
            out.append(t)
        page_count = data.get("page_count") or data.get("pageCount")
        try:
            if page_count is not None and page >= int(page_count):
                break
        except (TypeError, ValueError):
            pass
        if len(batch) < 30:
            # 115 每页通常较多；过短视为末页
            break
    return out


def _unzip_status_from_payload(data: Any) -> int:
    """115 进度字段位置不统一：data.unzip_status 或 data.extract_status.unzip_status。"""
    if not isinstance(data, dict):
        return -1
    inner = data.get("data") if isinstance(data.get("data"), dict) else {}
    nested = (
        inner.get("extract_status")
        if isinstance(inner.get("extract_status"), dict)
        else {}
    )
    status = (
        nested.get("unzip_status")
        if nested.get("unzip_status") is not None
        else (
            inner.get("unzip_status")
            if inner.get("unzip_status") is not None
            else data.get("unzip_status")
        )
    )
    try:
        return int(status) if status is not None else -1
    except (TypeError, ValueError):
        return -1


def _push_extract(
    client: httpx.Client,
    cookie: str,
    pick_code: str,
    password: str,
) -> dict[str, Any]:
    body = [("pick_code", pick_code), ("secret", password or "")]
    res = client.post(
        "https://webapi.115.com/files/push_extract",
        content=encode_form(body),
        headers=form_headers(cookie),
    )
    data = _read_json(res)
    if data.get("state") is True or data.get("state") == 1 or data.get("errno") == 0:
        return {
            "ok": True,
            "message": "已推送云解压",
            "unzipStatus": _unzip_status_from_payload(data),
        }
    return {"ok": False, "message": human_error(data, "推送云解压失败")}


def _read_push_progress(
    client: httpx.Client,
    cookie: str,
    pick_code: str,
) -> dict[str, Any]:
    qs = urlencode({"pick_code": pick_code})
    res = client.get(
        f"https://webapi.115.com/files/push_extract?{qs}",
        headers=headers(cookie),
    )
    data = _read_json(res)
    status_i = _unzip_status_from_payload(data)
    return {
        "ok": not (
            data.get("state") is False
            or (data.get("errno") and status_i < 0)
        ),
        "unzipStatus": status_i,
        "raw": data,
    }


def _parse_extract_list_items(lst: Any) -> tuple[list[str], list[str]]:
    files: list[str] = []
    dirs: list[str] = []
    if not isinstance(lst, list):
        return files, dirs
    for item in lst:
        if not isinstance(item, dict):
            continue
        name = str(
            item.get("file_name") or item.get("n") or item.get("name") or ""
        ).strip()
        if not name:
            continue
        is_dir = (
            item.get("file_category") == 0
            or item.get("file_category") == "0"
            or bool(item.get("ns"))
            or name.endswith("/")
        )
        if is_dir:
            dirs.append(name.rstrip("/"))
        else:
            files.append(name)
    return files, dirs


def _extract_info_all(
    client: httpx.Client,
    cookie: str,
    pick_code: str,
) -> dict[str, Any]:
    """翻页拉全压缩包根目录，避免大包漏文件/文件夹。"""
    files: list[str] = []
    dirs: list[str] = []
    seen_f: set[str] = set()
    seen_d: set[str] = set()
    next_marker = ""
    last_err = ""

    for _ in range(50):
        qs = urlencode(
            {
                "pick_code": pick_code,
                "file_name": "",
                "next_marker": next_marker,
                "page_count": "999",
                "paths": "文件",
            }
        )
        res = client.get(
            f"https://webapi.115.com/files/extract_info?{qs}",
            headers=headers(cookie),
        )
        data = _read_json(res)
        if data.get("state") is False or data.get("errno"):
            last_err = human_error(data, "读取压缩包目录失败（可能尚未就绪）")
            break

        inner = data.get("data") if isinstance(data.get("data"), dict) else {}
        lst = (
            inner.get("list")
            or data.get("list")
            or inner.get("files")
            or data.get("files")
            or []
        )
        page_files, page_dirs = _parse_extract_list_items(lst)
        for f in page_files:
            if f not in seen_f:
                seen_f.add(f)
                files.append(f)
        for d in page_dirs:
            if d not in seen_d:
                seen_d.add(d)
                dirs.append(d)

        nxt = str(
            inner.get("next_marker")
            or data.get("next_marker")
            or ""
        ).strip()
        if not nxt or nxt == next_marker:
            return {"files": files, "dirs": dirs}
        next_marker = nxt

    if files or dirs:
        # 条目太多翻不完：调用方改用空列表让 115 按“全部解压”处理
        return {"files": files, "dirs": dirs, "truncated": True}
    return {
        "files": [],
        "dirs": [],
        "message": last_err or "读取压缩包目录失败（可能尚未就绪）",
    }


def _add_extract_file(
    client: httpx.Client,
    cookie: str,
    pick_code: str,
    to_pid: str,
    files: list[str],
    dirs: list[str],
) -> dict[str, Any]:
    body: list[tuple[str, str]] = [
        ("pick_code", pick_code),
        ("paths", "文件"),
        ("to_pid", to_pid or "0"),
    ]
    if not files and not dirs:
        # 空列表兜底：请求解压全部（115 约定）
        body.append(("extract_file[]", ""))
    else:
        for f in files:
            body.append(("extract_file[]", f))
        for d in dirs:
            body.append(("extract_dir[]", d))

    res = client.post(
        "https://webapi.115.com/files/add_extract_file",
        content=encode_form(body),
        headers=form_headers(cookie),
    )
    data = _read_json(res)
    extract_id = data.get("extract_id") or (
        data.get("data", {}).get("extract_id")
        if isinstance(data.get("data"), dict)
        else None
    )
    if (
        data.get("state") is True
        or data.get("state") == 1
        or data.get("errno") == 0
        or extract_id
    ):
        return {
            "ok": True,
            "message": "已提交解压到目录",
            "extractId": str(extract_id) if extract_id is not None else "",
        }
    return {"ok": False, "message": human_error(data, "解压到目录失败")}


def _parse_extract_progress(data: dict[str, Any]) -> dict[str, Any]:
    """解析「解压到目录」进度：percent / 已解压字节数 / 是否完成。

    115 的字段层级不统一（data、data.extract_status、顶层），逐层兼容。
    字节数只认明确的“已解压大小”字段名，避免把压缩包原大小当成进度。
    """
    inner = data.get("data") if isinstance(data.get("data"), dict) else {}
    nested = (
        inner.get("extract_status")
        if isinstance(inner.get("extract_status"), dict)
        else {}
    )

    def pick(*keys: str) -> Any:
        for src in (nested, inner, data):
            for key in keys:
                if src.get(key) is not None:
                    return src.get(key)
        return None

    try:
        raw_pct = pick("progress", "percent", "percentDone")
        pct = float(raw_pct) if raw_pct is not None else None
    except (TypeError, ValueError):
        pct = None

    try:
        raw_size = pick("extract_size", "extracted_size", "done_size", "unzip_size")
        done_size = int(float(raw_size)) if raw_size is not None else None
    except (TypeError, ValueError):
        done_size = None

    unzip = _unzip_status_from_payload(data)
    return {
        "percent": pct,
        "bytes": done_size,
        "unzipStatus": unzip,
        # add_extract 响应里的 unzip_status 只代表源包可解压，不代表解压完成
        "done": pct is not None and pct >= 100,
    }


def extract_progress_once(
    client: httpx.Client,
    cookie: str,
    extract_id: str,
) -> dict[str, Any]:
    """单次查询「解压到目录」进度，供按预计完成时间调度（不轮询）。"""
    if not extract_id:
        return {"ok": True, "percent": None, "bytes": None, "done": False}
    qs = urlencode({"extract_id": extract_id})
    try:
        res = client.get(
            f"https://webapi.115.com/files/add_extract?{qs}",
            headers=headers(cookie),
        )
        data = _read_json(res)
    except Exception as err:  # noqa: BLE001 - 网络抖动交给调用方重排
        return {"ok": False, "message": f"查询解压进度失败：{err}"}
    if data.get("state") is False and (data.get("errno") or 0):
        return {"ok": False, "message": human_error(data, "查询解压进度失败")}
    info = _parse_extract_progress(data)
    # add_extract 响应可能带回源文件的 unzip_status（4/6 表示“可解压”），
    # 不代表解压已完成，这里只信 percent
    info["done"] = info["percent"] is not None and info["percent"] >= 100
    return {"ok": True, **info}
