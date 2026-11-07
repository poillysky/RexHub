"""插件导出：把已安装插件生成为 ForwardWidget 兼容的 JS 文件。

- ``widget-js`` 插件本身就是单文件 ForwardWidget，直接原样导出。
- HTTP 插件直接使用 runtime.base_url，生成可独立运行的模块。
- 独立进程 / 共享运行时插件需要填写对外访问地址，导出后由 App 直接访问该地址。
"""

import json
import re
import time
from typing import Any
from urllib.parse import urlparse

from app.rexhub.plugin_framework import store

_SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")


def _safe_base(value: str) -> str:
    text = str(value or "").strip().rstrip("/")
    if not text:
        return ""
    parsed = urlparse(text)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("访问地址必须是 http(s) 开头")
    return text


def _endpoint(row: dict[str, Any], capability: str) -> dict[str, str]:
    endpoints = row.get("endpoints")
    if not isinstance(endpoints, dict):
        return {}
    spec = endpoints.get(capability)
    if isinstance(spec, dict):
        path = str(spec.get("path") or "").strip()
        method = str(spec.get("method") or "GET").upper()
    elif isinstance(spec, str):
        path = spec.strip()
        method = "GET"
    else:
        return {}
    if not path:
        return {}
    return {"path": path, "method": method}


def _metadata(
    row: dict[str, Any],
    modules: list[dict[str, Any]],
    search: dict[str, Any] | None,
    *,
    bridge: bool,
) -> dict[str, Any]:
    version = str(row.get("installed_version") or row.get("version") or "0.0.0")
    data: dict[str, Any] = {
        "id": str(row.get("id") or "rexhub.plugin"),
        "title": str(row.get("name") or row.get("id") or "插件"),
        "version": version,
        "requiredVersion": "0.0.1",
        "description": str(row.get("description") or ""),
        "author": str(row.get("author") or "RexHub"),
        "detailCacheDuration": 60,
        "modules": modules,
    }
    if search:
        data["search"] = search
    if bridge:
        data["globalParams"] = [
            {
                "name": "server",
                "title": "RexHub 服务端地址",
                "type": "input",
                "placeholders": [
                    {"title": "示例", "value": "http://192.168.2.10:8020"},
                ],
            }
        ]
    return data


