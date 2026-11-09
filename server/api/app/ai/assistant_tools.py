"""小花助手：检索工具适配层。"""


import asyncio
import json
import re
from typing import Any, Awaitable, Callable
from urllib.parse import urlparse

import httpx

from app.ai.assistant_protocol import make_card, merge_cards, select_ui_cards
from app.ai.config import resolve_web_search_config
from app.search.hit_label import display_hit_label

ToolHandler = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]


_WEB_META_LABELS = (
    "导演",
    "主演",
    "演员",
    "类型",
    "制片国家/地区",
    "制片国家",
    "地区",
    "上映日期",
    "片长",
    "年份",
    "评分",
    "评语",
)


def _web_host(url: str) -> str:
    try:
        host = (urlparse(url).hostname or "").strip().lower()
    except Exception:  # noqa: BLE001
        return ""
    if host.startswith("www."):
        host = host[4:]
    return host


def _format_web_meta(snippet: str) -> str:
    text = re.sub(r"\s+", " ", str(snippet or "")).strip()
    if not text:
        return ""
    # 结构化字段前加分隔，避免「导演主演类型」糊成一团
    for label in _WEB_META_LABELS:
        text = re.sub(
            rf"(?<![·\s])\s*({re.escape(label)})\s*[:：]",
            rf" · \1：",
            text,
        )
    text = re.sub(r"^(?:\s*·\s*)+", "", text)
    text = re.sub(r"(?:\s*·\s*){2,}", " · ", text)
    return text[:160].rstrip(" ·")


def tool_definitions(*, include_web: bool = True) -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = [
        {
            "type": "function",
            "function": {
                "name": "sehua_keyword",
                "description": "在色花资源仓库用关键词搜索（标题/文件名）。适合番号、女优、片名。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "搜索词"},
                        "region": {
                            "type": "string",
                            "description": "可选分区，如 japan_censored / 有码 / 无码",
                        },
                        "limit": {"type": "integer", "description": "条数 1-12，默认 6"},
                    },
                    "required": ["query"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "magnet_search",
                "description": "Bitmagnet 本地磁力库关键词搜索。适合电影/剧集种子、蓝光、infohash。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "limit": {"type": "integer"},
                    },
                    "required": ["query"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "media_search",
                "description": (
                    "影视元数据搜索（TMDB/豆瓣/Bangumi/AniList）。"
                    "适合查片名、确认作品；会尽量带回主演供下一步推导。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "source": {
                            "type": "string",
                            "enum": ["tmdb", "douban", "bangumi", "anilist"],
                            "description": "默认 tmdb",
                        },
                        "limit": {"type": "integer"},
                    },
                    "required": ["query"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "media_person_works",
                "description": (
                    "按影人 ID 列出参演/相关电影电视剧作品。"
                    "适合「某某演过哪些」「某片女主演的其他电影」等多跳查询的第二步。"
                    "影人 ID 从 media_search 返回的 facts.personIds 或详情 castPeople 获得。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "person_id": {
                            "type": "string",
                            "description": "影人 ID，形如 tmdb:person/123（必填，来源见 description）",
                        },
                        "name": {
                            "type": "string",
                            "description": "影人姓名，仅用于展示，取作品必须给 person_id",
                        },
                        "limit": {"type": "integer", "description": "条数 1-12，默认 8"},
                    },
                    "required": ["person_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "sehua_detail",
                "description": "按 info hash 查看色花仓库资源详情：标题、大小、电驴链接、文件列表。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "hash": {"type": "string", "description": "资源 info hash，来自 sehua_keyword 卡片"},
                    },
                    "required": ["hash"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "magnet_detail",
                "description": "按 info hash 查看 Bitmagnet 种子详情：文件列表、大小、磁力链接。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "hash": {"type": "string", "description": "种子 info hash，来自 magnet_search"},
                    },
                    "required": ["hash"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "media_detail",
                "description": (
                    "影视详情（TMDB/豆瓣等）：简介、评分、类型、片长、主演、IMDb ID。"
                    "media_id 形如 tmdb:movie/123，来自 media_search 结果。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "media_id": {"type": "string", "description": "影视 ID，形如 tmdb:movie/123"},
                    },
                    "required": ["media_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "av_search",
                "description": (
                    "AV 片库搜索（JavDB）：番号、片名、片商、演员、系列、片单、导演。"
                    "actor 类型用于先拿演员 id，再调 av_actor_works 列作品。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "type": {
                            "type": "string",
                            "enum": ["code", "movie", "actor", "maker", "series", "director", "list"],
                            "description": "默认 code；普通片名用 movie",
                        },
                        "limit": {"type": "integer", "description": "条数 1-12，默认 8"},
                    },
                    "required": ["query"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "av_movie",
                "description": "AV 影片详情与种子列表。movie_id 来自 av_search 的 facts.movieIds。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "movie_id": {"type": "string", "description": "影片 id（av_search 返回）"},
                        "limit": {"type": "integer", "description": "种子条数 1-12，默认 8"},
                    },
                    "required": ["movie_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "av_actor_works",
                "description": "按 AV 演员 id 列出参演影片，用于「某某女优有哪些作品」。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "actor_id": {"type": "string", "description": "演员 id，来自 av_search(type=actor)"},
                        "name": {"type": "string", "description": "演员姓名，仅用于展示"},
                        "limit": {"type": "integer", "description": "条数 1-12，默认 10"},
                    },
                    "required": ["actor_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "media_streams",
                "description": (
                    "按 IMDb ID 聚合在线播放源（电影/剧集）。imdbId 来自 media_detail。"
                    "剧集可给 season/episode。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "imdb_id": {"type": "string", "description": "形如 tt1234567"},
                        "media_type": {"type": "string", "enum": ["movie", "tv"], "description": "默认 movie"},
                        "season": {"type": "integer"},
                        "episode": {"type": "integer"},
                    },
                    "required": ["imdb_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "cloudsaver_search",
                "description": "网盘资源搜索（CloudSaver）：夸克/阿里/115 等分享链接与提取码。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "limit": {"type": "integer", "description": "条数 1-12，默认 6"},
                    },
                    "required": ["query"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "p115_save",
                "description": (
                    "把网盘分享链接或磁力/电驴链接转存/离线下载到 115。"
                    "仅在用户明确要求转存或下载时调用。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "urls": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "分享链接或磁力/ed2k 链接；单条也可直接传字符串",
                        },
                        "password": {"type": "string", "description": "分享提取码（若有）"},
                        "cid": {"type": "string", "description": "115 目标目录 id，默认 0（根目录）"},
                    },
                    "required": ["urls"],
                },
            },
        },
    ]
    if include_web:
        tools.append(
            {
                "type": "function",
                "function": {
                    "name": "web_search",
                    "description": "搜索公开网络（SearXNG / Serper / Brave）。查演员资料、片名确认、网上热门等。",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {"type": "string"},
                            "limit": {"type": "integer"},
                        },
                        "required": ["query"],
                    },
                },
            }
        )
    return tools


