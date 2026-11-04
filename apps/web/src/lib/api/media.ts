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
  if (
    s.startsWith(`${API_BASE}/cover-proxy?`) ||
    s.includes("/cover-proxy?")
  ) {
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
  const base = `${API_BASE}/cover-proxy?url=${encodeURIComponent(s)}`;
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

export async function fetchMediaSearch(opts: {
  source: MediaSourceId;
  q: string;
  page?: number;
  signal?: AbortSignal;
}): Promise<MediaSearchResult> {
  const params = new URLSearchParams();
  params.set('source', opts.source);
  params.set('q', opts.q);
  if (opts.page != null) params.set('page', String(opts.page));
  const res = await apiFetch(`/media/search?${params}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as {
    hasMore?: boolean;
    items?: BridgeMediaItem[];
  };
  const page = opts.page != null ? opts.page : 1;
  return {
    source: opts.source,
    query: opts.q,
    terms: [opts.q],
    page,
    totalPages: data.hasMore ? page + 1 : 1,
    items: (data.items || []).map(toMediaItem),
  };
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
  const runtimeMatch = /\d+/.exec(String(d.runtime || ''));
  return {
    source,
    id,
    mediaType: mediaType || (d.mediaType === 'tv' ? 'tv' : 'movie'),
    title: String(d.title || '').trim(),
    originalTitle: null,
    aka: [],
    posterUrl: mediaImageUrl(d.poster) || null,
    year: firstYear(d.year),
    rating: d.rating != null ? Number(d.rating) : null,
    overview: String(d.overview || '').trim() || null,
    cast,
    genres: (d.genres || []).map((g) => String(g || '').trim()).filter(Boolean).slice(0, 12),
    runtime: runtimeMatch ? Number(runtimeMatch[0]) : null,
    countries: (d.countries || [])
      .map((c) => String(c || '').trim())
      .filter(Boolean)
      .slice(0, 8),
  };
}

export async function fetchMediaDetail(opts: {
  source: MediaSourceId;
  id: string;
  mediaType?: 'movie' | 'tv';
  signal?: AbortSignal;
}): Promise<MediaItem> {
  const q = new URLSearchParams({
    id: toBridgeMediaId(opts.source, opts.id, opts.mediaType),
  });
  const res = await apiFetch(`/media/detail?${q}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as BridgeDetail;
  return detailToMediaItem(opts.source, opts.id, opts.mediaType, data);
}

export async function fetchMediaRelated(opts: {
  source: MediaSourceId;
  mediaType: 'movie' | 'tv';
  id: string;
  signal?: AbortSignal;
}): Promise<MediaRelatedResult> {
  // 桥没有独立 related 端点：详情里的 recommendations 即相关推荐。
  const q = new URLSearchParams({
    id: toBridgeMediaId(opts.source, opts.id, opts.mediaType),
  });
  const res = await apiFetch(`/media/detail?${q}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as BridgeDetail;
  return {
    similar: [],
    recommendations: (data.recommendations || []).map(toMediaItem),
  };
}

export type MediaPersonWorksResult = {
  source: MediaSourceId;
  personId: string;
  name: string;
  items: MediaItem[];
};

export async function fetchMediaPersonWorks(opts: {
  source: MediaSourceId;
  q: string;
  personId?: string;
  signal?: AbortSignal;
}): Promise<MediaPersonWorksResult> {
  const params = new URLSearchParams();
  const pid = String(opts.personId || '').trim();
  if (pid) {
    // 详情 castPeople 已带 `tmdb:person/456` 前缀；裸数字按 tmdb 兜底
    params.set('id', pid.includes(':') ? pid : `tmdb:person/${pid}`);
  }
  if (opts.q) params.set('q', opts.q);
  const res = await apiFetch(`/media/person/works?${params}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as {
    personId?: string;
    name?: string;
    items?: BridgeMediaItem[];
  };
  return {
    source: opts.source,
    personId: String(data.personId || pid || ''),
    name: String(data.name || opts.q || ''),
    items: (data.items || []).map(toMediaItem),
  };
}