def _build_js(
    row: dict[str, Any],
    *,
    base_url: str,
    capabilities: list[str],
    direct: bool,
) -> str:
    endpoints = {
        capability: spec
        for capability in capabilities
        if (spec := _endpoint(row, capability))
    }
    modules: list[dict[str, Any]] = []
    search: dict[str, Any] | None = None

    if "playback.extract" in endpoints or "resource.search" in endpoints:
        list_params: list[dict[str, Any]] = [
            {"name": "page", "title": "页码", "type": "page"},
        ]
        if "playback.extract" in endpoints:
            list_params.extend(
                [
                    {"name": "group", "title": "榜单分组", "type": "input"},
                    {"name": "rank", "title": "榜单", "type": "input"},
                    {"name": "filter", "title": "筛选", "type": "input"},
                ]
            )
        modules.append(
            {
                "id": "loadList",
                "title": "列表",
                "functionName": "loadList",
                "cacheDuration": 600,
                "params": list_params,
            }
        )
    if "resource.search" in endpoints:
        search = {
            "title": "搜索",
            "functionName": "search",
            "params": [
                {"name": "keyword", "title": "关键词", "type": "input"},
                {"name": "page", "title": "页码", "type": "page"},
            ],
        }
    if "metadata.movie" in endpoints or "metadata.tv" in endpoints:
        # loadDetail 是顶层函数，不放进 modules
        pass
    if "playback.stream" in endpoints:
        modules.append(
            {
                "id": "loadResource",
                "title": "播放资源",
                "functionName": "loadResource",
                "type": "stream",
                "cacheDuration": 0,
                "params": [],
            }
        )
    if "subtitle.download" in endpoints or "subtitle.search" in endpoints:
        modules.append(
            {
                "id": "loadSubtitle",
                "title": "字幕",
                "functionName": "loadSubtitle",
                "type": "subtitle",
                "params": [],
            }
        )
    if (
        "danmaku.search" in endpoints
        or "danmaku.detail" in endpoints
        or "danmaku.fetch" in endpoints
    ):
        modules.extend(
            [
                {
                    "id": "searchDanmu",
                    "title": "搜索弹幕",
                    "functionName": "searchDanmu",
                    "type": "danmu",
                    "params": [],
                },
                {
                    "id": "getDetail",
                    "title": "弹幕剧集",
                    "functionName": "getDetailById",
                    "type": "danmu",
                    "params": [],
                },
                {
                    "id": "getComments",
                    "title": "弹幕内容",
                    "functionName": "getCommentsById",
                    "type": "danmu",
                    "params": [],
                },
                {
                    "id": "getDanmuWithSegmentTime",
                    "title": "分片弹幕",
                    "functionName": "getDanmuWithSegmentTime",
                    "type": "danmu",
                    "params": [],
                },
            ]
        )

    meta = _metadata(row, modules, search, bridge=not direct)
    list_cap = "playback.extract" if "playback.extract" in endpoints else "resource.search"
    detail_cap = "metadata.tv" if "metadata.tv" in endpoints else "metadata.movie"
    subtitle_cap = "subtitle.download" if "subtitle.download" in endpoints else "subtitle.search"

    template = _TEMPLATE
    substitutions = {
        "__METADATA__": json.dumps(meta, ensure_ascii=False, indent=2),
        "__ENDPOINTS__": json.dumps(endpoints, ensure_ascii=False, indent=2),
        "__SERVER__": json.dumps(base_url, ensure_ascii=False),
        "__PLUGIN_ID__": str(row.get("id") or ""),
        "__PLUGIN_ID_JS__": json.dumps(str(row.get("id") or ""), ensure_ascii=False),
        "__DIRECT__": "true" if direct else "false",
        "__LIST_CAP__": json.dumps(list_cap if list_cap in endpoints else ""),
        "__DETAIL_CAP__": json.dumps(detail_cap if detail_cap in endpoints else ""),
        "__SUBTITLE_CAP__": json.dumps(subtitle_cap if subtitle_cap in endpoints else ""),
        "__HAS_SEARCH__": "true" if search else "false",
        "__EXPORTED_AT__": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    for key, value in substitutions.items():
        template = template.replace(key, value)
    return template


def export_plugin(plugin_id: str, *, base_url: str = "") -> dict[str, Any]:
    row = store.get_plugin(plugin_id)
    version = str(row.get("installed_version") or row.get("version") or "0.0.0")
    safe_id = _SAFE_NAME_RE.sub("-", plugin_id).strip("-") or "plugin"
    filename = f"{safe_id}-{version}.js"

    if str(row.get("protocol") or "") == "widget-js":
        entry = str(row.get("entrypoint") or (row.get("runtime") or {}).get("entrypoint") or "plugin.js")
        source = store.install_path(row) / entry
        if not source.is_file():
            raise ValueError("插件 JS 源文件不存在")
        return {
            "filename": filename,
            "content": source.read_text("utf-8"),
            "mode": "source",
            "base_url": "",
        }

    runtime_spec = row.get("runtime") if isinstance(row.get("runtime"), dict) else {}
    direct = str(runtime_spec.get("type") or "") == "http"
    if direct:
        resolved = _safe_base(str(runtime_spec.get("base_url") or ""))
        if not resolved:
            raise ValueError("HTTP 插件缺少 base_url，无法导出")
    else:
        # 独立进程插件导出时地址留空，由 App 加载 JS 后再填写
        resolved = _safe_base(base_url)

    capabilities = [str(item) for item in (row.get("capabilities") or [])]
    content = _build_js(
        row, base_url=resolved, capabilities=capabilities, direct=direct
    )
    return {
        "filename": filename,
        "content": content,
        "mode": "http" if direct else "bridge",
        "base_url": resolved,
    }


_TEMPLATE = r"""// RexHub 插件导出的 ForwardWidget 模块
// 插件：__PLUGIN_ID__
// 导出时间：__EXPORTED_AT__

WidgetMetadata = __METADATA__;

const SERVER = __SERVER__;
const PLUGIN_ID = __PLUGIN_ID_JS__;
const DIRECT = __DIRECT__;
const ENDPOINTS = __ENDPOINTS__;
const LIST_CAP = __LIST_CAP__;
const DETAIL_CAP = __DETAIL_CAP__;
const SUBTITLE_CAP = __SUBTITLE_CAP__;
const HAS_SEARCH = __HAS_SEARCH__;

function encode(value) {
  return encodeURIComponent(String(value == null ? "" : value));
}

function fillPath(path, params) {
  return String(path).replace(/\{([A-Za-z0-9_.-]+)\}/g, function (_, key) {
    return encode(params[key]);
  });
}

function queryOf(params) {
  const parts = [];
  Object.keys(params || {}).forEach(function (key) {
    if (key === "server") return;
    const value = params[key];
    if (value == null || value === "" || typeof value === "object") return;
    parts.push(encode(key) + "=" + encode(value));
  });
  return parts.join("&");
}

function serverOf(params) {
  const input = params && params.server ? String(params.server).replace(/\/+$/, "") : "";
  if (input) {
    try {
      Widget.storage.set("rexhub.server", input);
    } catch (e) {}
    return input;
  }
  try {
    const saved = Widget.storage.get("rexhub.server");
    if (saved) return String(saved).replace(/\/+$/, "");
  } catch (e) {}
  return SERVER;
}

function withId(params) {
  const next = Object.assign({}, params || {});
  if (next.id == null || next.id === "") next.id = next.link;
  return next;
}

function assetUrl(value) {
  const text = String(value == null ? "" : value);
  if (!text || text.charAt(0) !== "/" || text.charAt(1) === "/") return text;
  return SERVER ? SERVER + text : text;
}

async function call(capability, params) {
  const input = params || {};
  if (!DIRECT) {
    const base = serverOf(input);
    if (!base) throw new Error("请先在模块设置中填写 RexHub 服务端地址");
    let url = base + "/api/v1/plugins/" + encode(PLUGIN_ID) + "/proxy/" + encode(capability);
    const query = queryOf(input);
    if (query) url += (url.indexOf("?") >= 0 ? "&" : "?") + query;
    const res = await Widget.http.get(url);
    return res.data;
  }
  const spec = ENDPOINTS[capability];
  if (!spec || !spec.path) throw new Error("未声明接口：" + capability);
  let url = SERVER + fillPath(spec.path, input);
  if ((spec.method || "GET").toUpperCase() === "GET") {
    const query = queryOf(input);
    if (query) url += (url.indexOf("?") >= 0 ? "&" : "?") + query;
    const res = await Widget.http.get(url);
    return res.data;
  }
  const res = await Widget.http.post(url, input);
  return res.data;
}

function rowsOf(payload) {
  if (Array.isArray(payload)) return payload;
  if (!payload || typeof payload !== "object") return [];
  const keys = ["items", "list", "results", "data", "plugins"];
  for (let i = 0; i < keys.length; i += 1) {
    const value = payload[keys[i]];
    if (Array.isArray(value)) return value;
    if (value && Array.isArray(value.items)) return value.items;
  }
  return [];
}

function videoItem(raw) {
  if (typeof raw === "string") {
    return { id: raw, type: "url", title: raw, link: raw };
  }
  if (!raw || typeof raw !== "object") return null;
  const type = raw.type || "url";
  const rawId = raw.id != null ? raw.id : raw.link != null ? raw.link : raw.title;
  if (rawId == null || rawId === "") return null;
  const id =
    type === "tmdb" || type === "douban" || type === "imdb" ? rawId : String(rawId);
  const item = {
    id: id,
    type: type,
    mediaType: raw.mediaType || raw.media_type || "tv",
    title: raw.title || raw.name || String(id),
    coverUrl: assetUrl(raw.coverUrl || raw.cover || raw.poster || raw.posterPath || ""),
    posterPath: assetUrl(raw.posterPath || raw.poster || ""),
    backdropPath: assetUrl(raw.backdropPath || raw.backdrop || ""),
    description: raw.description || raw.desc || "",
    rating: raw.rating,
  };
  if (raw.detailPoster) item.detailPoster = assetUrl(raw.detailPoster);
  if (raw.headers && typeof raw.headers === "object") item.headers = raw.headers;
  if (Array.isArray(raw.backdropPaths)) item.backdropPaths = raw.backdropPaths;
  if (Array.isArray(raw.episodeItems)) item.episodeItems = raw.episodeItems;
  if (Array.isArray(raw.episodes)) {
    item.episodeItems = raw.episodes.map(function (e, index) {
      const epId = String(e.id != null ? e.id : index + 1);
      return {
        id: epId,
        type: "url",
        title: e.title || "第" + (e.episode || index + 1) + "集",
        episode: e.episode || index + 1,
        duration: e.duration,
        link: epId,
      };
    });
  }
  if (Array.isArray(raw.relatedItems)) item.relatedItems = raw.relatedItems;
  if (Array.isArray(raw.trailers)) item.trailers = raw.trailers;
  if (Array.isArray(raw.genreItems)) item.genreItems = raw.genreItems;
  if (raw.genreTitle) item.genreTitle = raw.genreTitle;
  if (Array.isArray(raw.peoples)) item.peoples = raw.peoples;
  if (raw.releaseDate) item.releaseDate = raw.releaseDate;
  if (raw.videoUrl) item.videoUrl = raw.videoUrl;
  if (raw.previewUrl) item.previewUrl = raw.previewUrl;
  if (raw.duration != null) item.duration = raw.duration;
  if (raw.durationText) item.durationText = raw.durationText;
  if (raw.episode != null) item.episode = raw.episode;
  if (type === "url" || type === "forward") item.link = raw.link || String(id);
  return item;
}

function videoItems(payload) {
  return rowsOf(payload).map(videoItem).filter(function (item) { return item; });
}

function resourceItems(payload) {
  let rows = rowsOf(payload);
  if (!rows.length && payload && typeof payload === "object" && (payload.url || payload.playUrl)) {
    rows = [payload];
  }
  return rows
    .map(function (raw) {
      if (typeof raw === "string") return { name: "线路", url: raw, playerType: "app" };
      const url = raw.url || raw.playUrl || raw.play_url || raw.videoUrl || "";
      if (!url) return null;
      return {
        name: raw.name || raw.title || "线路",
        description: raw.description || raw.desc || "",
        url: url,
        headers: raw.headers || raw.customHeaders || raw.custom_headers || {},
        playerType: raw.playerType === "system" ? "system" : "app",
      };
    })
    .filter(function (item) { return item; });
}

function subtitleItems(payload) {
  return rowsOf(payload)
    .map(function (raw, index) {
      if (typeof raw === "string") {
        return { id: "sub-" + index, title: "字幕 " + (index + 1), lang: "zh", url: raw };
      }
      return {
        id: String(raw.id || "sub-" + index),
        title: raw.title || raw.name || "字幕 " + (index + 1),
        lang: raw.lang || raw.language || "zh",
        count: raw.count,
        url: raw.url || raw.downloadUrl || raw.download_url || "",
      };
    })
    .filter(function (item) { return item.url; });
}

async function loadList(params = {}) {
  if (!LIST_CAP) return [];
  return videoItems(await call(LIST_CAP, params));
}

async function loadResource(params = {}) {
  if (!DIRECT) {
    const base = serverOf(params);
    if (!base) throw new Error("请先在模块设置中填写 RexHub 服务端地址");
    const query = queryOf(withId(params));
    const res = await Widget.http.get(
      base +
        "/api/v1/plugins/" +
        encode(PLUGIN_ID) +
        "/playback/url" +
        (query ? "?" + query : "")
    );
    const data = res.data || {};
    if (!data.url) return [];
    return [{ name: "线路", url: data.url, playerType: "app" }];
  }
  return resourceItems(await call("playback.stream", withId(params)));
}

async function loadSubtitle(params = {}) {
  if (!SUBTITLE_CAP) return [];
  return subtitleItems(await call(SUBTITLE_CAP, params));
}

async function loadDetail(link) {
  if (!DETAIL_CAP) return null;
  const payload = await call(DETAIL_CAP, { link: link, id: link });
  const data = payload && payload.data && typeof payload.data === "object" ? payload.data : payload;
  const item = videoItem(data);
  if (!item) return null;
  if (item.type === "url" || item.type === "forward") item.link = link;
  return item;
}

async function search(params = {}) {
  if (!HAS_SEARCH) return [];
  return videoItems(await call("resource.search", params));
}

async function searchDanmu(params = {}) {
  if (!ENDPOINTS["danmaku.search"]) return { animes: [] };
  const query = Object.assign({}, params, {
    keyword: params.keyword || params.seriesName || params.title || "",
  });
  const payload = await call("danmaku.search", query);
  const list = payload && Array.isArray(payload.animes) ? payload.animes : rowsOf(payload);
  return {
    animes: list.map(function (raw, index) {
      return {
        animeId: String(raw.bangumiId || raw.animeId || raw.id || index),
        animeTitle: raw.animeTitle || raw.title || raw.name || "",
        type: raw.type || "tv",
      };
    }),
  };
}

async function getDetailById(params = {}) {
  const animeId = params.animeId != null ? String(params.animeId) : "";
  if (!animeId) return [];
  if (!ENDPOINTS["danmaku.detail"]) {
    return [{ episodeId: animeId, episodeTitle: params.seriesName ? String(params.seriesName) : "弹幕" }];
  }
  const payload = await call("danmaku.detail", { animeId: animeId });
  const data = payload && payload.data && typeof payload.data === "object" ? payload.data : payload;
  const list =
    (data && data.bangumi && Array.isArray(data.bangumi.episodes) && data.bangumi.episodes) ||
    (data && Array.isArray(data.episodes) && data.episodes) ||
    rowsOf(data);
  return list.map(function (raw, index) {
    return {
      episodeId: String(raw.episodeId || raw.id || index),
      episodeTitle: raw.episodeTitle || raw.title || raw.name || "",
    };
  });
}

async function getCommentsById(params = {}) {
  if (!ENDPOINTS["danmaku.fetch"]) return { count: 0, comments: [] };
  const payload = await call("danmaku.fetch", params);
  if (payload && payload.comments) return payload;
  return { count: rowsOf(payload).length, comments: rowsOf(payload) };
}

async function getDanmuWithSegmentTime(params = {}) {
  return getCommentsById(
    Object.assign({}, params, {
      time: params.segmentTime != null ? params.segmentTime : params.time,
    })
  );
}
"""