def filter_tools_by_prefer(
    tools: list[dict[str, Any]],
    prefer: list[str] | None,
) -> list[dict[str, Any]]:
    if not prefer:
        return tools
    allow = {str(s).strip().lower() for s in prefer if str(s).strip()}
    if not allow:
        return tools
    name_map = {
        "sehua": {"sehua_keyword", "sehua_detail"},
        "magnet": {"magnet_search", "magnet_detail"},
        "media": {"media_search", "media_detail", "media_person_works"},
        "av": {"av_search", "av_movie", "av_actor_works"},
        "stream": {"media_streams"},
        "cloud": {"cloudsaver_search", "p115_save"},
        "web": {"web_search"},
        "warehouse": {"sehua_keyword", "sehua_detail"},
    }
    names: set[str] = set()
    for p in allow:
        names |= name_map.get(p, set())
        if p in {
            "sehua_keyword",
            "sehua_detail",
            "magnet_search",
            "magnet_detail",
            "media_search",
            "media_detail",
            "media_person_works",
            "av_search",
            "av_movie",
            "av_actor_works",
            "media_streams",
            "cloudsaver_search",
            "p115_save",
            "web_search",
        }:
            names.add(p)
    if not names:
        return tools
    return [t for t in tools if str((t.get("function") or {}).get("name") or "") in names]


def filter_tools_by_enabled(
    tools: list[dict[str, Any]],
    enabled: list[str] | set[str] | None,
) -> list[dict[str, Any]]:
    if enabled is None:
        return tools
    allow = {str(x).strip() for x in enabled if str(x).strip()}
    if not allow:
        return []
    return [t for t in tools if str((t.get("function") or {}).get("name") or "") in allow]


def _limit(raw: Any, default: int = 6, hi: int = 12) -> int:
    try:
        n = int(raw)
    except (TypeError, ValueError):
        n = default
    return max(1, min(hi, n))


def _sehual_cards(resources: list[dict[str, Any]], *, limit: int) -> list[dict[str, Any]]:
    cards: list[dict[str, Any]] = []
    for item in resources[:limit]:
        h = str(item.get("hash") or item.get("info_hash") or "").strip()
        if not h:
            continue
        title = display_hit_label(
            title=item.get("title"),
            description=item.get("description"),
            filename=item.get("name") or item.get("filename"),
        )
        board = str(item.get("board_name") or "").strip()
        size = item.get("size")
        meta_parts = [board]
        if isinstance(size, (int, float)) and size > 0:
            meta_parts.append(_fmt_size(int(size)))
        cover = ""
        previews = item.get("preview_images") or item.get("images") or []
        if isinstance(previews, list) and previews:
            cover = str(previews[0] or "")
        score = item.get("score")
        cards.append(
            make_card(
                source="sehua",
                title=title,
                subtitle=_guess_code(title),
                meta=" · ".join(p for p in meta_parts if p),
                cover=cover,
                score=float(score) if isinstance(score, (int, float)) else None,
                key=h.lower(),
                open_payload={"kind": "sehua", "hash": h},
            )
        )
    return cards


def _fmt_size(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024**2:
        return f"{n / 1024:.1f} KB"
    if n < 1024**3:
        return f"{n / 1024**2:.1f} MB"
    return f"{n / 1024**3:.2f} GB"


_CODE_RE = re.compile(
    r"(?:^|[^A-Za-z0-9])((?:\d{2,3})?[A-Za-z]{2,15}[-_\s]?\d{2,8}|FC2[-_\s]?PPV[-_\s]?\d{5,10})",
    re.I,
)


def _guess_code(text: str) -> str:
    m = _CODE_RE.search(text or "")
    if not m:
        return ""
    raw = re.sub(r"[\s_]+", "-", m.group(1).upper())
    return raw[:24]


async def run_sehua_keyword(args: dict[str, Any]) -> dict[str, Any]:
    import app.search.resource_service as resource_service

    q = str(args.get("query") or "").strip()
    if len(q) < 2:
        return {"ok": False, "error": "关键词太短", "cards": [], "total": 0}
    limit = _limit(args.get("limit"), 6)
    region = str(args.get("region") or "").strip() or None
    try:
        data = await asyncio.to_thread(
            resource_service.search_resources,
            keyword=q,
            p=1,
            ps=limit,
            sort_type="default",
            match_mode="exact",
            with_total_count=True,
            region=region,
        )
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0}
    resources = list(data.get("resources") or [])
    total = int(data.get("total_count") or len(resources))
    cards = _sehual_cards(resources, limit=limit)
    return {
        "ok": True,
        "source": "sehua",
        "mode": "keyword",
        "query": q,
        "total": total,
        "cards": cards,
        "summary": f"仓库关键词「{q}」{total} 条",
    }


