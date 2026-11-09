/**
 * 影视搜索 / 详情 / 片源 / 字幕（MoviePilot + Stremio addon + MorePlay）
 *
 * 榜单与详情统一走 MoviePilot 原生接口；片源与字幕聚合已启用的 Stremio 插件。
 */
import { API_BASE, apiFetch, parseError } from './client';

export function proxiedCoverUrl(
  url: string | null | undefined,
  opts?: { w?: number; rp?: boolean },
): string {
  let s = String(url || "").trim();
  if (!s) return "";
  // 协议相对地址
  if (s.startsWith("//")) s = `https:${s}`;
  const w =
    typeof opts?.w === "number" && opts.w >= 32 && opts.w <= 1280
      ? Math.round(opts.w)
      : 0;
  const appendParams = (base: string) => {
    let out = base;
    if (w && !/[?&]w=\d+/.test(out)) {
      out = out.includes("?") ? `${out}&w=${w}` : `${out}?w=${w}`;
    }
    if (
      typeof opts?.rp === "boolean" &&
      w > 0 &&
      !/[?&]rp=/.test(out)
    ) {
      out = `${out}${out.includes("?") ? "&" : "?"}rp=${opts.rp ? 1 : 0}`;
    }
    return out;
  };
  if (s.includes("/cover-proxy?")) {
    return appendParams(s);
  }
  // 外站相对路径不应拼到 /api；仅本站 /api|/covers 等保留
  if (s.startsWith("/")) {
    if (s.startsWith(`${API_BASE}/`) || s === API_BASE) {
      return appendParams(s);
    }
    // /pics/... 这类外站相对路径无法代理
    if (
      s.startsWith("/api/") ||
      s.startsWith("/covers/") ||
      s.startsWith("/brand/")
    ) {
      const joined = `${API_BASE}${s.startsWith("/api/") ? s.slice(4) : s}`;
      return appendParams(joined);
    }
    return "";
  }
  if (!/^https?:\/\//i.test(s)) return s;
  const base = `${API_BASE}/media/cover-proxy?url=${encodeURIComponent(s)}`;
  return w ? `${base}&w=${w}` : base;
}


/* —— Media 基础类型 —— */

export type MediaSourceId = 'tmdb' | 'douban' | 'bangumi' | 'anilist';
export type MediaCategoryId = 'movie' | 'tv' | 'anime' | 'variety';

export type MediaCastPerson = {
  id?: string | null;
  name: string;
  avatarUrl?: string | null;
};

export type MediaItem = {
  source: MediaSourceId;
  id: string;
  mediaType: 'movie' | 'tv';
  title: string;
  originalTitle?: string | null;
  aka: string[];
  posterUrl?: string | null;
  year?: string | null;
  rating?: number | null;
  overview?: string | null;
  cast?: Array<MediaCastPerson | string>;
  genres?: string[];
  runtime?: number | null;
  countries?: string[];
  /** 详情接口带回的 IMDb 编号（tt…），PT 站点搜索可选按它精确匹配 */
  imdbId?: string | null;
};

export type MediaSearchResult = {
  source: MediaSourceId;
  query: string;
  /** 服务端拆分后的片名列表（多片名逐条搜再合并） */
  terms?: string[];
  page: number;
  /** MoviePilot 搜索不返回总页数，以 hasMore 为准 */
  hasMore?: boolean;
  totalPages: number;
  items: MediaItem[];
};

export type MediaRelatedResult = {
  similar: MediaItem[];
  recommendations: MediaItem[];
};

/* —— MoviePilot id 映射 —— */

/** Web 侧裸 id → 桥 id `source:native`；已带前缀的原样透传。 */
export function toBridgeMediaId(
  source: MediaSourceId,
  id: string,
  mediaType?: 'movie' | 'tv',
): string {
  const raw = String(id || '').trim();
  if (!raw) return '';
  if (raw.includes(':')) return raw;
  if (source === 'douban') return `douban:${raw}`;
  if (source === 'bangumi') return `bgm:${raw}`;
  if (source === 'anilist') return `anilist:${raw}`;
  return `tmdb:${mediaType === 'tv' ? 'tv' : 'movie'}/${raw}`;
}

/** 影视搜索：走 MoviePilot 原生媒体搜索（不再经插件桥） */
export async function fetchMpMediaSearch(opts: {
  source: MediaSourceId;
  q: string;
  page?: number;
  signal?: AbortSignal;
}): Promise<MediaSearchResult> {
  const page = opts.page != null ? opts.page : 1;
  const params = new URLSearchParams({
    source: opts.source,
    keyword: opts.q,
    page: String(page),
  });
  const res = await apiFetch(`/moviepilot/media-search?${params}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as {
    data?: {
      source?: MediaSourceId;
      page?: number;
      hasMore?: boolean;
      items?: MediaItem[];
    };
  };
  const data = json.data || {};
  return {
    source: data.source || opts.source,
    query: opts.q,
    terms: [opts.q],
    page: Number(data.page || page),
    hasMore: Boolean(data.hasMore),
    totalPages: data.hasMore ? page + 1 : page,
    items: (data.items || []).map((raw) => ({
      ...raw,
      aka: Array.isArray(raw.aka) ? raw.aka : [],
    })),
  };
}

/* —— Stremio 片源（网页播放）—— */

export type MediaStream = {
  addon: string;
  addonSlug: string;
  name: string;
  title: string;
  url: string;
  externalUrl: string;
  infoHash: string;
  fileIdx: number | null;
  filename: string;
  size: number | null;
  kind: 'direct' | 'external' | 'torrent' | string;
  playable: boolean;
};

export type MediaStreamsResult = {
  streams: MediaStream[];
  total: number;
  addons: number;
  reason: string;
};

/** 聚合影视类插件与已启用 Stremio 插件的片源；剧集默认取第 1 季第 1 集。 */
export async function fetchMediaStreams(opts: {
  id: string;
  imdbId?: string | null;
  mediaType?: 'movie' | 'tv';
  season?: number;
  episode?: number;
  title?: string;
  signal?: AbortSignal;
}): Promise<MediaStreamsResult> {
  const params = new URLSearchParams();
  params.set('id', opts.id);
  if (opts.imdbId) params.set('imdb', opts.imdbId);
  if (opts.title) params.set('title', opts.title);
  if (opts.mediaType) {
    params.set('mediaType', opts.mediaType === 'tv' ? 'series' : 'movie');
  }
  if (opts.season && opts.season > 0) params.set('season', String(opts.season));
  if (opts.episode && opts.episode > 0) params.set('episode', String(opts.episode));
  const res = await apiFetch(`/media/streams?${params}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as Partial<MediaStreamsResult>;
  return {
    streams: Array.isArray(data.streams) ? data.streams : [],
    total: Number(data.total || 0),
    addons: Number(data.addons || 0),
    reason: String(data.reason || ''),
  };
}

/** 视频直链走同源代理，透传 Range 以便拖动进度条。 */
export function mediaStreamProxyUrl(url: string): string {
  return `${API_BASE}/media/stream-proxy?url=${encodeURIComponent(url)}`;
}

/** MorePlay 猫源片源：按片名搜索，返回可直接播放的网盘原画线路。 */
export async function fetchMoreplayStreams(opts: {
  title: string;
  year?: string | null;
  mediaType?: 'movie' | 'tv';
  season?: number;
  episode?: number;
  signal?: AbortSignal;
}): Promise<MediaStreamsResult> {
  const params = moreplayParams(opts);
  const res = await apiFetch(`/media/moreplay/streams?${params}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as Partial<MediaStreamsResult>;
  return {
    streams: Array.isArray(data.streams) ? data.streams : [],
    total: Number(data.total || 0),
    addons: Number(data.addons || 0),
    reason: String(data.reason || ''),
  };
}

function moreplayParams(opts: {
  title: string;
  year?: string | null;
  mediaType?: 'movie' | 'tv';
  season?: number;
  episode?: number;
}): URLSearchParams {
  const params = new URLSearchParams();
  params.set('title', opts.title);
  if (opts.year) params.set('year', opts.year);
  params.set('mediaType', opts.mediaType === 'tv' ? 'tv' : 'movie');
  if (opts.season && opts.season > 0) params.set('season', String(opts.season));
  if (opts.episode && opts.episode > 0) params.set('episode', String(opts.episode));
  return params;
}

export type MoreplayLiveEvent =
  | { type: 'site'; site: string; siteId: string; streams: MediaStream[] }
  | { type: 'done'; reason?: string; tried?: string[] };

/**
 * 猫源流式搜索：每命中一个站点就回调一次，先到的先展示。
 * 传入的 signal abort 后请求随即中断，服务端也会停止剩余站点的搜索。
 */
export async function streamMoreplayStreams(
  opts: {
    title: string;
    year?: string | null;
    mediaType?: 'movie' | 'tv';
    season?: number;
    episode?: number;
    signal?: AbortSignal;
  },
  handlers: {
    onSite: (site: string, streams: MediaStream[]) => void;
    onDone: (reason: string) => void;
  },
): Promise<void> {
  const res = await apiFetch(`/media/moreplay/streams/live?${moreplayParams(opts)}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  if (!res.body) throw new Error('当前浏览器不支持流式片源');
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let index = buffer.indexOf('\n');
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        index = buffer.indexOf('\n');
        if (!line) continue;
        let event: MoreplayLiveEvent;
        try {
          event = JSON.parse(line) as MoreplayLiveEvent;
        } catch {
          continue;
        }
        if (event.type === 'site') {
          handlers.onSite(event.site, Array.isArray(event.streams) ? event.streams : []);
        } else if (event.type === 'done') {
          handlers.onDone(event.reason || '');
        }
      }
    }
  } finally {
    void reader.cancel().catch(() => {});
  }
}

