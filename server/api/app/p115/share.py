"""115 分享链接转存（share/snap + share/receive）。"""


import logging
import re
from typing import Any
from urllib.parse import parse_qs, urlencode

import httpx

from app.p115.client import (
    _read_json,
    encode_form,
    extract_uid,
    form_headers,
    headers,
    human_error,
    normalize_cookie,
)
from app.p115.naming import ARCHIVE_RE, PASSWORD_TAG_RE

log = logging.getLogger("p115-share")

SHARE_URL_RE = re.compile(
    r"(?:https?://)?(?:www\.)?(115cdn\.com|115\.com)/s/([A-Za-z0-9]+)(?:\?([^\s#]*))?",
    re.I,
)


def is_115_share_link(link: str | None) -> bool:
    lower = (link or "").strip().lower()
    return "115cdn.com/s/" in lower or "115.com/s/" in lower


def _query_param(query: str, key: str) -> str:
    if not query:
        return ""
    q = query[1:] if query.startswith("?") else query
    try:
        params = parse_qs(q, keep_blank_values=True)
        for k in (key, key.upper(), key.lower()):
            vals = params.get(k)
            if vals and vals[0]:
                return str(vals[0]).strip()
    except Exception:
        return ""
    return ""


def parse_115_share_url(
    link: str,
    fallback_password: str = "",
) -> dict[str, str] | None:
    raw = (link or "").strip()
    if not raw:
        return None
    m = SHARE_URL_RE.search(raw)
    if not m:
        return None
    host = (m.group(1) or "115cdn.com").lower()
    share_code = (m.group(2) or "").strip()
    if not share_code:
        return None
    receive_code = (
        _query_param(m.group(3) or "", "password")
        or _query_param(m.group(3) or "", "pwd")
        or _query_param(m.group(3) or "", "passwd")
        or (fallback_password or "").strip()
    )
    url = (
        f"https://{host}/s/{share_code}?password={receive_code}"
        if receive_code
        else f"https://{host}/s/{share_code}"
    )
    return {
        "shareCode": share_code,
        "receiveCode": receive_code,
        "host": host,
        "url": url,
    }


def _share_referer(share: dict[str, str]) -> str:
    return (
        f"https://{share['host']}/s/{share['shareCode']}"
        f"?password={share.get('receiveCode') or ''}&"
    )


def _fetch_share_snap(
    client: httpx.Client,
    cookie: str,
    share: dict[str, str],
    cid: str = "0",
    offset: int = 0,
    limit: int = 100,
) -> dict[str, Any]:
    qs = urlencode(
        {
            "share_code": share["shareCode"],
            "receive_code": share.get("receiveCode") or "",
            "cid": cid,
            "limit": str(limit),
            "offset": str(offset),
            "format": "json",
        }
    )
    try:
        res = client.get(
            f"https://webapi.115.com/share/snap?{qs}",
            headers=headers(cookie, _share_referer(share)),
        )
        data = _read_json(res)
        if not data.get("state"):
            return {
                "ok": False,
                "message": human_error(data, "读取分享内容失败"),
                "list": [],
                "count": 0,
            }
        inner = data.get("data") if isinstance(data.get("data"), dict) else {}
        lst = inner.get("list") if isinstance(inner.get("list"), list) else []
        count = int(inner.get("count") if inner.get("count") is not None else len(lst)) or len(
            lst
        )
        return {"ok": True, "message": "ok", "list": lst, "count": count}
    except Exception as err:
        return {
            "ok": False,
            "message": str(err) or "读取分享内容失败",
            "list": [],
            "count": 0,
        }


def _list_all_share_root_items(
    client: httpx.Client,
    cookie: str,
    share: dict[str, str],
) -> dict[str, Any]:
    file_ids: list[str] = []
    offset = 0
    limit = 100
    total = float("inf")

    while offset < total and offset < 2000:
        page = _fetch_share_snap(client, cookie, share, "0", offset, limit)
        if not page.get("ok"):
            return {"ok": False, "message": page.get("message"), "fileIds": []}
        total = page.get("count") or len(page.get("list") or [])
        for item in page.get("list") or []:
            if not isinstance(item, dict):
                continue
            fid = item.get("fid")
            if fid is None:
                fid = item.get("file_id")
            if fid is None:
                fid = item.get("cid")
            id_str = str(fid or "").strip()
            if id_str and id_str != "0":
                file_ids.append(id_str)
        lst = page.get("list") or []
        if not lst:
            break
        offset += len(lst)
        if len(lst) < limit:
            break

    unique = list(dict.fromkeys(file_ids))
    if not unique:
        return {
            "ok": False,
            "message": "分享内容为空或无法读取文件列表",
            "fileIds": [],
        }
    return {"ok": True, "message": "ok", "fileIds": unique}


def _post_share_receive(
    client: httpx.Client,
    cookie: str,
    share: dict[str, str],
    file_ids: list[str],
    folder_cid: str,
) -> dict[str, Any]:
    uid = extract_uid(cookie)
    if not uid:
        return {"ok": False, "message": "Cookie 缺少 UID"}

    body: list[tuple[str, str]] = [
        ("user_id", uid),
        ("share_code", share["shareCode"]),
        ("receive_code", share.get("receiveCode") or ""),
        ("file_id", ",".join(str(x) for x in file_ids)),
    ]
    if folder_cid and str(folder_cid) != "0":
        body.append(("cid", str(folder_cid)))

    try:
        res = client.post(
            "https://webapi.115.com/share/receive",
            content=encode_form(body),
            headers=form_headers(cookie, _share_referer(share)),
        )
        data = _read_json(res)
        if data.get("state"):
            return {"ok": True, "message": "分享已转存到网盘"}
        err = human_error(data, "分享转存失败")
        if re.search(r"无需重复接收|已经接收|已接收", err):
            return {"ok": True, "message": "分享已在网盘中（无需重复接收）"}
        return {"ok": False, "message": err}
    except Exception as err:
        return {"ok": False, "message": str(err) or "分享转存请求失败"}


