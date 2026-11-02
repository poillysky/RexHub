"""115 网盘登录与状态监控。

使用 p115client 提供的扫码登录与账号接口，不自行实现 115 协议。
授权 Cookie 保存在 data/115_pan.json（0600），不会暴露给前端。
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from typing import Any
from urllib.parse import parse_qs, urlparse

from . import config

AUTH_PATH = config.DATA_DIR / "115_pan.json"


def _redirect_client_cache() -> None:
    """把 p115client 的本地缓存放到 data 目录，避免依赖 $HOME 可写。"""
    try:
        from p115client import util as p115_util

        cache_dir = config.DATA_DIR / "p115cache"
        cache_dir.mkdir(parents=True, exist_ok=True)
        p115_util.UID_TO_STABLE_POINT = p115_util.LockedJsonKV(
            cache_dir / "pickcode_stable_points.json"
        )
        p115_util.UID_TO_USER_KEY = p115_util.LockedJsonKV(
            cache_dir / "userkey_stable_points.json"
        )
    except Exception:
        pass


_redirect_client_cache()

REQ_TIMEOUT = 20
LONG_POLL_TIMEOUT = 45
CACHE_TTL = 30
QR_TIMEOUT = 300
DEFAULT_APP = "alipaymini"

# 支持手机扫码登录的客户端类型（对应 p115client 的 app 参数）
# 电视端（tv/apple_tv）、桌面端（os_*）、平板端（ipad/115ipad/qipad）的 token
# 接口不返回 qrcode 字段，115 对这些端走设备码授权，手机扫码会被判为已过期，
# 因此不在此列出。
QR_APPS: dict[str, str] = {
    "alipaymini": "115生活 · 支付宝小程序",
    "wechatmini": "115生活 · 微信小程序",
    "web": "网页版（Cookie）",
    "ios": "115生活 · 苹果端",
    "115ios": "115 · 苹果端",
    "android": "115生活 · 安卓端",
    "115android": "115 · 安卓端",
    "qandroid": "115管理 · 安卓端",
    "qios": "115管理 · 苹果端",
    "harmony": "115 · 鸿蒙端",
}

_sessions: dict[str, dict[str, Any]] = {}
_tasks: set[asyncio.Task] = set()
_cache: dict[str, Any] = {"at": 0.0, "data": None}
_ua_cache: dict[str, Any] = {"at": 0.0, "value": ""}


class Pan115Error(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# 授权文件
# ---------------------------------------------------------------------------

def _read_auth() -> dict | None:
    try:
        data = json.loads(AUTH_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("cookies"), dict):
        return None
    if not data["cookies"]:
        return None
    return data


def _write_auth(data: dict) -> None:
    config.ensure_data_dir()
    tmp = AUTH_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(AUTH_PATH)


def is_bound() -> bool:
    return _read_auth() is not None


def unbind() -> None:
    try:
        AUTH_PATH.unlink()
    except FileNotFoundError:
        pass
    _cache.update({"at": 0.0, "data": None})


# ---------------------------------------------------------------------------
# Cookie 解析与账号探测
# ---------------------------------------------------------------------------

_CANON = {"uid": "UID", "cid": "CID", "seid": "SEID", "kid": "KID"}


def parse_cookie_input(raw: str) -> dict[str, str]:
    raw = (raw or "").strip()
    if not raw:
        raise Pan115Error("请粘贴 115 Cookie")

    values: dict[str, str] = {}
    if raw.startswith("{"):
        try:
            obj = json.loads(raw)
        except ValueError as exc:
            raise Pan115Error("Cookie 格式不正确") from exc
        source = obj.get("cookies") if isinstance(obj, dict) and "cookies" in obj else obj
        if isinstance(source, dict):
            values = {str(k): str(v) for k, v in source.items()}
    else:
        for part in re.split(r"[;\n]", raw):
            if "=" not in part:
                continue
            key, value = part.split("=", 1)
            key = key.strip()
            if key:
                values[key] = value.strip()

    cookies: dict[str, str] = {}
    for key, value in values.items():
        cookie_name = _CANON.get(key.lower(), key)
        if value:
            cookies[cookie_name] = value

    missing = [name for name in ("UID", "CID", "SEID") if name not in cookies]
    if missing:
        raise Pan115Error(f"Cookie 缺少必要字段：{', '.join(missing)}")
    return cookies


def _num(value: Any) -> int | None:
    if isinstance(value, dict):
        value = value.get("size", value.get("total"))
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def _extract_space(data: dict) -> tuple[int | None, int | None]:
    space = data.get("rt_space_info")
    if not isinstance(space, dict):
        space = data
    total = (
        _num(space.get("all_total"))
        or _num(space.get("total"))
        or _num(space.get("all_total_size"))
    )
    used = (
        _num(space.get("all_used"))
        or _num(space.get("all_use"))
        or _num(space.get("used"))
        or _num(space.get("all_used_size"))
    )
    return total, used


def _ios_user_agent() -> str:
    """伪造 iOS 端 UA，降低 115 对服务端请求的风控概率。"""
    now = time.time()
    if _ua_cache["value"] and now - _ua_cache["at"] < 3600:
        return _ua_cache["value"]

    ua_version = "36.2.20"
    try:
        from p115client import P115Client

        resp = P115Client.app_version_list2()
        data = resp.get("data") or {}
        version = (data.get("115wangpan_iOS") or {}).get("version_code")
        if version:
            ua_version = str(version)
    except Exception:
        pass

    ua = (
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        f"AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 115wangpan_ios/{ua_version}"
    )
    _ua_cache.update({"at": now, "value": ua})
    return ua


def _client(cookies: dict[str, str]):
    from p115client import P115Client

    client = P115Client(cookies, console_qrcode=False)
    try:
        client.headers["user-agent"] = _ios_user_agent()
    except Exception:
        pass
    return client


def _auth_expired(resp: dict) -> bool:
    if resp.get("errno") in (99, 911):
        return True
    message = str(resp.get("message") or resp.get("error") or "")
    return "重新登录" in message or "重新登录" in str(resp.get("data") or "")


def _probe(cookies: dict[str, str]) -> dict[str, Any]:
    client = _client(cookies)

    try:
        space_resp = client.user_space_info(timeout=REQ_TIMEOUT)
    except Exception as exc:
        raise Pan115Error(f"无法连接 115：{exc}") from exc
    if not space_resp.get("state"):
        if _auth_expired(space_resp):
            raise Pan115Error("登录已过期，请重新扫码或重新粘贴 Cookie")
        raise Pan115Error(space_resp.get("message") or "Cookie 已失效，请重新登录")
    total, used = _extract_space(space_resp.get("data") or {})

    username = ""
    user_id = None
    avatar = ""
    vip_active = False
    vip_forever = False
    vip_expire = ""
    try:
        info_resp = client.user_my_info(timeout=REQ_TIMEOUT)
        if info_resp.get("state"):
            info = info_resp.get("data") or {}
            username = str(info.get("user_name") or info.get("uname") or "")
            user_id = info.get("user_id") or info.get("uid")
            face = info.get("face") or {}
            if isinstance(face, dict):
                avatar = str(face.get("face_m") or face.get("face_s") or "")
            vip = info.get("vip") or {}
            if isinstance(vip, dict):
                vip_active = bool(vip.get("is_vip"))
                vip_forever = bool(vip.get("is_forever"))
                vip_expire = str(vip.get("expire_str") or "")
            if total is None:
                total, used = _extract_space(info)
    except Exception:
        pass

    return {
        "username": username,
        "user_id": user_id,
        "avatar": avatar,
        "vip_active": vip_active,
        "vip_forever": vip_forever,
        "vip_expire": vip_expire,
        "total": total,
        "used": used,
    }


def _account(auth: dict) -> dict[str, Any]:
    return {
        "avatar": auth.get("avatar") or "",
        "vip_active": bool(auth.get("vip_active")),
        "vip_forever": bool(auth.get("vip_forever")),
        "vip_expire": auth.get("vip_expire") or "",
    }


def snapshot() -> dict[str, Any]:
    auth = _read_auth()
    if not auth:
        return {
            "bound": False,
            "status": "unbound",
            "username": "",
            "total": None,
            "used": None,
            "bound_at": None,
            "checked_at": None,
            "message": "",
            "avatar": "",
            "vip_active": False,
            "vip_forever": False,
            "vip_expire": "",
        }
    return {
        "bound": True,
        "status": auth.get("last_status") or "pending",
        "username": auth.get("username") or "",
        "total": auth.get("total"),
        "used": auth.get("used"),
        "bound_at": auth.get("bound_at"),
        "checked_at": auth.get("last_check") or None,
        "message": auth.get("last_message") or "",
        **_account(auth),
    }


def check(force: bool = False) -> dict[str, Any]:
    auth = _read_auth()
    if not auth:
        return snapshot()

    now = time.time()
    if not force and _cache["data"] and now - _cache["at"] < CACHE_TTL:
        return _cache["data"]

    result: dict[str, Any]
    try:
        probe = _probe(auth["cookies"])
    except Exception as exc:
        auth.update(
            {
                "last_check": int(now),
                "last_status": "invalid",
                "last_message": str(exc),
            }
        )
        _write_auth(auth)
        result = {
            "bound": True,
            "status": "invalid",
            "username": auth.get("username") or "",
            "total": auth.get("total"),
            "used": auth.get("used"),
            "bound_at": auth.get("bound_at"),
            "checked_at": int(now),
            "message": str(exc),
            **_account(auth),
        }
    else:
        auth.update(
            {
                "username": probe["username"] or auth.get("username") or "",
                "total": probe["total"],
                "used": probe["used"],
                "last_check": int(now),
                "last_status": "ok",
                "last_message": "",
                **_account(probe),
            }
        )
        _write_auth(auth)
        result = {
            "bound": True,
            "status": "ok",
            "username": auth["username"],
            "total": probe["total"],
            "used": probe["used"],
            "bound_at": auth.get("bound_at"),
            "checked_at": int(now),
            "message": "",
            **_account(auth),
        }

    _cache.update({"at": now, "data": result})
    return result


def bind_cookie(raw: str) -> dict[str, Any]:
    cookies = parse_cookie_input(raw)
    probe = _probe(cookies)
    now = int(time.time())
    _write_auth(
        {
            "cookies": cookies,
            "app": "web",
            "bound_at": now,
            "username": probe["username"],
            "total": probe["total"],
            "used": probe["used"],
            "last_check": now,
            "last_status": "ok",
            "last_message": "",
            **_account(probe),
        }
    )
    _cache.update({"at": 0.0, "data": None})
    return check(force=True)


# ---------------------------------------------------------------------------
# 扫码登录
# ---------------------------------------------------------------------------

def qr_image(text: str) -> str:
    import segno

    return segno.make(text, error="m").svg_data_uri(
        scale=4, border=0, dark="#0F172A", light="#FFFFFF"
    )


def _prune_sessions() -> None:
    now = time.time()
    for uid in [uid for uid, s in _sessions.items() if now - s["created"] > QR_TIMEOUT + 60]:
        _sessions.pop(uid, None)


async def _run(func, /, *args, timeout: float = REQ_TIMEOUT, **kwargs):
    """在线程中执行同步调用，并按接口类型限制等待时间。"""
    return await asyncio.wait_for(
        asyncio.to_thread(func, *args, **kwargs), timeout=timeout
    )


async def create_qr(app: str = DEFAULT_APP) -> dict[str, Any]:
    from p115client import P115Client

    app = app if app in QR_APPS else DEFAULT_APP
    try:
        resp = await _run(P115Client.login_qrcode_token, app=app)
    except Exception as exc:
        raise Pan115Error(f"无法获取二维码：{exc}") from exc
    if not resp.get("state"):
        raise Pan115Error(resp.get("message") or "获取二维码失败")

    data = resp.get("data") or {}
    uid = str(data.get("uid") or "")
    if not uid:
        raise Pan115Error("获取二维码失败：缺少 uid")
    if not data.get("qrcode"):
        # 该端不支持手机扫码登录（电视/桌面/平板端走设备码授权）
        raise Pan115Error(
            f"{QR_APPS.get(app, app)} 不支持手机扫码登录，请换一个扫码端"
        )

    # 115 官方二维码实际内容为 yun.115.com/scan/dg-{uid}，
    # token 接口返回的 qrcode 字段仍是旧域名 115.com，手机 App 扫码会被判为过期
    url = f"https://yun.115.com/scan/dg-{uid}"
    session = {
        "uid": uid,
        "app": app,
        "time": data.get("time"),
        "sign": data.get("sign"),
        "url": url,
        "status": 0,
        "message": "等待扫码",
        "created": time.time(),
        "finished": False,
    }
    _sessions[uid] = session
    _prune_sessions()

    task = asyncio.create_task(_watch(session))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)

    return {
        "uid": uid,
        "app": app,
        "status": 0,
        "message": session["message"],
        "image": qr_image(url),
        "expires_in": QR_TIMEOUT,
    }


async def _watch(session: dict[str, Any]) -> None:
    from p115client import P115Client

    payload = {"uid": session["uid"], "time": session["time"], "sign": session["sign"]}
    while time.time() - session["created"] < QR_TIMEOUT:
        try:
            resp = await _run(
                P115Client.login_qrcode_scan_status,
                payload,
                timeout=LONG_POLL_TIMEOUT,
            )
        except Exception:
            await asyncio.sleep(1.0)
            continue

        status = (resp.get("data") or {}).get("status")
        if status == 1:
            session["status"] = 1
            session["message"] = "已扫码，请在手机上确认"
        elif status == 2:
            session["status"] = 2
            session["message"] = "已确认，正在保存授权…"
            await _finish_qr(session)
            return
        elif status in (-1, -2):
            session["status"] = status
            session["message"] = "二维码已过期" if status == -1 else "已取消扫码"
            session["finished"] = True
            return

    session["status"] = -1
    session["message"] = "二维码已过期"
    session["finished"] = True


async def _finish_qr(session: dict[str, Any]) -> None:
    from p115client import P115Client

    try:
        app = session.get("app") or DEFAULT_APP
        resp = await _run(
            P115Client.login_qrcode_scan_result,
            session["uid"],
            app=app,
            timeout=LONG_POLL_TIMEOUT,
        )
        cookie = (resp.get("data") or {}).get("cookie")
        if not cookie:
            raise Pan115Error(resp.get("message") or "未获取到 Cookie")

        cookies = {str(k): str(v) for k, v in cookie.items()}
        now = int(time.time())
        try:
            probe = await _run(_probe, cookies, timeout=LONG_POLL_TIMEOUT)
        except Exception:
            probe = {
                "username": "",
                "user_id": None,
                "avatar": "",
                "vip_active": False,
                "vip_forever": False,
                "vip_expire": "",
                "total": None,
                "used": None,
            }

        _write_auth(
            {
                "cookies": cookies,
                "app": app,
                "bound_at": now,
                "username": probe["username"],
                "total": probe["total"],
                "used": probe["used"],
                "last_check": now if probe["username"] or probe["total"] else 0,
                "last_status": "ok" if probe["username"] or probe["total"] else "pending",
                "last_message": "",
                **_account(probe),
            }
        )
        _cache.update({"at": 0.0, "data": None})
        session["message"] = "绑定成功"
    except Exception as exc:
        session["status"] = -3
        session["message"] = f"登录成功但保存失败：{exc}"
    finally:
        session["finished"] = True


def qr_status(uid: str) -> dict[str, Any]:
    session = _sessions.get(uid)
    if not session:
        return {"ok": False, "status": -4, "message": "二维码已失效，请重新生成", "bound": is_bound()}
    return {
        "ok": True,
        "status": session["status"],
        "message": session["message"],
        "bound": session["status"] == 2 and is_bound(),
    }


def fmt_size(value: Any) -> str:
    if not value:
        return "—"
    size = float(value)
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    index = 0
    while size >= 1024 and index < len(units) - 1:
        size /= 1024
        index += 1
    return f"{size:.1f} {units[index]}" if size < 10 else f"{size:.0f} {units[index]}"


# ---------------------------------------------------------------------------
# 文件浏览与播放直链（供 App 使用，Cookie 不出服务端）
# ---------------------------------------------------------------------------

def _bound_client() -> tuple[dict[str, str], Any]:
    auth = _read_auth()
    if not auth:
        raise Pan115Error("尚未绑定 115 网盘，请先在服务端管理台绑定")
    return auth, _client(auth["cookies"])


def _list_item(raw: dict[str, Any]) -> dict[str, Any]:
    # 115 /files 返回中，目录带 cid 无 fid；文件带 fid 与 pc（pickcode）。
    is_dir = not raw.get("fid")
    return {
        "id": str(raw.get("cid") if is_dir else raw.get("fid") or ""),
        "name": str(raw.get("n") or ""),
        "is_dir": bool(is_dir),
        "size": _num(raw.get("s")) or 0,
        "pickcode": str(raw.get("pc") or ""),
        "sha1": str(raw.get("sha") or ""),
        "updated_at": _num(raw.get("te")) or _num(raw.get("tp")) or 0,
    }


def list_files(cid: str = "0", offset: int = 0, limit: int = 200) -> dict[str, Any]:
    """列目录：目录在前，按更新时间倒序，与 115 网页端一致。"""
    _, client = _bound_client()
    try:
        resp = client.fs_files(
            {
                "cid": cid or "0",
                "offset": offset,
                "limit": limit,
                "show_dir": 1,
                "o": "user_ptime",
                "asc": 0,
            },
            timeout=REQ_TIMEOUT,
        )
    except Exception as exc:
        raise Pan115Error(f"无法连接 115：{exc}") from exc

    if not resp.get("state"):
        if _auth_expired(resp):
            raise Pan115Error("115 登录已过期，请重新绑定")
        raise Pan115Error(resp.get("message") or "获取文件列表失败")

    raw_items = resp.get("data")
    if not isinstance(raw_items, list):
        raw_items = []
    items = [_list_item(raw) for raw in raw_items if isinstance(raw, dict)]
    items = [item for item in items if item["name"]]

    total = _num(resp.get("count")) or (offset + len(items))
    return {"cid": str(cid or "0"), "offset": offset, "total": total, "items": items}


def create_folder(cid: str = "0", name: str = "") -> dict[str, Any]:
    """在当前目录新建文件夹。"""
    from p115client import check_response

    folder = (name or "").strip()
    if not folder:
        raise Pan115Error("请输入文件夹名称")
    if len(folder) > 255:
        raise Pan115Error("文件夹名称不能超过 255 个字符")
    if any(char in folder for char in '<>"'):
        raise Pan115Error('文件夹名称不能包含 < > " 字符')

    _, client = _bound_client()
    try:
        resp = client.fs_mkdir(
            {"pid": int(cid or 0), "cname": folder},
            timeout=REQ_TIMEOUT,
        )
        check_response(resp)
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"新建文件夹失败：{exc}") from exc

    data = resp.get("data") if isinstance(resp, dict) else None
    new_cid = ""
    if isinstance(data, dict):
        new_cid = str(data.get("cid") or data.get("file_id") or "")
    return {"ok": True, "cid": new_cid}


def upload_file(path: str, cid: str = "0", filename: str = "") -> dict[str, Any]:
    """把服务端临时文件上传到网盘指定目录。"""
    from p115client import check_response

    name = (filename or os.path.basename(path) or "").strip()
    if not name:
        raise Pan115Error("文件名不能为空")
    if not os.path.isfile(path):
        raise Pan115Error("待上传文件不存在")

    _, client = _bound_client()
    try:
        resp = client.upload_file(
            path,
            pid=int(cid or 0),
            filename=name,
            partsize=-1,
            timeout=600,
        )
        check_response(resp)
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"上传失败：{exc}") from exc
    return {"ok": True}


def delete_items(ids: list[str]) -> dict[str, Any]:
    """把选中的文件 / 文件夹移入 115 回收站。"""
    from p115client import check_response

    file_ids = [str(item).strip() for item in ids if str(item).strip()]
    if not file_ids:
        raise Pan115Error("请先选择要删除的项目")

    _, client = _bound_client()
    try:
        resp = client.fs_delete(file_ids, timeout=REQ_TIMEOUT)
        check_response(resp)
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"删除失败：{exc}") from exc
    return {"ok": True, "count": len(file_ids)}


def rename_item(fid: str, name: str) -> dict[str, Any]:
    """重命名单个文件 / 文件夹。115 要求必须带上扩展名，否则会截断后缀。"""
    from p115client import check_response

    file_id = str(fid).strip()
    new_name = str(name).strip()
    if not file_id:
        raise Pan115Error("缺少要重命名的项目")
    if not new_name:
        raise Pan115Error("名称不能为空")
    if "/" in new_name or "\\" in new_name:
        raise Pan115Error("名称不能包含斜杠")

    _, client = _bound_client()
    try:
        resp = client.fs_rename((file_id, new_name), timeout=REQ_TIMEOUT)
        check_response(resp)
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"重命名失败：{exc}") from exc
    return {"ok": True, "id": file_id, "name": new_name}


def rename_items(pairs: list[tuple[str, str]]) -> dict[str, Any]:
    """批量重命名：一次请求提交多组「id → 新名称」。"""
    from p115client import check_response

    payload: list[tuple[str, str]] = []
    for fid, name in pairs:
        file_id = str(fid).strip()
        new_name = str(name).strip()
        if not file_id or not new_name:
            continue
        if "/" in new_name or "\\" in new_name:
            raise Pan115Error("名称不能包含斜杠")
        payload.append((file_id, new_name))

    if not payload:
        raise Pan115Error("没有要重命名的项目")

    _, client = _bound_client()
    try:
        resp = client.fs_rename(payload, timeout=REQ_TIMEOUT)
        check_response(resp)
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"重命名失败：{exc}") from exc
    return {"ok": True, "count": len(payload)}


def _transfer_items(
    ids: list[str],
    cid: str,
    *,
    action: str,
    method: str,
) -> dict[str, Any]:
    """批量移动 / 复用的公共实现，`method` 对应 p115client 的方法名。"""
    from p115client import check_response

    file_ids = [str(item).strip() for item in ids if str(item).strip()]
    if not file_ids:
        raise Pan115Error(f"请先选择要{action}的项目")

    _, client = _bound_client()
    try:
        resp = getattr(client, method)(
            file_ids,
            pid=int(str(cid or "0").strip() or 0),
            timeout=REQ_TIMEOUT,
        )
        check_response(resp)
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"{action}失败：{exc}") from exc
    return {"ok": True, "count": len(file_ids)}


def move_items(ids: list[str], cid: str = "0") -> dict[str, Any]:
    """把选中的文件 / 文件夹移动到指定目录。"""
    return _transfer_items(ids, cid, action="移动", method="fs_move")


def copy_items(ids: list[str], cid: str = "0") -> dict[str, Any]:
    """把选中的文件 / 文件夹复制到指定目录。"""
    return _transfer_items(ids, cid, action="复制", method="fs_copy")


def _expires_in(url: str) -> int:
    """115 直链的 t 参数是过期时间戳，返回剩余秒数。"""
    try:
        params = parse_qs(urlparse(url).query)
        expiry = int(params.get("t", ["0"])[0])
    except (TypeError, ValueError):
        return 0
    return max(0, expiry - int(time.time()))


# ---------------------------------------------------------------------------
# 云下载（离线下载）：任务列表、添加、重试、删除
# ---------------------------------------------------------------------------

_CLOUD_TASK_TTL = 10
_cloud_task_cache: dict[tuple[int, int, int], tuple[float, dict[str, Any]]] = {}


def _invalidate_cloud_cache() -> None:
    _cloud_task_cache.clear()


def _cloud_listing(cookies: dict[str, str], payload: dict[str, int]) -> dict[str, Any]:
    from p115client import check_response

    listing = _client(cookies).clouddownload_task_list(payload)
    check_response(listing)
    return listing


def _cloud_counts(cookies: dict[str, str]) -> dict[str, Any]:
    from p115client import check_response

    counts = _client(cookies).clouddownload_task_count()
    check_response(counts)
    return counts


def cloud_tasks(stat: int = 0, page: int = 1, page_size: int = 30) -> dict[str, Any]:
    """云下载任务列表。stat: 0 全部 / 9 失败 / 11 已完成 / 12 进行中。

    任务列表与计数并发请求 115（各占一次往返），结果缓存 10 秒：
    切换 Tab、回到页面时直接命中缓存，不再重复等待。
    """
    key = (stat, max(1, page), min(max(1, page_size), 200))
    hit = _cloud_task_cache.get(key)
    if hit and time.time() - hit[0] < _CLOUD_TASK_TTL:
        return hit[1]

    auth = _read_auth()
    if not auth:
        raise Pan115Error("尚未绑定 115 网盘，请先在服务端管理台绑定")

    cookies = auth["cookies"]
    payload = {"page": key[1], "page_size": key[2], "stat": key[0]}
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            listing_future = pool.submit(_cloud_listing, cookies, payload)
            counts_future = pool.submit(_cloud_counts, cookies)
            listing = listing_future.result()
            counts = counts_future.result()
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"读取云下载任务失败：{exc}") from exc

    tasks = [
        {
            "info_hash": task.get("info_hash") or "",
            "name": task.get("name") or "未命名任务",
            "size": _num(task.get("size")) or 0,
            "add_time": _num(task.get("add_time")) or 0,
            "status": task.get("display_status") or "",
            "status_text": task.get("status_text") or "",
            "percent": _num(task.get("display_percent")) or 0,
            "url": task.get("url") or "",
            "actions": task.get("available_actions") or [],
        }
        for task in listing.get("tasks") or []
        if task.get("info_hash")
    ]

    result = {
        "counts": {
            "total": _num(counts.get("total_count")) or 0,
            "downloading": _num(counts.get("downloading_count")) or 0,
            "failed": _num(counts.get("failed_count")) or 0,
            "finished": _num(counts.get("finished_count")) or 0,
        },
        "quota": {
            "remaining": _num(listing.get("quota")) or 0,
            "total": _num(listing.get("total")) or 0,
        },
        "page": _num(listing.get("page")) or 1,
        "page_count": _num(listing.get("page_count")) or 1,
        "tasks": tasks,
    }
    _cloud_task_cache[key] = (time.time(), result)
    return result


def cloud_add(urls: list[str], cid: str = "0") -> dict[str, Any]:
    """添加云下载任务，支持 HTTP / HTTPS / FTP / 磁力 / 电驴链接。"""
    from p115client import check_response

    cleaned = [url.strip() for url in urls if url.strip()]
    if not cleaned:
        raise Pan115Error("请填写下载链接")

    _, client = _bound_client()
    payload: dict[str, Any] = {f"url[{i}]": url for i, url in enumerate(cleaned)}
    payload["wp_path_id"] = int(cid or 0)

    try:
        resp = client.clouddownload_task_add_urls(payload)
        check_response(resp)
    except Exception as exc:
        raise Pan115Error(f"添加云下载失败：{exc}") from exc
    _invalidate_cloud_cache()
    return {"count": len(cleaned)}


def cloud_retry(info_hash: str) -> dict[str, Any]:
    from p115client import check_response

    if not info_hash.strip():
        raise Pan115Error("任务已失效，请刷新后重试")

    _, client = _bound_client()
    try:
        resp = client.clouddownload_task_restart({"info_hash": info_hash.strip()})
        check_response(resp)
    except Exception as exc:
        raise Pan115Error(f"重试失败：{exc}") from exc
    _invalidate_cloud_cache()
    return {"ok": True}


def cloud_delete(info_hash: str) -> dict[str, Any]:
    from p115client import check_response

    if not info_hash.strip():
        raise Pan115Error("任务已失效，请刷新后重试")

    _, client = _bound_client()
    try:
        resp = client.clouddownload_task_del({"hash[0]": info_hash.strip()})
        check_response(resp)
    except Exception as exc:
        raise Pan115Error(f"删除失败：{exc}") from exc
    _invalidate_cloud_cache()
    return {"ok": True}


def play_url(pickcode: str) -> dict[str, Any]:
    """只解析直链，不代理字节流：客户端拿到 URL 后直连 115 CDN。"""
    _, client = _bound_client()
    ua = _ios_user_agent()
    try:
        url = client.download_url(pickcode, user_agent=ua, app="web", timeout=REQ_TIMEOUT)
    except Exception as exc:
        raise Pan115Error(f"获取播放直链失败：{exc}") from exc

    link = str(url)
    if not link.startswith("http"):
        raise Pan115Error("获取播放直链失败，请重试")

    headers = {
        str(key): str(value)
        for key, value in (getattr(url, "headers", None) or {}).items()
    }
    if not any(key.lower() == "user-agent" for key in headers):
        headers["User-Agent"] = ua
    return {"url": link, "headers": headers, "expires_in": _expires_in(link)}


# ---------------------------------------------------------------------------
# 图片缩略图：服务端代取字节，Cookie 不出服务端
# ---------------------------------------------------------------------------

_THUMB_LIMIT = 512
_THUMB_MAX_BYTES = 8 * 1024 * 1024
_thumbs: OrderedDict[str, tuple[bytes, str]] = OrderedDict()


def _remember_thumb(key: str, value: tuple[bytes, str]) -> None:
    """按最近使用淘汰，避免缩略图无限占用内存。"""
    _thumbs[key] = value
    _thumbs.move_to_end(key)
    while len(_thumbs) > _THUMB_LIMIT:
        _thumbs.popitem(last=False)


def _fetch_thumb(url: str, cookies: dict[str, str]) -> tuple[bytes, str]:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": _ios_user_agent(),
            "Referer": "https://115.com/",
            "Accept": "image/avif,image/webp,image/png,image/jpeg,*/*",
            "Cookie": "; ".join(f"{key}={value}" for key, value in cookies.items()),
        },
    )
    with urllib.request.urlopen(request, timeout=REQ_TIMEOUT) as resp:
        data = resp.read(_THUMB_MAX_BYTES + 1)
        content_type = (
            (resp.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        )
    if len(data) > _THUMB_MAX_BYTES:
        raise Pan115Error("缩略图体积过大")
    if not content_type.startswith("image/"):
        raise Pan115Error("115 未返回图片数据")
    return data, content_type


def thumbnail(sha1: str) -> tuple[bytes, str]:
    """按文件 sha1 取图片缩略图，命中缓存时直接返回。"""
    key = (sha1 or "").strip()
    if not key or len(key) > 64:
        raise Pan115Error("缺少缩略图标识")

    hit = _thumbs.get(key)
    if hit:
        _thumbs.move_to_end(key)
        return hit

    auth, client = _bound_client()
    try:
        from p115client.tool.download import get_pic_url

        link = str(get_pic_url(client, key, timeout=REQ_TIMEOUT))
        if not link.startswith("http"):
            raise Pan115Error("获取缩略图地址失败")
        result = _fetch_thumb(link, auth["cookies"])
    except Pan115Error:
        raise
    except Exception as exc:
        raise Pan115Error(f"获取缩略图失败：{exc}") from exc

    _remember_thumb(key, result)
    return result