async def run_magnet_search(args: dict[str, Any]) -> dict[str, Any]:
    import app.search.bitmagnet_client as bitmagnet_client

    q = str(args.get("query") or "").strip()
    if not q:
        return {"ok": False, "error": "空查询", "cards": [], "total": 0}
    limit = _limit(args.get("limit"), 6)
    try:
        data = await asyncio.to_thread(bitmagnet_client.search, q, page=1)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0}
    items = list(data.get("items") or [])[:limit]
    total = int(data.get("total") or len(items))
    cards: list[dict[str, Any]] = []
    for it in items:
        h = str(it.get("hash") or it.get("infoHash") or it.get("info_hash") or "").strip()
        if not h:
            continue
        title = str(it.get("name") or it.get("title") or h).strip()
        size = it.get("size") or it.get("totalSize")
        meta = _fmt_size(int(size)) if isinstance(size, (int, float)) and size else ""
        cards.append(
            make_card(
                source="magnet",
                title=title,
                subtitle=_guess_code(title),
                meta=meta,
                cover="",
                key=h.lower(),
                open_payload={"kind": "magnet", "hash": h},
            )
        )
    return {
        "ok": True,
        "source": "magnet",
        "mode": "keyword",
        "query": q,
        "total": total,
        "cards": cards,
        "summary": f"磁力「{q}」{total} 条",
    }


def _split_media_id(raw: str) -> tuple[str, str, str]:
    """``tmdb:movie/123`` → (tmdb, 123, movie)；普通数字按 tmdb 电影处理。"""
    text = str(raw or "").strip()
    source, rest = "tmdb", text
    if ":" in text:
        source, _, rest = text.partition(":")
        source = source.strip() or "tmdb"
    media_type = "movie"
    if "/" in rest:
        kind, _, ident = rest.partition("/")
        if kind in ("movie", "tv"):
            media_type, rest = kind, ident
    return source, rest, media_type


async def run_media_search(args: dict[str, Any]) -> dict[str, Any]:
    q = str(args.get("query") or "").strip()
    if not q:
        return {"ok": False, "error": "空查询", "cards": [], "total": 0}
    source = str(args.get("source") or "tmdb").strip().lower() or "tmdb"
    if source not in {"tmdb", "douban", "bangumi", "anilist"}:
        source = "tmdb"
    limit = _limit(args.get("limit"), 6)
    try:
        from app.core.moviepilot_routes import moviepilot_media_search

        items = list(moviepilot_media_search(source, q, 1)["data"]["items"])
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0}
    items = items[:limit]
    cards: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        mid = str(it.get("id") or "").strip()
        title = str(it.get("title") or "").strip() or mid
        year = str(it.get("year") or "").strip()
        media_type = str(it.get("mediaType") or it.get("media_type") or "").strip()
        rating = it.get("rating")
        meta_parts = [year, media_type]
        if isinstance(rating, (int, float)):
            meta_parts.append(f"{float(rating):.1f}")
        cover = str(it.get("posterUrl") or it.get("poster_url") or it.get("poster") or "")
        full_id = mid if ":" in mid else f"{source}:{mid}"
        cards.append(
            make_card(
                source="media",
                title=title,
                subtitle=str(it.get("originalTitle") or it.get("overview") or "")[:40],
                meta=" · ".join(p for p in meta_parts if p),
                cover=cover,
                key=full_id,
                open_payload={"kind": "media", "item": {**it, "id": full_id}},
            )
        )

    # 取头条详情主演，方便多跳（片名 → 演员 → 作品）
    facts: list[dict[str, Any]] = []
    if items:
        first = items[0]
        mid = str(first.get("id") or "").strip()
        full_id = mid if ":" in mid else f"{source}:{mid}"
        cast = await _media_top_cast(full_id)
        if cast:
            facts.append(
                {
                    "title": str(first.get("title") or q),
                    "year": str(first.get("year") or ""),
                    "cast": [c["name"] for c in cast],
                    "personIds": {c["name"]: c["id"] for c in cast if c.get("id")},
                    "hint": "若用户要该片主演的其他作品，下一步用 media_person_works(person_id=影人ID)",
                }
            )

    return {
        "ok": True,
        "source": "media",
        "mode": source,
        "query": q,
        "total": len(cards),
        "cards": cards,
        "facts": facts,
        "summary": f"影视({source})「{q}」{len(cards)} 条"
        + (f"；头条主演 {', '.join(facts[0]['cast'][:3])}" if facts else ""),
    }


async def _media_top_cast(media_id: str) -> list[dict[str, Any]]:
    """尽量拉取作品主演（name + 影人 id），失败则空，不影响主流程。"""
    if not media_id:
        return []
    source, ident, media_type = _split_media_id(media_id)
    try:
        from app.core.moviepilot_routes import moviepilot_detail

        detail = moviepilot_detail(source, ident, media_type)["data"]
    except Exception:  # noqa: BLE001
        return []
    if not isinstance(detail, dict):
        return []
    cast = detail.get("cast") if isinstance(detail.get("cast"), list) else []
    people: list[dict[str, Any]] = []
    for person in cast:
        if not isinstance(person, dict):
            continue
        name = str(person.get("name") or "").strip()
        if not name:
            continue
        pid = str(person.get("id") or "").strip()
        people.append({"name": name, "id": f"{source}:{pid}" if pid else ""})
        if len(people) >= 5:
            break
    return people