export type MediaSubtitle = {
  addon: string;
  addonSlug: string;
  id: string;
  url: string;
  lang: string;
  label: string;
};

export type MediaSubtitlesResult = {
  subtitles: MediaSubtitle[];
  total: number;
  reason: string;
};

/** 聚合已启用字幕插件的字幕；返回的是上游字幕地址，播放时走字幕代理。 */
export async function fetchMediaSubtitles(opts: {
  id: string;
  imdbId?: string | null;
  mediaType?: 'movie' | 'tv' | 'series';
  season?: number;
  episode?: number;
  signal?: AbortSignal;
}): Promise<MediaSubtitlesResult> {
  const params = new URLSearchParams();
  params.set('id', opts.id);
  if (opts.imdbId) params.set('imdb', opts.imdbId);
  if (opts.mediaType) {
    params.set('mediaType', opts.mediaType === 'tv' ? 'series' : opts.mediaType);
  }
  if (opts.season && opts.season > 0) params.set('season', String(opts.season));
  if (opts.episode && opts.episode > 0) params.set('episode', String(opts.episode));
  const res = await apiFetch(`/media/subtitles?${params}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as Partial<MediaSubtitlesResult>;
  return {
    subtitles: Array.isArray(data.subtitles) ? data.subtitles : [],
    total: Number(data.total || 0),
    reason: String(data.reason || ''),
  };
}

/** 字幕代理：SRT → WebVTT，浏览器 <track> 才能加载。 */
export function mediaSubtitleProxyUrl(url: string): string {
  return `${API_BASE}/media/subtitle-proxy?url=${encodeURIComponent(url)}`;
}

/* —— MoviePilot 影人（详情 + 作品，取代插件桥 /media/person/works）—— */

export type MpPerson = {
  source: MediaSourceId;
  id: string;
  name: string;
  originalName?: string | null;
  avatarUrl?: string | null;
  birthday?: string | null;
  deathday?: string | null;
  placeOfBirth?: string | null;
  gender?: string | null;
  department?: string | null;
  aliases: string[];
  biography?: string | null;
  imdbId?: string | null;
};

export async function fetchMpPerson(opts: {
  source: MediaSourceId;
  id: string;
  signal?: AbortSignal;
}): Promise<MpPerson> {
  const params = new URLSearchParams({ source: opts.source, id: opts.id });
  const res = await apiFetch(`/moviepilot/person?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as { data?: Partial<MpPerson> };
  const data = json.data || {};
  return {
    source: (data.source as MediaSourceId) || opts.source,
    id: String(data.id || opts.id),
    name: String(data.name || ''),
    originalName: data.originalName || null,
    avatarUrl: data.avatarUrl || null,
    birthday: data.birthday || null,
    deathday: data.deathday || null,
    placeOfBirth: data.placeOfBirth || null,
    gender: data.gender || null,
    department: data.department || null,
    aliases: Array.isArray(data.aliases) ? data.aliases : [],
    biography: data.biography || null,
    imdbId: data.imdbId || null,
  };
}

export type MpPersonWorksPage = {
  personId: string;
  page: number;
  items: MediaItem[];
  hasMore: boolean;
};

export async function fetchMpPersonWorks(opts: {
  source: MediaSourceId;
  id: string;
  page?: number;
  signal?: AbortSignal;
}): Promise<MpPersonWorksPage> {
  const params = new URLSearchParams({
    source: opts.source,
    id: opts.id,
    page: String(opts.page || 1),
  });
  const res = await apiFetch(`/moviepilot/person/credits?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as {
    data?: {
      personId?: string;
      page?: number;
      items?: MediaItem[];
      hasMore?: boolean;
    };
  };
  const data = json.data;
  return {
    personId: String(data?.personId || opts.id),
    page: Number(data?.page || opts.page || 1),
    items: (data?.items || []).map((raw) => ({
      ...raw,
      aka: Array.isArray(raw.aka) ? raw.aka : [],
    })),
    hasMore: Boolean(data?.hasMore),
  };
}



/* —— MoviePilot 推荐 / 探索（服务端已归一为 MediaItem）—— */

export type MpListParams = Record<string, string | number | undefined | null>;

export type MpListResult = {
  path: string;
  items: MediaItem[];
  total: number;
};

/** 代理 MoviePilot 的 recommend/*、discover/*、anilist/* 列表 */
export async function fetchMpList(opts: {
  path: string;
  params?: MpListParams;
  signal?: AbortSignal;
}): Promise<MpListResult> {
  const params = new URLSearchParams({ path: opts.path });
  for (const [key, value] of Object.entries(opts.params || {})) {
    if (value === undefined || value === null || String(value) === '') continue;
    params.set(key, String(value));
  }
  const res = await apiFetch(`/moviepilot/list?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as {
    data?: { path?: string; items?: MediaItem[]; total?: number };
  };
  const data = json.data;
  return {
    path: String(data?.path || opts.path),
    items: (data?.items || []).map((raw) => ({
      ...raw,
      aka: Array.isArray(raw.aka) ? raw.aka : [],
    })),
    total: Number(data?.total || 0),
  };
}

/* —— MoviePilot 详情 / 详情页相关推荐 —— */

/** 详情：MoviePilot /media/{id}，含演员、时长、类型与地区 */
export async function fetchMpDetail(opts: {
  source: MediaSourceId;
  id: string;
  mediaType?: 'movie' | 'tv';
  signal?: AbortSignal;
}): Promise<MediaItem> {
  const params = new URLSearchParams({ source: opts.source, id: opts.id });
  params.set('mediaType', opts.mediaType || 'movie');
  const res = await apiFetch(`/moviepilot/detail?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as { data?: MediaItem };
  const raw = json.data;
  if (!raw || !String(raw.title || '').trim()) {
    throw new Error('未找到该条目详情');
  }
  return {
    ...raw,
    mediaType: raw.mediaType === 'tv' ? 'tv' : 'movie',
    aka: Array.isArray(raw.aka) ? raw.aka : [],
    cast: Array.isArray(raw.cast) ? raw.cast : [],
    genres: Array.isArray(raw.genres) ? raw.genres : [],
    countries: Array.isArray(raw.countries) ? raw.countries : [],
  };
}

/** 详情页相关推荐：MoviePilot tmdb|douban|bangumi|anilist 的 recommend/similar */
export async function fetchMpRelated(opts: {
  source: MediaSourceId;
  id: string;
  mediaType: 'movie' | 'tv';
  signal?: AbortSignal;
}): Promise<MediaRelatedResult> {
  const params = new URLSearchParams({
    source: opts.source,
    id: opts.id,
    mediaType: opts.mediaType,
  });
  const res = await apiFetch(`/moviepilot/related?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as {
    data?: { similar?: MediaItem[]; recommendations?: MediaItem[] };
  };
  const clean = (rows?: MediaItem[]) =>
    (rows || []).map((raw) => ({
      ...raw,
      aka: Array.isArray(raw.aka) ? raw.aka : [],
    }));
  return {
    similar: clean(json.data?.similar),
    recommendations: clean(json.data?.recommendations),
  };
}

/* —— MoviePilot PT 站点搜索 —— */

export type MpTorrentItem = {
  site: string;
  /** 跨站点合并后的全部站点（含 site） */
  sites?: string[];
  title: string;
  description?: string | null;
  category?: string | null;
  size: number | null;
  seeders: number;
  peers: number;
  grabs: number;
  pubdate?: string | null;
  dateElapsed?: string | null;
  volumeFactor?: string | null;
  /** 以下来自 MP meta_info，与资源筛选条一一对应 */
  seasonEpisode?: string | null;
  releaseGroup?: string | null;
  webSource?: string | null;
  edition?: string | null;
  resolution?: string | null;
  videoCode?: string | null;
  downloadVolumeFactor?: number | null;
  hitAndRun: boolean;
  labels: string[];
  pageUrl?: string | null;
  downloadUrl?: string | null;
  /** 服务端下载令牌：提交下载时回传，换取原始 torrent_info */
  downloadKey?: string | null;
};

export type MpSearchMode = 'title' | 'imdbid';

export type MpSearchResult = {
  keyword: string;
  /** 本次实际使用的搜索方式（MoviePilot 侧逻辑） */
  mode: MpSearchMode;
  page: number;
  items: MpTorrentItem[];
  total: number;
};

/**
 * PT 站点搜索，对齐 MoviePilot 自己的资源搜索：
 * - title：/search/title?keyword=
 * - imdbid：/search/media/{id}?media_source=&mtype=&area=imdbid
 */
export async function fetchMpSearch(opts: {
  keyword?: string;
  page?: number;
  source?: MediaSourceId;
  id?: string;
  mediaType?: 'movie' | 'tv';
  area?: MpSearchMode;
  signal?: AbortSignal;
}): Promise<MpSearchResult> {
  const params = new URLSearchParams();
  if (opts.keyword) params.set('keyword', opts.keyword);
  params.set('page', String(opts.page || 1));
  if (opts.source) params.set('source', opts.source);
  if (opts.id) params.set('id', opts.id);
  if (opts.mediaType) params.set('mediaType', opts.mediaType);
  params.set('area', opts.area || 'title');
  const res = await apiFetch(`/moviepilot/search?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as {
    data?: {
      keyword?: string;
      mode?: string;
      page?: number;
      items?: MpTorrentItem[];
      total?: number;
    };
  };
  const data = json.data;
  return {
    keyword: String(data?.keyword || opts.keyword || ''),
    mode: data?.mode === 'imdbid' ? 'imdbid' : 'title',
    page: Number(data?.page || opts.page || 1),
    items: (data?.items || []).map((raw) => ({
      ...raw,
      labels: Array.isArray(raw.labels) ? raw.labels : [],
    })),
    total: Number(data?.total || 0),
  };
}

export type MpDownloadTask = {
  /** 下载器任务 hash（可能为空，此时轮询会退回标题匹配） */
  downloadId: string;
  title: string;
  site: string;
};

/** 把 PT 搜索结果提交到 MoviePilot 下载器 */
export async function submitMpDownload(opts: {
  key: string;
  source?: MediaSourceId;
  mediaId?: string;
  mediaType?: 'movie' | 'tv';
  title?: string;
  originalTitle?: string | null;
  year?: string | null;
  posterUrl?: string | null;
}): Promise<MpDownloadTask> {
  const res = await apiFetch('/moviepilot/download', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      key: opts.key,
      source: opts.source || '',
      mediaId: opts.mediaId || '',
      mediaType: opts.mediaType || '',
      title: opts.title || '',
      originalTitle: opts.originalTitle || '',
      year: opts.year || '',
      posterUrl: opts.posterUrl || '',
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as { data?: Partial<MpDownloadTask> };
  return {
    downloadId: String(json.data?.downloadId || ''),
    title: String(json.data?.title || opts.title || ''),
    site: String(json.data?.site || ''),
  };
}

export type MpDownloadStatus = {
  found: boolean;
  hash?: string | null;
  title?: string | null;
  state?: string | null;
  progress: number;
  dlspeed?: string | null;
  leftTime?: string | null;
};

/** 轮询下载器里是否已出现该任务 */
export async function fetchMpDownloadStatus(opts: {
  downloadId?: string;
  title?: string;
  signal?: AbortSignal;
}): Promise<MpDownloadStatus> {
  const params = new URLSearchParams();
  if (opts.downloadId) params.set('downloadId', opts.downloadId);
  if (opts.title) params.set('title', opts.title);
  const res = await apiFetch(`/moviepilot/download/status?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as {
    data?: {
      found?: boolean;
      hash?: string | null;
      title?: string | null;
      state?: string | null;
      progress?: number;
      dlspeed?: string | null;
      leftTime?: string | null;
    };
  };
  const data = json.data;
  return {
    found: Boolean(data?.found),
    hash: data?.hash ?? null,
    title: data?.title ?? null,
    state: data?.state ?? null,
    progress: Number(data?.progress || 0),
    dlspeed: data?.dlspeed ?? null,
    leftTime: data?.leftTime ?? null,
  };
}
