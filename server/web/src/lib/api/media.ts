/**
 * 影视榜单与详情（只走插件桥 /api/media/*）
 *
 * 数据来自服务端插件（rexhub.tmdb / rexhub.douban / rexhub.bangumi），
 * 统一经 media_bridge 归一化：列表条目 id 形如 `source:native`
 * （tmdb:movie/123、douban:1292052、bgm:326、anilist:12345）。
 * 对外仍导出旧签名 / 旧返回类型，字段映射在 fetch 函数内完成。
 */
import { API_BASE, apiFetch, parseError } from './client';
import type {
  AuthUser,
  BrowseResult,
  FilterSize,
  FilterTime,
  MatchMode,
  ResourceDbConfig,
  ResourceItem,
  SearchResult,
  SortType,
} from '@/types/resource';

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


/* —— Media（插件桥：rexhub.tmdb / douban / bangumi）—— */

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

export type MediaChartResult = {
  source: MediaSourceId;
  category: MediaCategoryId;
  chart: string;
  page: number;
  totalPages: number;
  items: MediaItem[];
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

export type MediaMeta = {
  tmdbConfigured: boolean;
  categories: Array<{ id: MediaCategoryId; label: string }>;
  sources: Array<{
    id: MediaSourceId;
    label: string;
    charts: Array<{ id: string; label: string }>;
  }>;
};

/* —— 桥侧原始形状（media_bridge 归一化产物） —— */

type BridgeMediaItem = {
  id: string;
  mediaType?: string;
  title?: string;
  poster?: string;
  backdrop?: string;
  overview?: string;
  year?: string;
  rating?: number | null;
};

type BridgeCastMember = {
  id?: string;
  name?: string;
  character?: string;
  profile?: string;
};

type BridgeDetail = {
  id?: string;
  mediaType?: string;
  title?: string;
  originalTitle?: string;
  poster?: string;
  backdrop?: string;
  overview?: string;
  year?: string;
  rating?: number | null;
  runtime?: string;
  genres?: string[];
  countries?: string[];
  cast?: string[];
  castPeople?: BridgeCastMember[];
  recommendations?: BridgeMediaItem[];
};

type BridgeCatalog = {
  id: string;
  title?: string;
  mediaType?: string;
  source?: string;
};

/**
 * TMDB 图片路径（`/abc.jpg`）→ 服务端图片代理；已是完整 URL 的（豆瓣图床等）
 * 原样返回，交给 proxiedCoverUrl 走 cover-proxy。
 */
export function mediaImageUrl(path: string | null | undefined, size = 'w500'): string {
  const p = String(path || '').trim();
  if (!p) return '';
  if (p.startsWith('/')) {
    return `${API_BASE}/media/image?path=${encodeURIComponent(p)}&size=${size}`;
  }
  return p;
}

/** 拆桥侧 `source:native` id；`bgm:` 归一为 bangumi，无前缀视为 tmdb。 */
function splitBridgeId(raw: string): { source: MediaSourceId; native: string } {
  const s = String(raw || '').trim();
  const idx = s.indexOf(':');
  const prefix = idx > 0 ? s.slice(0, idx).toLowerCase() : 'tmdb';
  const native = idx > 0 ? s.slice(idx + 1) : s;
  const source: MediaSourceId =
    prefix === 'douban'
      ? 'douban'
      : prefix === 'anilist'
        ? 'anilist'
        : prefix === 'bangumi' || prefix === 'bgm'
          ? 'bangumi'
          : 'tmdb';
  return { source, native };
}

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

function firstYear(value: string | null | undefined): string | null {
  const m = /^(\d{4})/.exec(String(value || '').trim());
  return m ? m[1] : null;
}

/** 桥列表条目 → Web MediaItem（id 拆回裸 id，source 归一） */
function toMediaItem(raw: BridgeMediaItem): MediaItem {
  const { source, native } = splitBridgeId(raw.id);
  let mediaType: 'movie' | 'tv' = raw.mediaType === 'tv' ? 'tv' : 'movie';
  let id = native;
  if (source === 'tmdb') {
    const m = /^(movie|tv)[/:](\d+)$/.exec(native);
    if (m) {
      id = m[2];
      mediaType = m[1] === 'tv' ? 'tv' : 'movie';
    }
  }
  return {
    source,
    id,
    mediaType,
    title: String(raw.title || '').trim() || id,
    originalTitle: null,
    aka: [],
    posterUrl: mediaImageUrl(raw.poster) || null,
    year: firstYear(raw.year),
    rating: raw.rating != null ? Number(raw.rating) : null,
    overview: String(raw.overview || '').trim() || null,
  };
}

const META_CATEGORIES: Array<{ id: MediaCategoryId; label: string }> = [
  { id: 'movie', label: '电影' },
  { id: 'tv', label: '电视剧' },
  { id: 'anime', label: '动漫' },
  { id: 'variety', label: '综艺' },
];

const META_SOURCES: MediaMeta['sources'] = [
  {
    id: 'tmdb',
    label: 'TMDB',
    charts: [
      { id: 'trending', label: '本周趋势' },
      { id: 'now_playing', label: '正在热映' },
      { id: 'upcoming', label: '即将上映' },
      { id: 'popular', label: '热门' },
      { id: 'top_rated', label: '高分' },
      { id: 'on_the_air', label: '播出中' },
    ],
  },
  {
    id: 'douban',
    label: '豆瓣',
    charts: [
      { id: 'hot', label: '热门' },
      { id: 'top250', label: 'Top250' },
      { id: 'new', label: '新片/新剧' },
      { id: 'cn', label: '华语' },
      { id: 'western', label: '欧美' },
      { id: 'jp', label: '日剧' },
      { id: 'kr', label: '韩剧' },
    ],
  },
  {
    id: 'bangumi',
    label: 'Bangumi',
    charts: [
      { id: 'rank', label: '排名' },
      { id: 'heat', label: '热门' },
      { id: 'score', label: '高分' },
      { id: 'calendar', label: '放送表' },
      { id: 'real', label: '三次元' },
    ],
  },
  {
    id: 'anilist',
    label: 'AniList',
    charts: [
      { id: 'trending', label: '趋势' },
      { id: 'popular', label: '热门' },
      { id: 'top_rated', label: '高分' },
      { id: 'airing', label: '放送中' },
      { id: 'upcoming', label: '即将上映' },
      { id: 'movies', label: '剧场版' },
    ],
  },
];

let catalogsPromise: Promise<BridgeCatalog[]> | null = null;

function loadMediaCatalogs(): Promise<BridgeCatalog[]> {
  if (!catalogsPromise) {
    catalogsPromise = (async () => {
      const res = await apiFetch('/media/catalogs');
      if (!res.ok) throw new Error(await parseError(res));
      const data = (await res.json()) as { items?: BridgeCatalog[] };
      return data.items || [];
    })().catch((e) => {
      catalogsPromise = null;
      throw e;
    });
  }
  return catalogsPromise;
}

/** /media/meta 由栏目目录派生：前台只依赖 tmdbConfigured 决定默认数据源。 */
export async function fetchMediaMeta(signal?: AbortSignal): Promise<MediaMeta> {
  const items = await loadMediaCatalogs().catch(() => null);
  void signal;
  const tmdbOk = (items || []).some(
    (c) => c.source === 'tmdb' || String(c.id || '').startsWith('tmdb:'),
  );
  return {
    tmdbConfigured: tmdbOk,
    categories: META_CATEGORIES,
    sources: META_SOURCES,
  };
}

/** tmdb 插件栏目 id 固定（movie-trending…），先走静态映射，其余源按目录动态解析。 */
const TMDB_CHART_CATALOGS: Partial<Record<MediaCategoryId, Record<string, string>>> = {
  movie: {
    trending: 'tmdb:movie-trending',
    now_playing: 'tmdb:movie-theaters',
    upcoming: 'tmdb:movie-upcoming',
    popular: 'tmdb:movie-trending',
    top_rated: 'tmdb:movie-top',
  },
  tv: {
    trending: 'tmdb:tv-trending',
    on_the_air: 'tmdb:tv-airing',
    popular: 'tmdb:tv-trending',
    top_rated: 'tmdb:tv-top',
  },
  anime: {
    popular: 'tmdb:tv-animation',
    top_rated: 'tmdb:tv-animation',
  },
};

function categoryMediaType(category: MediaCategoryId): 'movie' | 'series' {
  return category === 'movie' ? 'movie' : 'series';
}

async function resolveChartCatalog(
  source: MediaSourceId,
  category: MediaCategoryId,
  chart: string,
): Promise<string> {
  const fixed = TMDB_CHART_CATALOGS[category]?.[chart];
  if (source === 'tmdb' && fixed) return fixed;
  const catalogs = await loadMediaCatalogs();
  const ofSource = catalogs.filter((c) => c.source === source);
  if (ofSource.length === 0) throw new Error('该数据源暂无可用栏目');
  const want = categoryMediaType(category);
  const typed = ofSource.filter((c) => c.mediaType === want);
  const pool = typed.length > 0 ? typed : ofSource;
  const byChart = pool.find(
    (c) => c.id === chart || c.id.endsWith(`-${chart}`) || c.id.endsWith(`_${chart}`),
  );
  return (byChart || pool[0]).id;
}

export async function fetchMediaCharts(opts: {
  source: MediaSourceId;
  category: MediaCategoryId;
  chart: string;
  page?: number;
  signal?: AbortSignal;
}): Promise<MediaChartResult> {
  const catalog = await resolveChartCatalog(opts.source, opts.category, opts.chart);
  const q = new URLSearchParams({ catalog });
  if (opts.page != null) q.set('page', String(opts.page));
  const res = await apiFetch(`/media/list?${q}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as {
    hasMore?: boolean;
    items?: BridgeMediaItem[];
  };
  const page = opts.page != null ? opts.page : 1;
  return {
    source: opts.source,
    category: opts.category,
    chart: opts.chart,
    page,
    totalPages: data.hasMore ? page + 1 : Math.max(1, page),
    items: (data.items || []).map(toMediaItem),
  };
}

export type MediaGenre = { id: number; name: string };

export type MediaDiscoverSort =
  | 'popularity.desc'
  | 'vote_average.desc'
  | 'primary_release_date.desc'
  | 'first_air_date.desc'
  | 'revenue.desc'
  | 'vote_count.desc';

export type MediaDiscoverResult = {
  source: 'tmdb';
  mediaType: 'movie' | 'tv';
  genre?: string | null;
  sortBy: string;
  year?: string | null;
  page: number;
  totalPages: number;
  totalResults?: number;
  items: MediaItem[];
};

export async function fetchMediaGenres(opts: {
  mediaType: 'movie' | 'tv';
  signal?: AbortSignal;
}): Promise<MediaGenre[]> {
  const res = await apiFetch('/media/genres?source=tmdb', { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as {
    movie?: MediaGenre[];
    series?: MediaGenre[];
  };
  const rows = opts.mediaType === 'tv' ? data.series : data.movie;
  return (rows || []).map((g) => ({
    id: Number(g.id),
    name: String(g.name || ''),
  }));
}

export async function fetchMediaDiscover(opts: {
  mediaType: 'movie' | 'tv';
  genre?: string;
  sortBy?: string;
  year?: string;
  page?: number;
  signal?: AbortSignal;
}): Promise<MediaDiscoverResult> {
  const q = new URLSearchParams();
  q.set('mediaType', opts.mediaType);
  if (opts.genre) q.set('genre', opts.genre);
  if (opts.sortBy) q.set('sortBy', opts.sortBy);
  if (opts.year) q.set('year', opts.year);
  if (opts.page != null) q.set('page', String(opts.page));
  const res = await apiFetch(`/media/discover?${q}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as {
    hasMore?: boolean;
    items?: BridgeMediaItem[];
  };
  const page = opts.page != null ? opts.page : 1;
  return {
    source: 'tmdb',
    mediaType: opts.mediaType,
    genre: opts.genre || null,
    sortBy: opts.sortBy || 'popularity.desc',
    year: opts.year || null,
    page,
    totalPages: data.hasMore ? page + 1 : 1,
    items: (data.items || []).map(toMediaItem),
  };
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

/** 插件可能返回「2 小时 32 分钟」「2h 32m」「152 分钟」等格式 */
function parseRuntimeMinutes(value: unknown): number | null {
  const text = String(value ?? '').trim();
  if (!text) return null;
  const hours = /(\d+)\s*(?:小时|h\b)/i.exec(text);
  const minutes = /(\d+)\s*(?:分钟|min\b|m\b)/i.exec(text);
  if (hours || minutes) {
    return (hours ? Number(hours[1]) * 60 : 0) + (minutes ? Number(minutes[1]) : 0);
  }
  const plain = /\d+/.exec(text);
  return plain ? Number(plain[0]) : null;
}

function detailToMediaItem(
  source: MediaSourceId,
  id: string,
  mediaType: 'movie' | 'tv' | undefined,
  d: BridgeDetail,
): MediaItem {
  const castPeople = Array.isArray(d.castPeople) ? d.castPeople : [];
  const castNames = Array.isArray(d.cast) ? d.cast : [];
  const cast: Array<MediaCastPerson | string> =
    castPeople.length > 0
      ? castPeople
          .filter((p) => String(p.name || '').trim())
          .map((p) => ({
            id: p.id ? String(p.id) : null,
            name: String(p.name || '').trim(),
            avatarUrl: mediaImageUrl(p.profile) || null,
          }))
      : castNames.map((n) => String(n || '').trim()).filter(Boolean);
  const runtime = parseRuntimeMinutes(d.runtime);
  return {
    source,
    id,
    mediaType: mediaType || (d.mediaType === 'tv' ? 'tv' : 'movie'),
    title: String(d.title || '').trim(),
    originalTitle: String(d.originalTitle || '').trim() || null,
    aka: [],
    posterUrl: mediaImageUrl(d.poster) || null,
    year: firstYear(d.year),
    rating: d.rating != null ? Number(d.rating) : null,
    overview: String(d.overview || '').trim() || null,
    cast,
    genres: (d.genres || []).map((g) => String(g || '').trim()).filter(Boolean).slice(0, 12),
    runtime,
    countries: (d.countries || [])
      .map((c) => String(c || '').trim())
      .filter(Boolean)
      .slice(0, 8),
  };
}

/** 详情短缓存：详情页会在同一帧内取详情 + 相关推荐，共用一次请求。 */
const DETAIL_CACHE_TTL = 10_000;
const detailCache = new Map<string, { at: number; data: BridgeDetail }>();

async function fetchBridgeDetail(opts: {
  source: MediaSourceId;
  id: string;
  mediaType?: 'movie' | 'tv';
  signal?: AbortSignal;
}): Promise<BridgeDetail> {
  const key = toBridgeMediaId(opts.source, opts.id, opts.mediaType);
  const now = Date.now();
  const hit = detailCache.get(key);
  if (hit && now - hit.at < DETAIL_CACHE_TTL) return hit.data;
  const q = new URLSearchParams({ id: key });
  const res = await apiFetch(`/media/detail?${q}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as BridgeDetail;
  if (!opts.signal?.aborted) {
    if (detailCache.size > 64) {
      const oldest = detailCache.keys().next().value;
      if (oldest != null) detailCache.delete(oldest);
    }
    detailCache.set(key, { at: Date.now(), data });
  }
  return data;
}

export async function fetchMediaDetail(opts: {
  source: MediaSourceId;
  id: string;
  mediaType?: 'movie' | 'tv';
  signal?: AbortSignal;
}): Promise<MediaItem> {
  const data = await fetchBridgeDetail(opts);
  return detailToMediaItem(opts.source, opts.id, opts.mediaType, data);
}

export async function fetchMediaRelated(opts: {
  source: MediaSourceId;
  mediaType: 'movie' | 'tv';
  id: string;
  signal?: AbortSignal;
}): Promise<MediaRelatedResult> {
  // 桥没有独立 related 端点：详情里的 recommendations 即相关推荐。
  const data = await fetchBridgeDetail(opts);
  return {
    similar: [],
    recommendations: (data.recommendations || []).map(toMediaItem),
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

/** 聚合已启用 Stremio 插件的片源；剧集默认取第 1 季第 1 集。 */
export async function fetchMediaStreams(opts: {
  id: string;
  imdbId?: string | null;
  mediaType?: 'movie' | 'tv';
  season?: number;
  episode?: number;
  signal?: AbortSignal;
}): Promise<MediaStreamsResult> {
  const params = new URLSearchParams();
  params.set('id', opts.id);
  if (opts.imdbId) params.set('imdb', opts.imdbId);
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
  const params = new URLSearchParams();
  params.set('title', opts.title);
  if (opts.year) params.set('year', opts.year);
  params.set('mediaType', opts.mediaType === 'tv' ? 'tv' : 'movie');
  if (opts.season && opts.season > 0) params.set('season', String(opts.season));
  if (opts.episode && opts.episode > 0) params.set('episode', String(opts.episode));
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