async def run_media_person_works(args: dict[str, Any]) -> dict[str, Any]:
    name = str(args.get("name") or args.get("q") or "").strip()
    person_id = str(args.get("person_id") or args.get("personId") or "").strip()
    if not name and not person_id:
        return {"ok": False, "error": "需要影人 ID（可从影视详情 castPeople 获得）", "cards": [], "total": 0}
    limit = _limit(args.get("limit"), 8)
    target = person_id.strip()
    if not target:
        # 桥按 ID 取影人作品；只有姓名时给出可操作提示
        return {
            "ok": False,
            "error": f"缺少影人 ID，请先 media_search 后从 castPeople 取 {name} 的 ID",
            "cards": [],
            "total": 0,
            "summary": f"暂无「{name}」的影人 ID",
        }
    try:
        from app.core.moviepilot_routes import moviepilot_person_credits

        source, ident, _media_type = _split_media_id(target)
        data = moviepilot_person_credits(source, ident, 1)["data"]
    except Exception as e:  # noqa: BLE001
        err = str(getattr(e, "detail", None) or e)
        return {"ok": False, "error": err, "cards": [], "total": 0, "summary": err}
    if not isinstance(data, dict):
        return {"ok": False, "error": "影人作品无数据", "cards": [], "total": 0}
    display = str(data.get("name") or name or person_id)
    items = list(data.get("items") or [])[:limit]
    cards: list[dict[str, Any]] = []
    titles: list[str] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        mid = str(it.get("id") or "").strip()
        title = str(it.get("title") or "").strip() or mid
        if title:
            titles.append(title)
        year = str(it.get("year") or "").strip()
        media_type = str(it.get("mediaType") or it.get("media_type") or "").strip()
        rating = it.get("rating")
        meta_parts = [year, media_type]
        if isinstance(rating, (int, float)):
            meta_parts.append(f"{float(rating):.1f}")
        cover = str(it.get("posterUrl") or it.get("poster_url") or it.get("poster") or "")
        item_source = str(it.get("source") or source).strip() or "tmdb"
        item_type = str(it.get("mediaType") or it.get("media_type") or "movie").strip()
        full_id = (
            mid
            if ":" in mid
            else f"{item_source}:{item_type}/{mid}"
        )
        cards.append(
            make_card(
                source="media",
                title=title,
                subtitle=display[:40],
                meta=" · ".join(p for p in meta_parts if p),
                cover=cover,
                key=full_id or f"person-work:{title}",
                open_payload={"kind": "media", "item": {**it, "id": full_id}},
            )
        )
    facts = [{"person": display, "works": titles[:8]}]
    return {
        "ok": True,
        "source": "media",
        "mode": "person_works",
        "query": name or person_id,
        "total": len(cards),
        "cards": cards,
        "facts": facts,
        "summary": f"影人「{display}」作品 {len(cards)} 部",
    }


async def run_web_search(args: dict[str, Any]) -> dict[str, Any]:
    cfg = resolve_web_search_config(include_secret=True)
    if not cfg.get("enabled"):
        return {
            "ok": False,
            "error": "网络搜索未启用",
            "cards": [],
            "total": 0,
            "summary": "请在 设置 → AI 模型 → 小花 中启用网络搜索",
        }
    provider = str(cfg.get("provider") or "serper").strip().lower()
    api_key = str(cfg.get("apiKey") or "").strip()
    base_url = str(cfg.get("baseUrl") or "").strip().rstrip("/")
    if provider == "searxng":
        if not base_url:
            return {
                "ok": False,
                "error": "未配置 SearXNG 地址",
                "cards": [],
                "total": 0,
                "summary": "请填写 SearXNG 服务地址，例如 http://192.168.2.38:8085",
            }
    elif not api_key:
        return {
            "ok": False,
            "error": "未配置网络搜索 API Key",
            "cards": [],
            "total": 0,
            "summary": "未配置网络搜索 API Key",
        }
    q = str(args.get("query") or "").strip()
    if not q:
        return {"ok": False, "error": "空查询", "cards": [], "total": 0}
    limit = _limit(args.get("limit"), 5, hi=8)
    try:
        if provider == "searxng":
            hits = await _searxng_search(q, base_url=base_url, limit=limit)
        elif provider == "brave":
            hits = await _brave_search(q, api_key=api_key, limit=limit)
        else:
            hits = await _serper_search(q, api_key=api_key, limit=limit)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"网络搜索失败：{e}"}

    cards: list[dict[str, Any]] = []
    for h in hits:
        url = str(h.get("url") or "").strip()
        if not url:
            continue
        title = str(h.get("title") or url).strip()
        snippet = _format_web_meta(str(h.get("snippet") or ""))
        host = _web_host(url)
        cards.append(
            make_card(
                source="web",
                title=title,
                subtitle=host,
                meta=snippet,
                cover="",
                key=url,
                open_payload={"kind": "url", "url": url, "title": title},
            )
        )
    return {
        "ok": True,
        "source": "web",
        "mode": provider,
        "query": q,
        "total": len(cards),
        "cards": cards,
        "summary": f"网络({provider})「{q}」{len(cards)} 条",
    }


_MAGNET_HASH_RE = re.compile(r"urn:btih:([0-9a-fA-F]{32,40})")


def _hash_from_magnet(url: str) -> str:
    m = _MAGNET_HASH_RE.search(str(url or ""))
    return m.group(1).lower() if m else ""


def _str_list(raw: Any) -> list[str]:
    if isinstance(raw, str):
        return [raw.strip()] if raw.strip() else []
    if isinstance(raw, (list, tuple)):
        return [str(x).strip() for x in raw if str(x).strip()]
    return []


def _file_rows(files: Any, limit: int = 8) -> list[str]:
    out: list[str] = []
    for f in files or []:
        if isinstance(f, dict):
            path = str(f.get("path") or f.get("name") or "").strip()
            size = f.get("size")
        else:
            path = str(f).strip()
            size = None
        if not path:
            continue
        row = path[:90]
        if isinstance(size, (int, float)) and size > 0:
            row += f" ({_fmt_size(int(size))})"
        out.append(row)
        if len(out) >= limit:
            break
    return out


async def run_sehua_detail(args: dict[str, Any]) -> dict[str, Any]:
    h = str(args.get("hash") or args.get("info_hash") or "").strip()
    if len(h) < 32:
        return {"ok": False, "error": "hash 不合法", "cards": [], "total": 0}
    try:
        import app.search.resource_service as resource_service

        item = await asyncio.to_thread(resource_service.resource_by_hash, h)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"仓库详情失败：{e}"}
    if not isinstance(item, dict) or not item:
        return {"ok": False, "error": "未找到该资源", "cards": [], "total": 0, "summary": "仓库里没有这个 hash"}
    title = display_hit_label(
        title=item.get("title"),
        description=item.get("description"),
        filename=item.get("name") or item.get("filename"),
    )
    size = item.get("size")
    cover = ""
    previews = item.get("preview_images") or item.get("images") or []
    if isinstance(previews, list) and previews:
        cover = str(previews[0] or "")
    card = make_card(
        source="sehua",
        title=title,
        subtitle=_guess_code(title),
        meta=_fmt_size(int(size)) if isinstance(size, (int, float)) and size > 0 else "",
        cover=cover,
        key=h.lower(),
        open_payload={"kind": "sehua", "hash": h},
    )
    facts = {
        "title": title,
        "code": _guess_code(title),
        "size": _fmt_size(int(size)) if isinstance(size, (int, float)) and size > 0 else "",
        "files": _file_rows(item.get("files")),
        "ed2kLinks": _str_list(item.get("ed2k_links") or item.get("ed2k_link"))[:6],
        "extractPassword": str(item.get("extract_password") or ""),
        "sourceUrl": str(item.get("source_url") or ""),
    }
    return {
        "ok": True,
        "source": "sehua",
        "mode": "detail",
        "query": title,
        "total": 1,
        "cards": [card],
        "facts": [facts],
        "summary": f"仓库资源「{title[:40]}」",
    }


