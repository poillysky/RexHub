"""outbound_http 子模块：对外拉页入口 fetch_page（curl → clearance → Flare 阶梯）。"""

import re
import threading
import time
from dataclasses import dataclass
from typing import Any

import httpx

from . import flare
from .classify import extract_safeid, is_r18_safe_shell, looks_blocked_html, normalize_access
from .clearance import get_cached_clearance, mark_prefer_flare
from .flare import flaresolverr_request_full
from .proxy import resolve_flaresolverr_url, resolve_proxy_url
from .shared import (
    _cached_soft_cookies,
    _host_key,
    _remember_soft_cookies,
    _sehuatang_like_host,
    log,
    merge_cookie_headers,
)
from .slots import _page_slot
from .tls import thread_allow_flare, thread_is_cancelled, thread_request_timeout

_DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)
# curl-impersonate（curl_cffi）浏览器指纹；站点拉页优先
_CURL_IMPERSONATE = "chrome"

_JAVBUS_HOST_RE = re.compile(r"(?:^|\.)(?:javbus|seejav)\b", re.I)

# 对齐 MDCS flaresolverr NEVER_REGISTER_FLARE_RE：稳定 curl/代理源，勿吸入过盾通道
_NEVER_FLARE_HOST_RE = re.compile(
    r"(?:^|\.)("
    r"madouqu|madou\.club|theporndb|javbus|seejav|caribbeancom|10musume|"
    r"jav321|freejavbt|libredmm|contents\.fc2|dmm\.co\.jp|xchina|iqq[0-9]"
    r")\b",
    re.I,
)

# 最近一次 curl/httpx 未采纳原因（供错误文案；按 host）
_last_http_miss: dict[str, dict[str, Any]] = {}
_last_http_miss_lock = threading.Lock()


def _note_http_miss(url: str, *, status: int | None = None, reason: str = "") -> None:
    host = _host_key(url)
    if not host:
        return
    with _last_http_miss_lock:
        _last_http_miss[host] = {
            "status": status,
            "reason": reason,
            "at": time.time(),
        }


def _take_http_miss(url: str) -> dict[str, Any] | None:
    host = _host_key(url)
    if not host:
        return None
    with _last_http_miss_lock:
        return _last_http_miss.pop(host, None)


def _ensure_safe_gate_cookies(url: str, cookie_header: str | None) -> str:
    """色花堂类主机默认带 safe=1，并合并进程内 _safe。"""
    merged = merge_cookie_headers(cookie_header, _cached_soft_cookies(url))
    host = _host_key(url)
    if _sehuatang_like_host(host):
        lower = f"; {merged.lower()}; "
        if "safe=" not in lower:
            merged = merge_cookie_headers(merged, "safe=1")
    return merged


def _javbus_like_host(host: str) -> bool:
    """JavBus 走 curl/代理即可，禁止 FlareSolverr 过盾。"""
    h = (host or "").lower().lstrip(".")
    return bool(_JAVBUS_HOST_RE.search(h))


def _skip_flare_host(host: str) -> bool:
    """这些站 curl（+ 站点 Cookie）即可，勿进 Flare 队列（对齐 MDCS）。"""
    h = (host or "").lower().lstrip(".")
    return (
        _sehuatang_like_host(host)
        or _javbus_like_host(host)
        or bool(_NEVER_FLARE_HOST_RE.search(h))
    )


@dataclass
class FetchPageResult:
    html: str
    final_url: str
    via: str = "curl"  # curl | flare | httpx


def _timeout_seconds(timeout: httpx.Timeout | float | None, default: float = 22.0) -> float:
    if timeout is None:
        return default
    if isinstance(timeout, httpx.Timeout):
        return float(getattr(timeout, "read", None) or getattr(timeout, "timeout", None) or default)
    return float(timeout)


def decode_html_bytes(raw: bytes, *, content_type: str = "") -> str:
    """按 meta/HTTP charset 解码 HTML；caribbeancompr 等站为 euc-jp，勿默认 utf-8。"""
    data = raw or b""
    if not data:
        return ""
    ctype = str(content_type or "").lower()
    candidates: list[str] = []

    def _add(enc: str) -> None:
        e = str(enc or "").strip().lower().replace('"', "")
        if not e:
            return
        # 别名归一
        if e in {"shift_jis", "shift-jis", "sjis", "x-sjis"}:
            e = "cp932"
        if e in {"euc_jp", "euc-jp", "x-euc-jp"}:
            e = "euc_jp"
        if e not in candidates:
            candidates.append(e)

    m = re.search(rb"charset\s*=\s*['\"]?\s*([a-zA-Z0-9_\-]+)", data[:4096], re.I)
    if m:
        _add(m.group(1).decode("ascii", errors="ignore"))
    m2 = re.search(r"charset\s*=\s*([\w\-]+)", ctype, re.I)
    if m2:
        _add(m2.group(1))
    for enc in ("utf-8", "euc_jp", "cp932", "latin-1"):
        _add(enc)

    for enc in candidates:
        try:
            text = data.decode(enc)
        except (LookupError, UnicodeDecodeError):
            continue
        # utf-8 误解 euc-jp 时替换符很多；优先无 � 的解码
        if enc == "utf-8" and "\ufffd" in text[:8000] and len(data) > 2000:
            continue
        return text
    return data.decode("utf-8", errors="replace")