LIST_PAGE = 200
MAX_LIST_PAGES = 20


def _folder_snapshot(folder_cid: str) -> dict[str, tuple[str, bool]] | None:
    """目标目录当前的顶层条目（id → 名称、是否文件夹），用于对比转存新增了哪些。

    目录可能超过一页，必须翻完；任何一页失败返回 None，调用方放弃标注密码。
    """
    from app.rexhub import pan115

    snapshot: dict[str, tuple[str, bool]] = {}
    offset = 0
    for _ in range(MAX_LIST_PAGES):
        try:
            data = pan115.list_files(folder_cid or "0", offset, LIST_PAGE)
        except Exception as err:  # noqa: BLE001 - 标记失败不影响转存结果
            log.info("list folder %s for password tag failed: %s", folder_cid, err)
            return None
        items = data.get("items") or []
        for item in items:
            fid = str(item.get("id") or "")
            if fid:
                snapshot[fid] = (str(item.get("name") or ""), bool(item.get("is_dir")))
        if len(items) < LIST_PAGE:
            break
        offset += LIST_PAGE
    return snapshot


def _tagged_name(name: str, is_dir: bool, pwd: str) -> str:
    """压缩包把标记插在扩展名前，文件夹直接追加在末尾；非压缩包返回空串。"""
    tag = f" [密码 {pwd}]"
    if is_dir:
        return f"{name[:180]}{tag}"
    from app.p115.extract import _is_multipart_archive

    # 分卷包改名后（.part1【密码:x】.rar）就认不出分卷了，直接跳过
    if _is_multipart_archive(name):
        return ""
    m = ARCHIVE_RE.search(name)
    if not m:
        return ""
    return f"{name[: m.start()][:170]}{tag}{m.group(0)}"


def _tag_received_items(
    folder_cid: str,
    before: dict[str, tuple[str, bool]] | None,
    password: str,
) -> int:
    """给本次转存新增的压缩包 / 文件夹名追加 ` [密码 xxx]`，解压时直接读名字。"""
    pwd = str(password or "").strip()
    if not pwd or before is None:
        return 0
    after = _folder_snapshot(folder_cid)
    if after is None:
        return 0
    pairs: list[tuple[str, str]] = []
    for fid, (name, is_dir) in after.items():
        if fid in before or not name or PASSWORD_TAG_RE.search(name):
            continue
        new_name = _tagged_name(name, is_dir, pwd)
        if new_name and new_name != name:
            pairs.append((fid, new_name))
    if not pairs:
        return 0
    try:
        from app.rexhub import pan115

        pan115.rename_items(pairs)
    except Exception as err:  # noqa: BLE001 - 标记失败不影响转存结果
        log.info("tag password on received items failed: %s", err)
        return 0
    return len(pairs)


def receive_115_shares(
    cookie_raw: str,
    urls: list[str],
    folder_cid: str = "0",
    fallback_password: str = "",
) -> dict[str, Any]:
    cookie = normalize_cookie(cookie_raw)
    if not cookie:
        return {"ok": False, "message": "Cookie 为空", "received": 0, "failed": []}

    failed: list[dict[str, str]] = []
    received = 0
    tagged = 0
    seen: set[str] = set()

    with httpx.Client(
        timeout=30.0, follow_redirects=True, trust_env=False
    ) as client:
        for raw in urls:
            share = parse_115_share_url(raw, fallback_password)
            if not share:
                failed.append({"url": raw, "message": "不是有效的 115 分享链接"})
                continue
            key = f"{share['host']}/{share['shareCode']}".lower()
            if key in seen:
                continue
            seen.add(key)

            listed = _list_all_share_root_items(client, cookie, share)
            if not listed.get("ok"):
                failed.append(
                    {
                        "url": share["url"],
                        "message": str(listed.get("message") or "读取失败"),
                    }
                )
                continue

            before = _folder_snapshot(folder_cid or "0") if fallback_password else None
            result = _post_share_receive(
                client,
                cookie,
                share,
                listed["fileIds"],
                folder_cid or "0",
            )
            if result.get("ok"):
                received += 1
                if fallback_password:
                    tagged += _tag_received_items(
                        folder_cid or "0", before, fallback_password
                    )
            else:
                failed.append(
                    {
                        "url": share["url"],
                        "message": str(result.get("message") or "转存失败"),
                    }
                )

    tag_note = f"，{tagged} 个压缩包/文件夹已标注解压密码" if tagged else ""
    if received > 0 and not failed:
        return {
            "ok": True,
            "message": f"已转存 {received} 个 115 分享到网盘{tag_note}",
            "received": received,
            "tagged": tagged,
            "failed": failed,
        }
    if received > 0:
        return {
            "ok": True,
            "message": f"转存完成：成功 {received} · 失败 {len(failed)}{tag_note}",
            "received": received,
            "tagged": tagged,
            "failed": failed,
        }
    return {
        "ok": False,
        "message": (failed[0]["message"] if failed else "分享转存失败"),
        "received": 0,
        "tagged": 0,
        "failed": failed,
    }