async def run_magnet_detail(args: dict[str, Any]) -> dict[str, Any]:
    h = str(args.get("hash") or args.get("info_hash") or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{32}|[0-9a-f]{40}", h):
        return {"ok": False, "error": "infoHash 不合法", "cards": [], "total": 0}
    try:
        import app.search.bitmagnet_client as bitmagnet_client

        item = await asyncio.to_thread(bitmagnet_client.get, h)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"磁力详情失败：{e}"}
    title = str(item.get("name") or item.get("title") or h)
    size_text = str(item.get("sizeText") or "")
    magnet = str(item.get("magnet_uri") or item.get("magnet") or "")
    files = _file_rows(item.get("files"))
    card = make_card(
        source="magnet",
        title=title,
        subtitle=size_text or h[:12],
        meta=f"{int(item.get('fileCount') or 0)} 个文件",
        key=h,
        open_payload={"kind": "magnet", "hash": h},
    )
    facts = {
        "title": title,
        "size": size_text,
        "fileCount": int(item.get("fileCount") or 0),
        "files": files,
        "magnet": magnet,
    }
    return {
        "ok": True,
        "source": "magnet",
        "mode": "detail",
        "query": title,
        "total": 1,
        "cards": [card],
        "facts": [facts],
        "summary": f"种子「{title[:40]}」",
    }


async def run_media_detail(args: dict[str, Any]) -> dict[str, Any]:
    raw_id = str(args.get("media_id") or args.get("id") or "").strip()
    if not raw_id:
        return {"ok": False, "error": "缺少 media_id", "cards": [], "total": 0}
    try:
        source, ident, media_type = _split_media_id(raw_id)
        from app.core.moviepilot_routes import moviepilot_detail

        raw = await asyncio.to_thread(moviepilot_detail, source, ident, media_type)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"影视详情失败：{e}"}
    detail = raw.get("data") if isinstance(raw, dict) else None
    if not isinstance(detail, dict) or not detail:
        return {"ok": False, "error": "未找到影视详情", "cards": [], "total": 0}

    full_id = str(detail.get("id") or raw_id)
    title = str(detail.get("title") or "")
    cast_people: list[dict[str, str]] = []
    for c in detail.get("cast") or []:
        if not isinstance(c, dict):
            continue
        pid = str(c.get("id") or "").strip()
        name = str(c.get("name") or "").strip()
        if not pid or not name:
            continue
        cast_people.append(
            {"name": name, "personId": pid if ":" in pid else f"{source}:{pid}"}
        )
        if len(cast_people) >= 8:
            break
    item = {**detail, "id": full_id}
    card = make_card(
        source="media",
        title=title or full_id,
        subtitle=str(detail.get("originalTitle") or ""),
        meta=str(detail.get("year") or ""),
        cover=str(detail.get("posterUrl") or ""),
        key=full_id,
        open_payload={"kind": "media", "item": item},
    )
    facts = {
        "title": title,
        "originalTitle": str(detail.get("originalTitle") or ""),
        "year": str(detail.get("year") or ""),
        "rating": detail.get("rating"),
        "runtime": detail.get("runtime"),
        "genres": detail.get("genres") or [],
        "countries": detail.get("countries") or [],
        "overview": str(detail.get("overview") or "")[:400],
        "imdbId": str(detail.get("imdbId") or ""),
        "cast": cast_people,
    }
    return {
        "ok": True,
        "source": "media",
        "mode": "detail",
        "query": title or full_id,
        "total": 1,
        "cards": [card],
        "facts": [facts],
        "summary": f"影视详情「{title or full_id}」",
    }


async def run_av_search(args: dict[str, Any]) -> dict[str, Any]:
    q = str(args.get("query") or "").strip()
    if not q:
        return {"ok": False, "error": "空查询", "cards": [], "total": 0}
    kind = str(args.get("type") or "code").strip().lower()
    limit = _limit(args.get("limit"), 8)
    try:
        from app.makers.service import fetch_movie_search, fetch_search

        if kind in {"code", "movie", "all"}:
            data = await asyncio.to_thread(
                fetch_movie_search, q, 1, limit, False, "all", "", "relevance"
            )
            rows = [
                {
                    "movieId": str(it.get("id") or ""),
                    "code": str(it.get("number") or ""),
                    "title": str(it.get("title") or ""),
                    "releaseDate": str(it.get("releaseDate") or ""),
                    "magnets": int(it.get("magnetsCount") or 0),
                    "cnsub": bool(it.get("hasCnsub")),
                }
                for it in (data.get("items") or [])
                if isinstance(it, dict)
            ]
            mode = "movie"
        else:
            data = await asyncio.to_thread(fetch_search, q, kind)
            rows = [
                {
                    "id": str(it.get("id") or ""),
                    "name": str(it.get("name") or ""),
                    "kind": str(it.get("kind") or kind),
                    "count": int(it.get("count") or 0),
                }
                for it in (data.get("items") or [])
                if isinstance(it, dict)
            ]
            mode = kind
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"AV 搜索失败：{e}"}
    return {
        "ok": True,
        "source": "av",
        "mode": mode,
        "query": q,
        "total": len(rows),
        "cards": [],
        "facts": [{"mode": mode, "results": rows}],
        "summary": f"AV「{q}」{len(rows)} 条",
    }