def _accept_http_body(
    url: str,
    *,
    status: int,
    html: str,
    final_url: str,
    via: str,
) -> tuple[str, str, str] | None:
    """对齐 MDCS：≥400 默认丢弃；但 404 站点模板页交给上层解析「未找到」。"""
    if looks_blocked_html(html):
        _note_http_miss(url, status=status, reason="blocked")
        return None
    if status >= 400:
        # 软 404：完整站点 404 页（如 JavBus），供 parse 报「未找到影片」
        if status == 404 and len(html) >= 400:
            return html, final_url, via
        _note_http_miss(url, status=status, reason="http_error")
        return None
    if len(html) < 200:
        _note_http_miss(url, status=status, reason="thin")
        return None
    return html, final_url, via


def _http_get_once(
    url: str,
    *,
    headers: dict[str, str],
    timeout: httpx.Timeout,
    proxy: str | None,
    verify: bool,
) -> tuple[str, str, str] | None:
    """优先 curl-impersonate；不可用时回退 httpx。返回 (html, final_url, via)。"""
    try:
        from curl_cffi import requests as creq

        kwargs: dict[str, Any] = {
            "headers": headers,
            "timeout": _timeout_seconds(timeout),
            "allow_redirects": True,
            "verify": verify,
            "impersonate": _CURL_IMPERSONATE,
        }
        if proxy:
            kwargs["proxy"] = proxy
        r = creq.get(url, **kwargs)
        status = int(getattr(r, "status_code", 500) or 500)
        raw = getattr(r, "content", None) or b""
        ctype = ""
        try:
            ctype = str((getattr(r, "headers", None) or {}).get("content-type") or "")
        except Exception:
            ctype = ""
        html = decode_html_bytes(raw, content_type=ctype) if raw else str(
            getattr(r, "text", "") or ""
        )
        final = str(getattr(r, "url", "") or url)
        hit = _accept_http_body(
            url, status=status, html=html, final_url=final, via="curl"
        )
        if hit:
            return hit
    except Exception as e:
        log.debug("curl-impersonate miss %s: %s", _host_key(url), e)

    opts: dict[str, Any] = {
        "timeout": timeout,
        "trust_env": False,
        "follow_redirects": True,
        "verify": verify,
    }
    if proxy:
        opts["proxy"] = proxy
    try:
        with httpx.Client(**opts) as client:
            r2 = client.get(url, headers=headers)
        status = int(r2.status_code or 500)
        html = decode_html_bytes(r2.content or b"", content_type=str(r2.headers.get("content-type") or ""))
        hit = _accept_http_body(
            url,
            status=status,
            html=html,
            final_url=str(r2.url or url),
            via="httpx",
        )
        if hit:
            return hit
    except Exception:
        _note_http_miss(url, reason="exception")
    return None


def fetch_page(
    url: str,
    *,
    referer: str | None = None,
    cookie: str | None = None,
    user_agent: str | None = None,
    access: str | None = None,
    timeout: httpx.Timeout | float | None = None,
    fresh_probe: bool = False,
    source_id: str | None = None,
) -> FetchPageResult:
    """
    对齐 MDCS fetchPage 阶梯：
    clearance + curl-impersonate →（adaptive 短探）→ FlareSolverr。

    同站闸只罩直连/curl；过盾在闸外跑，避免 FS 单飞时占满 host slot 拖死整批。
    """
    return _fetch_page_unlocked(
        url,
        referer=referer,
        cookie=cookie,
        user_agent=user_agent,
        access=access,
        timeout=timeout,
        fresh_probe=fresh_probe,
        source_id=source_id,
    )


