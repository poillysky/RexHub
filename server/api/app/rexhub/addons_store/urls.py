"""addon 地址工具：http(s) 校验与 transport / manifest 地址互转。"""

from urllib.parse import urlparse


def _http_url(value: str) -> str:
    target = (value or "").strip()
    parsed = urlparse(target)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("请填写 http(s) 开头的完整地址")
    return target


def normalize_transport(url: str) -> str:
    """把 manifest 地址归一到 transport 基址（去掉 /manifest.json）。"""
    target = _http_url(url).rstrip("/")
    if target.lower().endswith("/manifest.json"):
        target = target[: -len("/manifest.json")]
    return target.rstrip("/")


def manifest_url(transport: str) -> str:
    return f"{transport.rstrip('/')}/manifest.json"