async def run_av_movie(args: dict[str, Any]) -> dict[str, Any]:
    mid = str(args.get("movie_id") or args.get("id") or "").strip()
    if not mid:
        return {"ok": False, "error": "缺少 movie_id", "cards": [], "total": 0}
    limit = _limit(args.get("limit"), 8)
    try:
        from app.makers.service import fetch_movie_detail

        detail = await asyncio.to_thread(fetch_movie_detail, mid)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"AV 详情失败：{e}"}

    magnets_out: list[dict[str, Any]] = []
    cards: list[dict[str, Any]] = []
    for m in (detail.get("magnets") or [])[:limit]:
        if not isinstance(m, dict):
            continue
        url = str(m.get("url") or "")
        h = _hash_from_magnet(url)
        name = str(m.get("name") or m.get("title") or detail.get("number") or mid)
        size = str(m.get("sizeText") or m.get("size") or "")
        magnets_out.append({"name": name, "size": size, "url": url})
        if h:
            cards.append(
                make_card(
                    source="magnet",
                    title=name,
                    subtitle=size,
                    meta=str(detail.get("number") or ""),
                    key=h,
                    open_payload={"kind": "magnet", "hash": h},
                )
            )
    actors = [
        {"name": str(a.get("name") or ""), "id": str(a.get("id") or "")}
        for a in (detail.get("actors") or [])
        if isinstance(a, dict) and a.get("name")
    ]
    facts = {
        "movieId": str(detail.get("id") or mid),
        "code": str(detail.get("number") or ""),
        "title": str(detail.get("title") or ""),
        "summary": str(detail.get("summary") or "")[:300],
        "releaseDate": str(detail.get("releaseDate") or ""),
        "duration": detail.get("duration"),
        "score": detail.get("score"),
        "makers": detail.get("makers") or [],
        "actors": actors[:8],
        "tags": detail.get("tags") or [],
        "magnets": magnets_out,
        "resources": [
            {"name": str(r.get("name") or ""), "url": str(r.get("url") or "")}
            for r in (detail.get("resources") or [])[:6]
            if isinstance(r, dict)
        ],
    }
    return {
        "ok": True,
        "source": "av",
        "mode": "movie",
        "query": facts["code"] or facts["title"] or mid,
        "total": len(magnets_out),
        "cards": cards[:limit],
        "facts": [facts],
        "summary": f"AV「{facts['code'] or facts['title'] or mid}」种子 {len(magnets_out)} 条",
    }


async def run_av_actor_works(args: dict[str, Any]) -> dict[str, Any]:
    aid = str(args.get("actor_id") or args.get("id") or "").strip()
    if not aid:
        return {"ok": False, "error": "缺少 actor_id", "cards": [], "total": 0}
    name = str(args.get("name") or "").strip()
    limit = _limit(args.get("limit"), 10)
    try:
        from app.makers.service import fetch_browse

        data = await asyncio.to_thread(
            fetch_browse,
            "0", "", "", "", aid, "", "", "", "", "", "", "",
            "release", "desc", 1, limit,
        )
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"女优作品失败：{e}"}
    rows = [
        {
            "movieId": str(it.get("id") or ""),
            "code": str(it.get("number") or ""),
            "title": str(it.get("title") or ""),
            "releaseDate": str(it.get("releaseDate") or ""),
            "magnets": int(it.get("magnetsCount") or 0),
        }
        for it in (data.get("items") or [])
        if isinstance(it, dict)
    ]
    label = name or aid
    return {
        "ok": True,
        "source": "av",
        "mode": "actor",
        "query": label,
        "total": len(rows),
        "cards": [],
        "facts": [{"actor": label, "actorId": aid, "results": rows}],
        "summary": f"「{label}」作品 {len(rows)} 部",
    }


async def run_media_streams(args: dict[str, Any]) -> dict[str, Any]:
    imdb_id = str(args.get("imdb_id") or "").strip()
    if not imdb_id.startswith("tt"):
        return {"ok": False, "error": "imdb_id 需形如 tt1234567", "cards": [], "total": 0}
    media_type = "series" if str(args.get("media_type") or "movie").lower() in {"tv", "series"} else "movie"
    try:
        season = max(0, int(args.get("season") or 0))
        episode = max(0, int(args.get("episode") or 0))
    except (TypeError, ValueError):
        season = episode = 0
    try:
        from app.rexhub.addons_store import streams as addon_streams

        data = await addon_streams.collect(media_type, imdb_id, season, episode)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"片源查询失败：{e}"}
    streams = [s for s in (data.get("streams") or []) if isinstance(s, dict)]
    cards: list[dict[str, Any]] = []
    rows: list[dict[str, Any]] = []
    for s in streams[:12]:
        kind = str(s.get("kind") or "")
        url = str(s.get("url") or s.get("externalUrl") or "")
        info_hash = str(s.get("infoHash") or "").lower()
        name = str(s.get("name") or s.get("addon") or "片源")
        addon = str(s.get("addon") or "")
        desc = str(s.get("title") or "")[:100]
        rows.append({"addon": addon, "name": name, "kind": kind, "title": desc, "url": url})
        if kind == "torrent" and info_hash:
            cards.append(
                make_card(
                    source="magnet",
                    title=name,
                    subtitle=addon,
                    meta=desc,
                    key=info_hash,
                    open_payload={"kind": "magnet", "hash": info_hash},
                )
            )
        elif url.startswith("http"):
            cards.append(
                make_card(
                    source="stream",
                    title=name,
                    subtitle=addon,
                    meta=desc,
                    key=url,
                    open_payload={"kind": "url", "url": url, "title": name},
                )
            )
    if not rows:
        return {
            "ok": True,
            "source": "stream",
            "mode": media_type,
            "query": imdb_id,
            "total": 0,
            "cards": [],
            "facts": [{"imdbId": imdb_id, "streams": [], "reason": str(data.get("reason") or "")}],
            "summary": "没有可用片源（可能未配置片源插件）",
        }
    return {
        "ok": True,
        "source": "stream",
        "mode": media_type,
        "query": imdb_id,
        "total": len(rows),
        "cards": cards[:12],
        "facts": [{"imdbId": imdb_id, "streams": rows}],
        "summary": f"{imdb_id} 可用片源 {len(rows)} 条",
    }


