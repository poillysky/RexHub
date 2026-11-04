"""115 扫码登录 → Cookie（UID/CID/SEID/KID）。

同步自老后端 `reference/legacy-server/app/pan115.py`：
- 用 p115client 的 `login_qrcode_token` / `login_qrcode_scan_status` /
  `login_qrcode_scan_result`，各客户端 app 参数取自老后端 QR_APPS；
- 电视端 / 桌面端 / 平板端走设备码授权，token 接口不返回 qrcode，手机扫不到，
  因此只列支持手机扫码的客户端；
- 二维码内容统一用 `https://yun.115.com/scan/dg-{uid}`，token 接口返回的
  qrcode 字段仍是旧域名 115.com，手机 App 扫码会被判为过期。
"""


from typing import Any
from urllib.parse import urlencode

import httpx

from app.p115.client import UA, human_error, normalize_cookie
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

ALLOWED_APPS = frozenset(QR_APPS)

_STATUS_LABEL = {
    0: "等待扫码",
    1: "已扫码，请在手机上确认",
    2: "已确认",
    -1: "二维码已过期",
    -2: "已取消扫码",
}


def qr_apps() -> list[dict[str, str]]:
    """可选扫码端列表（供设置页下拉选择）。"""
    return [{"key": key, "label": label} for key, label in QR_APPS.items()]


def normalize_app(app: str | None) -> str:
    device = (app or DEFAULT_APP).strip().lower()
    return device if device in ALLOWED_APPS else DEFAULT_APP


def qr_image(text: str) -> str | None:
    """把扫码链接画成 SVG data URL（未安装 segno 时返回 None，由前端自渲染）。"""
    try:
        import segno
    except ImportError:
        return None
    try:
        return segno.make(text, error="m").svg_data_uri(
            scale=4, border=0, dark="#0F172A", light="#FFFFFF"
        )
    except Exception:
        return None


def _client() -> httpx.Client:
    return httpx.Client(
        timeout=15.0,
        follow_redirects=True,
        trust_env=False,
        headers={
            "User-Agent": UA,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
        },
    )


def _p115_token(app: str) -> dict[str, Any]:
    from p115client import P115Client

    return P115Client.login_qrcode_token(app=app)


def start_qrlogin(app: str = DEFAULT_APP) -> dict[str, Any]:
    """生成扫码会话：uid/time/sign + 二维码图。"""
    device = normalize_app(app)
    try:
        token = _p115_token(device)
    except Exception as e:
        return {"ok": False, "message": f"无法获取二维码：{e}"}
    if not token.get("state"):
        return {"ok": False, "message": human_error(token, "获取二维码失败")}

    data = token.get("data") if isinstance(token.get("data"), dict) else {}
    uid = str(data.get("uid") or "").strip()
    if not uid:
        return {"ok": False, "message": "获取二维码失败：缺少 uid"}
    if not data.get("qrcode"):
        # 该端不支持手机扫码登录（电视/桌面/平板端走设备码授权）
        return {
            "ok": False,
            "message": f"{QR_APPS.get(device, device)} 不支持手机扫码登录，请换一个扫码端",
        }

    url = f"https://yun.115.com/scan/dg-{uid}"
    return {
        "ok": True,
        "uid": uid,
        "time": data.get("time"),
        "sign": str(data.get("sign") or "").strip(),
        "qrcode": url,
        "qrImage": qr_image(url),
        "app": device,
        "apps": qr_apps(),
        "message": "请使用 115 App 扫码",
    }


def poll_qrlogin_status(
    uid: str,
    time_: Any,
    sign: str,
) -> dict[str, Any]:
    """Poll scan status. status: 0 wait / 1 scanned / 2 done / -1 expired / -2 canceled."""
    uid = str(uid or "").strip()
    sign = str(sign or "").strip()
    if not uid or time_ is None or not sign:
        return {"ok": False, "message": "缺少扫码参数"}

    try:
        qs = urlencode({"uid": uid, "time": str(time_), "sign": sign})
        with _client() as client:
            res = client.get(f"https://qrcodeapi.115.com/get/status/?{qs}")
            data = res.json()
    except Exception as e:
        return {"ok": False, "message": str(e) or "查询扫码状态失败"}

    if not isinstance(data, dict):
        return {"ok": False, "message": "扫码状态响应异常"}

    inner = data.get("data") if isinstance(data.get("data"), dict) else {}
    try:
        status = int(inner.get("status")) if inner.get("status") is not None else None
    except (TypeError, ValueError):
        status = None

    if status is None and data.get("state") is False:
        return {
            "ok": False,
            "message": human_error(data, "查询扫码状态失败"),
        }

    label = _STATUS_LABEL.get(status if status is not None else 0, f"状态 {status}")
    return {
        "ok": True,
        "status": status,
        "statusLabel": label,
        "done": status == 2,
        "expired": status in (-1, -2),
        "message": label,
    }


def _scan_result(uid: str, app: str) -> dict[str, Any]:
    from p115client import P115Client

    return P115Client.login_qrcode_scan_result(uid, app=app)


def complete_qrlogin(uid: str, app: str = DEFAULT_APP) -> dict[str, Any]:
    """Exchange confirmed QR for cookie string."""
    uid = str(uid or "").strip()
    device = normalize_app(app)
    if not uid:
        return {"ok": False, "message": "缺少二维码 uid"}

    try:
        data = _scan_result(uid, device)
    except Exception as e:
        return {"ok": False, "message": str(e) or "扫码登录失败"}

    if not isinstance(data, dict):
        return {"ok": False, "message": "登录响应异常"}

    inner = data.get("data") if isinstance(data.get("data"), dict) else {}
    cookie_map = inner.get("cookie") if isinstance(inner.get("cookie"), dict) else None
    if not cookie_map:
        return {
            "ok": False,
            "message": human_error(data, "扫码登录未返回 Cookie"),
        }

    # Prefer stable order for readability
    parts: list[str] = []
    for key in ("UID", "CID", "SEID", "KID"):
        if key in cookie_map and cookie_map[key] is not None:
            parts.append(f"{key}={cookie_map[key]}")
    for key, val in cookie_map.items():
        up = str(key).upper()
        if up in ("UID", "CID", "SEID", "KID"):
            continue
        parts.append(f"{key}={val}")

    cookie = normalize_cookie("; ".join(parts))
    if not cookie:
        return {"ok": False, "message": "Cookie 为空"}

    return {
        "ok": True,
        "cookie": cookie,
        "app": device,
        "userId": inner.get("user_id") or cookie_map.get("UID"),
        "message": "扫码登录成功",
    }