def _fetch_page_unlocked(
    url: str,
    *,
    referer: str | None = None,
    cookie: str | None = None,
    user_agent: str | None = None,
    access: str | None = None,
    timeout: httpx.Timeout | float | None = None,
    fresh_probe: bool = False,
    source_id: str | None = None,
) -> FetchPageResult:
    del source_id  # 预留：按源覆盖 access
    host = _host_key(url)
    mode = normalize_access(access)
    # 策略单源超时优先于调用方传入的默认 12/28s
    tls_to = thread_request_timeout()
    if tls_to is not None:
        timeout = float(tls_to)
    if isinstance(timeout, httpx.Timeout):
        to = timeout
    elif timeout is not None:
        to = httpx.Timeout(float(timeout), connect=min(8.0, float(timeout)))
    else:
        to = httpx.Timeout(22.0, connect=8.0)

    flare_url = resolve_flaresolverr_url()
    flare_on = bool(flare_url)
    cached = None if fresh_probe else get_cached_clearance(url)
    merged_cookie = _ensure_safe_gate_cookies(
        url,
        merge_cookie_headers(cookie, (cached or {}).get("cookieHeader")),
    )
    ua = (
        str(user_agent or "").strip()
        or (cached or {}).get("userAgent")
        or _DEFAULT_UA
    )
    has_clearance = bool((cached or {}).get("cookieHeader"))
    prefer_flare = bool((cached or {}).get("preferFlare"))

    headers: dict[str, str] = {
        "User-Agent": ua,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8,ja;q=0.7",
    }
    if referer:
        headers["Referer"] = referer
    if merged_cookie:
        headers["Cookie"] = merged_cookie

    proxy = resolve_proxy_url()
    # 对齐 MDCS download.fetchPage：
    # - 全源优先 impersonate curl（含 proxy_flare），失败再 Flare
    # - 勿因 proxy_flare / preferFlare 跳过 curl（否则「全部走 Flare」）
    # - NEVER_FLARE / proxy_only：禁过盾
    skip_direct = False
    no_flare = (
        mode == "proxy_only"
        or _skip_flare_host(host)
        or not thread_allow_flare()
    )
    if no_flare:
        prefer_flare = False
        flare_on = False

    def _apply_r18_bypass(html: str) -> bool:
        """命中名言壳则写 _safe，刷新 Cookie 头；成功返回 True。"""
        nonlocal merged_cookie
        if not is_r18_safe_shell(html):
            return False
        safeid = extract_safeid(html)
        if not safeid:
            return False
        soft = f"safe=1; _safe={safeid}"
        _remember_soft_cookies(url, soft)
        merged_cookie = merge_cookie_headers(merged_cookie, soft)
        headers["Cookie"] = merged_cookie
        log.info("r18-safeid host=%s → _safe set", _host_key(url))
        return True

    def _accept_or_bypass_r18(
        html: str, final_url: str, via: str, *, opts: dict[str, Any], direct_to: httpx.Timeout
    ) -> FetchPageResult | None:
        if not is_r18_safe_shell(html):
            return FetchPageResult(html=html, final_url=final_url, via=via)
        if not _apply_r18_bypass(html):
            return None
        hit2 = _http_get_once(
            url,
            headers=headers,
            timeout=direct_to,
            proxy=opts.get("proxy"),
            verify=bool(opts.get("verify")),
        )
        if not hit2:
            return None
        html2, final2, via2 = hit2
        if is_r18_safe_shell(html2):
            return None
        return FetchPageResult(html=html2, final_url=final2, via=via2)

    last_err: Exception | None = None
    if not skip_direct:
        attempts: list[dict[str, Any]] = []
        if proxy:
            attempts.append({"proxy": proxy, "verify": False})
            attempts.append({"proxy": proxy, "verify": True})
        attempts.append({"proxy": None, "verify": False})
        attempts.append({"proxy": None, "verify": True})
        seen: set[str] = set()
        # 同站闸只包直连；成功即返回，失败后释放再进过盾
        with _page_slot(url, timeout=90.0):
            last_miss: dict[str, Any] | None = None
            for opts in attempts:
                # 该源已被上层放弃（早停/暂停）：别再试剩余组合，白占 page 槽
                if thread_is_cancelled():
                    last_err = RuntimeError("已放弃(早停)")
                    break
                key = repr(sorted(opts.items()))
                if key in seen:
                    continue
                seen.add(key)
                # 对齐 MDCS curlOpts；有策略单源超时时不再强制抬到 ≥15s
                base_read = float(getattr(to, "read", 22) or 22)
                if tls_to is not None:
                    read_s = max(3.0, min(base_read, float(tls_to)))
                    # 连接更快失败，避免死站把预算耗在 connect 上
                    direct_to = httpx.Timeout(
                        read_s, connect=min(4.0, read_s)
                    )
                elif has_clearance:
                    direct_to = httpx.Timeout(max(12.0, base_read), connect=8.0)
                else:
                    direct_to = httpx.Timeout(max(15.0, base_read), connect=8.0)
                hit = _http_get_once(
                    url,
                    headers=headers,
                    timeout=direct_to,
                    proxy=opts.get("proxy"),
                    verify=bool(opts.get("verify")),
                )
                if hit:
                    html, final_url, via = hit
                    accepted = _accept_or_bypass_r18(
                        html, final_url, via, opts=opts, direct_to=direct_to
                    )
                    if accepted:
                        if has_clearance:
                            mark_prefer_flare(url, False)
                            log.info(
                                "clearance-curl-ok host=%s %sb via=%s",
                                _host_key(url),
                                len(accepted.html),
                                accepted.via,
                            )
                        else:
                            log.info(
                                "curl-ok host=%s %sb via=%s",
                                _host_key(url),
                                len(accepted.html),
                                accepted.via,
                            )
                        if no_flare:
                            mark_prefer_flare(url, False)
                        return accepted
                miss_now = _take_http_miss(url)
                if miss_now:
                    last_miss = miss_now
                st_now = int((last_miss or {}).get("status") or 0)
                # 硬错误立刻停重试（对齐 mdc-ng：未找到/拒绝秒级返回）
                if st_now in {401, 403, 404} or (500 <= st_now < 600):
                    break
            miss = last_miss
            st = int((miss or {}).get("status") or 0)
            if st in {429, 503}:
                try:
                    from app.core.outbound_scheduler import get_scheduler

                    get_scheduler().note_status(url, st)
                except Exception:  # noqa: BLE001
                    pass
            if st == 404:
                last_err = RuntimeError("未找到影片 (HTTP 404)")
            elif st in (401, 403):
                last_err = RuntimeError(f"拒绝访问 (HTTP {st})")
            elif st >= 500:
                last_err = RuntimeError(f"站点错误 (HTTP {st})")
            elif (miss or {}).get("reason") == "blocked":
                last_err = RuntimeError("curl/直连遇盾")
            else:
                last_err = RuntimeError("curl/直连失败或遇盾")
            if (
                has_clearance
                and not no_flare
                and (miss or {}).get("reason") == "blocked"
            ):
                mark_prefer_flare(url, True)
                log.info(
                    "clearance-curl-miss host=%s → preferFlare",
                    _host_key(url),
                )

    # HTTP 404/403/401：直接失败，禁止回落 Flare
    if isinstance(last_err, RuntimeError) and (
        "HTTP 404" in str(last_err)
        or "HTTP 403" in str(last_err)
        or "HTTP 401" in str(last_err)
        or "拒绝访问" in str(last_err)
        or "未找到影片" in str(last_err)
    ):
        raise last_err

    if flare_on:
        # 自适应回落：过盾排队深时直接失败，让其它源/番号先走（proxy_flare 仍进盾）
        if mode != "proxy_flare" and flare._flare_queue_depth > 2:
            log.info(
                "curl-miss → skip flare (busy depth=%s) host=%s",
                flare._flare_queue_depth,
                _host_key(url),
            )
            raise last_err or RuntimeError("curl/直连失败 · 过盾繁忙跳过")
        log.info(
            "curl-miss → flare host=%s access=%s err=%s",
            _host_key(url),
            mode,
            str(last_err)[:80] if last_err else "",
        )
        try:
            read_s = float(_timeout_seconds(to, 22.0))
            if thread_request_timeout() is not None:
                # 以策略超时为准，不再抬到 35s/45s
                flare_timeout = max(3000, int(read_s * 1000))
            else:
                flare_timeout = int(
                    max(
                        35000 if fresh_probe else 45000,
                        read_s * 1000,
                    )
                )
            # 有磁盘 clearance 时一并注入，避免年龄门/二次挑战
            flare_cookie = merged_cookie or None
            result = flaresolverr_request_full(
                url,
                max_timeout_ms=flare_timeout,
                referer=referer,
                cookie=flare_cookie,
                no_session_retry=fresh_probe,
            )
            if is_r18_safe_shell(result.html) and _apply_r18_bypass(result.html):
                result = flaresolverr_request_full(
                    url,
                    max_timeout_ms=flare_timeout,
                    referer=referer,
                    cookie=merged_cookie or None,
                    no_session_retry=fresh_probe,
                )
            if is_r18_safe_shell(result.html):
                raise RuntimeError("flare 仍停在 R18 名言壳")
            # 刚过盾成功：默认下次仍可先试 curl；若本次因 preferFlare 跳过 curl，保持标记
            if prefer_flare or skip_direct:
                mark_prefer_flare(url, True)
            return FetchPageResult(
                html=result.html,
                final_url=result.final_url,
                via="flare",
            )
        except Exception as e:
            last_err = e
            log.warning("flare fallback %s: %s", url, e)

    raise last_err or RuntimeError(f"拉页失败 {url}")