async def run_cloudsaver_search(args: dict[str, Any]) -> dict[str, Any]:
    q = str(args.get("query") or "").strip()
    if not q:
        return {"ok": False, "error": "空查询", "cards": [], "total": 0}
    limit = _limit(args.get("limit"), 6)
    try:
        import app.search.cloudsaver_client as cloudsaver_client

        data = await asyncio.to_thread(cloudsaver_client.search, q)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"网盘搜索失败：{e}"}
    items = [it for it in (data.get("items") or []) if isinstance(it, dict)][:limit]
    cards: list[dict[str, Any]] = []
    rows: list[dict[str, Any]] = []
    for it in items:
        title = str(it.get("title") or q)
        links = [lk for lk in (it.get("links") or []) if isinstance(lk, dict)]
        main = links[0] if links else {}
        url = str(main.get("url") or "")
        channel = str(it.get("channel") or main.get("type") or "")
        password = str(main.get("password") or "")
        rows.append(
            {
                "title": title,
                "channel": channel,
                "url": url,
                "password": password,
                "links": len(links),
            }
        )
        if url.startswith("http"):
            cards.append(
                make_card(
                    source="cloud",
                    title=title,
                    subtitle=channel,
                    meta=f"提取码 {password}" if password else "",
                    key=url,
                    open_payload={"kind": "url", "url": url, "title": title},
                )
            )
    return {
        "ok": True,
        "source": "cloud",
        "mode": "search",
        "query": q,
        "total": len(rows),
        "cards": cards,
        "facts": [{"results": rows}],
        "summary": f"网盘「{q}」{len(rows)} 条",
    }


async def run_p115_save(args: dict[str, Any]) -> dict[str, Any]:
    raw = args.get("urls") if args.get("urls") is not None else args.get("url")
    urls = _str_list(raw)
    if not urls:
        return {"ok": False, "error": "缺少链接", "cards": [], "total": 0}
    bad = [
        u
        for u in urls
        if not re.match(r"^(https?://|magnet:\?|ed2k://)", u, re.I)
    ]
    if bad:
        return {
            "ok": False,
            "error": f"不支持的链接：{bad[0][:48]}",
            "cards": [],
            "total": 0,
            "summary": "只支持网页分享链接、磁力或 ed2k 链接",
        }
    password = str(args.get("password") or "").strip()
    cid = str(args.get("cid") or "0").strip() or "0"
    try:
        from app.rexhub import pan115

        result = await asyncio.to_thread(pan115.save_to_drive, urls, password, cid)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cards": [], "total": 0, "summary": f"转存失败：{e}"}
    count = int(result.get("count") or 0)
    errors = [str(x) for x in (result.get("errors") or [])][:3]
    return {
        "ok": count > 0,
        "source": "cloud",
        "mode": "save",
        "query": f"{count} 项",
        "total": count,
        "cards": [],
        "facts": [
            {
                "mode": result.get("mode"),
                "count": count,
                "received": int(result.get("received") or 0),
                "cloud": int(result.get("cloud") or 0),
                "errors": errors,
            }
        ],
        "summary": f"已转存到 115：{count} 项" + (f"（失败 {len(errors)}）" if errors else ""),
    }


async def _searxng_search(query: str, *, base_url: str, limit: int) -> list[dict[str, str]]:
    root = base_url.rstrip("/")
    async with httpx.AsyncClient(timeout=httpx.Timeout(25.0, connect=8.0)) as client:
        r = await client.get(
            f"{root}/search",
            params={
                "q": query,
                "format": "json",
                "language": "zh-CN",
            },
        )
    if not r.is_success:
        raise RuntimeError(f"SearXNG {r.status_code}: {r.text[:160]}")
    data = r.json() or {}
    rows = data.get("results") or []
    out: list[dict[str, str]] = []
    for row in rows[:limit]:
        if not isinstance(row, dict):
            continue
        url = str(row.get("url") or "").strip()
        if not url:
            continue
        out.append(
            {
                "title": str(row.get("title") or url).strip(),
                "url": url,
                "snippet": str(row.get("content") or row.get("snippet") or "").strip(),
            }
        )
    return out


async def _serper_search(query: str, *, api_key: str, limit: int) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=8.0)) as client:
        r = await client.post(
            "https://google.serper.dev/search",
            headers={"X-API-KEY": api_key, "Content-Type": "application/json"},
            json={"q": query, "num": limit},
        )
    if r.status_code == 401:
        raise RuntimeError("Serper API Key 无效")
    if not r.is_success:
        raise RuntimeError(f"Serper {r.status_code}: {r.text[:160]}")
    data = r.json() or {}
    organic = data.get("organic") or []
    out: list[dict[str, str]] = []
    for row in organic[:limit]:
        if not isinstance(row, dict):
            continue
        out.append(
            {
                "title": str(row.get("title") or ""),
                "url": str(row.get("link") or ""),
                "snippet": str(row.get("snippet") or ""),
            }
        )
    return out


async def _brave_search(query: str, *, api_key: str, limit: int) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=8.0)) as client:
        r = await client.get(
            "https://api.search.brave.com/res/v1/web/search",
            headers={
                "Accept": "application/json",
                "X-Subscription-Token": api_key,
            },
            params={"q": query, "count": limit},
        )
    if r.status_code == 401:
        raise RuntimeError("Brave API Key 无效")
    if not r.is_success:
        raise RuntimeError(f"Brave {r.status_code}: {r.text[:160]}")
    data = r.json() or {}
    web = (data.get("web") or {}).get("results") or []
    out: list[dict[str, str]] = []
    for row in web[:limit]:
        if not isinstance(row, dict):
            continue
        out.append(
            {
                "title": str(row.get("title") or ""),
                "url": str(row.get("url") or ""),
                "snippet": str(row.get("description") or ""),
            }
        )
    return out


TOOL_HANDLERS: dict[str, ToolHandler] = {
    "sehua_keyword": run_sehua_keyword,
    "sehua_detail": run_sehua_detail,
    "magnet_search": run_magnet_search,
    "magnet_detail": run_magnet_detail,
    "media_search": run_media_search,
    "media_detail": run_media_detail,
    "media_person_works": run_media_person_works,
    "av_search": run_av_search,
    "av_movie": run_av_movie,
    "av_actor_works": run_av_actor_works,
    "media_streams": run_media_streams,
    "cloudsaver_search": run_cloudsaver_search,
    "p115_save": run_p115_save,
    "web_search": run_web_search,
}

TOOL_STATUS_LABEL: dict[str, str] = {
    "sehua_keyword": "正在仓库搜…",
    "sehua_detail": "正在看仓库详情…",
    "magnet_search": "正在磁力库搜…",
    "magnet_detail": "正在看种子文件…",
    "media_search": "正在影视库搜…",
    "media_detail": "正在看影视详情…",
    "media_person_works": "正在查影人作品…",
    "av_search": "正在搜 AV 片库…",
    "av_movie": "正在看 AV 详情…",
    "av_actor_works": "正在查女优作品…",
    "media_streams": "正在找在线片源…",
    "cloudsaver_search": "正在搜网盘…",
    "p115_save": "正在转存到 115…",
    "web_search": "正在搜网络…",
}


async def dispatch_tool(name: str, arguments: dict[str, Any] | str | None) -> dict[str, Any]:
    handler = TOOL_HANDLERS.get(name)
    if not handler:
        return {"ok": False, "error": f"未知工具 {name}", "cards": [], "total": 0}
    if isinstance(arguments, str):
        try:
            args = json.loads(arguments) if arguments.strip() else {}
        except json.JSONDecodeError:
            args = {}
    elif isinstance(arguments, dict):
        args = arguments
    else:
        args = {}
    try:
        result = await handler(args)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"{name} 调用失败：{e}", "cards": [], "total": 0}
    if not isinstance(result, dict):
        return {"ok": False, "error": f"{name} 返回异常", "cards": [], "total": 0}
    if "cards" not in result:
        result["cards"] = []
    return result


def tool_result_for_llm(result: dict[str, Any]) -> str:
    payload = {
        "ok": bool(result.get("ok")),
        "summary": result.get("summary") or result.get("error") or "",
        "total": result.get("total") or 0,
        "cards": [
            {
                "source": c.get("source"),
                "title": c.get("title"),
                "subtitle": c.get("subtitle"),
                "meta": c.get("meta"),
            }
            for c in (result.get("cards") or [])[:8]
        ],
    }
    facts = result.get("facts")
    if isinstance(facts, list) and facts:
        payload["facts"] = facts[:4]
    if result.get("error") and not result.get("ok"):
        payload["error"] = result["error"]
    return json.dumps(payload, ensure_ascii=False)


def collect_cards_from_results(results: list[dict[str, Any]], *, limit: int = 24) -> list[dict[str, Any]]:
    groups = [list(r.get("cards") or []) for r in results if isinstance(r, dict)]
    return merge_cards(*groups, limit=limit)


def collect_ui_cards(
    results: list[dict[str, Any]],
    *,
    message: str,
    limit: int = 24,
) -> list[dict[str, Any]]:
    from app.ai.assistant_protocol import user_wants_resource_cards

    return select_ui_cards(
        results,
        wants_cards=user_wants_resource_cards(message),
        limit=limit,
    )


async def heuristic_local_search(
    message: str,
    *,
    prefer: list[str] | None = None,
    enabled_tools: list[str] | set[str] | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """无 LLM 时的降级：按 prefer 或启发式并行搜本地。"""
    q = message.strip()
    prefer_set = {str(s).strip().lower() for s in (prefer or []) if str(s).strip()}
    allow = (
        {str(x).strip() for x in enabled_tools if str(x).strip()}
        if enabled_tools is not None
        else None
    )
    jobs: list[tuple[str, dict[str, Any]]] = []

    def want(*keys: str) -> bool:
        if not prefer_set:
            return True
        return bool(prefer_set & set(keys))

    def tool_ok(name: str) -> bool:
        return allow is None or name in allow

    if want("sehua", "warehouse") and tool_ok("sehua_keyword"):
        jobs.append(("sehua_keyword", {"query": q, "limit": 5}))
    if want("magnet") and tool_ok("magnet_search"):
        jobs.append(("magnet_search", {"query": q, "limit": 5}))
    if want("media") and tool_ok("media_search"):
        jobs.append(("media_search", {"query": q, "limit": 5}))
    if "av" in prefer_set and tool_ok("av_search"):
        jobs.append(("av_search", {"query": q, "limit": 5}))
    if "cloud" in prefer_set and tool_ok("cloudsaver_search"):
        jobs.append(("cloudsaver_search", {"query": q, "limit": 5}))
    if not jobs and allow is not None:
        # 无 prefer 命中时，退到已启用工具
        for name in (
            "sehua_keyword",
            "magnet_search",
            "media_search",
            "av_search",
            "cloudsaver_search",
        ):
            if name in allow:
                jobs.append((name, {"query": q, "limit": 5}))
    elif not jobs:
        jobs = [
            ("sehua_keyword", {"query": q, "limit": 5}),
            ("magnet_search", {"query": q, "limit": 5}),
            ("media_search", {"query": q, "limit": 5}),
        ]

    # 并发跑各工具；gather 保序。单个工具异常降级为一条失败结果，不拖垮整轮检索
    outs = await asyncio.gather(
        *(dispatch_tool(name, args) for name, args in jobs), return_exceptions=True
    )
    results: list[dict[str, Any]] = []
    steps: list[dict[str, Any]] = []
    for (name, _), r in zip(jobs, outs):
        if isinstance(r, BaseException):
            r = {"ok": False, "error": str(r), "cards": [], "total": 0}
        results.append(r)
        steps.append(
            {
                "tool": name,
                "status": "done",
                "ok": bool(r.get("ok")),
                "summary": r.get("summary") or r.get("error") or "",
            }
        )
    return collect_cards_from_results(results), steps
