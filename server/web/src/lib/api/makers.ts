/**
 * 片商（AVDB）：榜单 / 片商搜索 / 影片 / 磁力代理。
 */
import { apiFetch, parseError } from './client';
import type { MediaStream } from './media';

/** AVDB 榜单类别：0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫 */
export type MakerCategoryId = '0' | '1' | '2' | '3' | '4';

/** AVDB 榜单周期 */
export type MakerPeriod = 'daily' | 'weekly' | 'monthly';

/** 最新排序：update 更新时间 / release 发行日期 */
export type MakerLatestSort = 'update' | 'release';

/** 可播放榜筛选：all 热播 / high_score 热门（AVDB 官方「热门」tab） */
export type MakerPlaybackFilter = 'all' | 'high_score';

/** 最新筛选：all 全部 / magnets 含磁链 / subtitle 含字幕 */
export type MakerLatestFilter = 'all' | 'magnets' | 'subtitle';

/** 影片搜索筛选：all 全部 / subtitle 中文字幕 / magnets 有磁力 / playable 可播放 */
export type MakerMovieSearchFilter =
  | 'all'
  | 'subtitle'
  | 'magnets'
  | 'playable';

export type MakerRankPage = {
  category: MakerCategoryId;
  categoryLabel: string;
  period: MakerPeriod;
  periodLabel: string;
  /** 该类别在 AVDB 是否有独立榜单（动漫无） */
  supported?: boolean;
  items: MakerMovie[];
};

export type MakerHit = {
  id: string;
  name: string;
  videosCount: number;
};

/** AVDB 站内搜索类型：片商 / 演员 / 片单 / 系列 / 导演 / 番号前缀 */
export type MakerSearchType =
  | 'maker'
  | 'actor'
  | 'list'
  | 'series'
  | 'director'
  | 'code';

/** 站内搜索结果项（统一形状，kind 决定点击后跳哪里） */
export type MakerSearchItem = {
  id: string;
  name: string;
  kind: MakerSearchType;
  count: number;
  avatarUrl?: string;
};

export type MakerActor = {
  id: string;
  name: string;
  avatarUrl: string | null;
  videosCount: number;
};

export type MakerReview = {
  id: string;
  username: string;
  content: string;
  score: number;
  likesCount: number;
  createdAt: string | null;
  statusTitle?: string | null;
};

export type MakerHotReview = MakerReview & {
  movie: {
    id: string;
    number: string;
    title: string;
    score: number | string | null;
    thumbUrl: string | null;
    releaseDate: string | null;
  };
};

export type MakerMovie = {
  id: string;
  number: string;
  title: string;
  coverUrl: string | null;
  thumbUrl: string | null;
  /** 横版预览图（第一张 sample 缩略图） */
  previewUrl: string | null;
  releaseDate: string | null;
  duration: number;
  magnetsCount: number;
  hasCnsub: boolean;
};

export type MakerMoviePage = {
  category?: MakerCategoryId;
  categoryLabel?: string;
  period?: MakerPeriod;
  periodLabel?: string;
  startRank?: number;
  supported?: boolean;
  /** kind=top：年份榜（留空为按类别榜） */
  year?: string;
  sortBy?: MakerLatestSort;
  filterBy?: MakerPlaybackFilter | MakerLatestFilter;
  filterLabel?: string;
  maker?: string;
  makerId?: string | null;
  group?: string;
  tagId?: string;
  page: number;
  items: MakerMovie[];
  hasMore: boolean;
};

export type MakerTag = {
  id: string;
  name: string;
};

export type MakerTagCategory = {
  id: string;
  name: string;
  tags: MakerTag[];
};

export type MakerTagsPage = {
  category: MakerCategoryId;
  categoryLabel: string;
  categories: MakerTagCategory[];
};

export type MakerMagnet = {
  name: string;
  url: string;
  size: string | null;
  sizeBytes: number;
  createdAt: string | null;
  filesCount: number;
};

/** 评论区共享资源（ed2k 等） */
export type MakerResource = {
  id: string;
  type: string;
  url: string;
  name: string;
  sizeBytes: number;
  hash: string | null;
  sourceLabel: string | null;
  hd: boolean;
  createdAt: string | null;
};

export type MakerMovieDetail = MakerMovie & {
  summary: string | null;
  score: number | string | null;
  reviewsCount: number;
  commentsCount: number;
  wantWatchCount: number;
  watchedCount: number;
  makers: Array<{ id: string; name: string }>;
  makerId: string | null;
  publisher: string | null;
  publisherId: string | null;
  director: string | null;
  directorId: string | null;
  series: string | null;
  seriesId: string | null;
  seriesType: string | null;
  actors: Array<{ id: string; name: string; avatarUrl: string | null }>;
  tags: string[];
  shareUrl: string | null;
  magnets: MakerMagnet[];
  resources: MakerResource[];
  previews: Array<{ thumb: string; large: string }>;
  relativeMovies: MakerMovie[];
  actorMovies: Array<{
    id: string;
    number: string;
    title: string;
    thumbUrl: string | null;
    coverUrl: string | null;
  }>;
  topRankings: Array<{
    type: string;
    period: string;
    rank: number;
    category: string | null;
  }>;
  hasPreviewVideo: boolean;
  previewVideoUrl: string | null;
  canPlay: boolean;
  playSources: unknown[];
  hasLocalSubtitle: boolean;
  /** AVDB 自有种子库中该番号的资源 */
  avdbTorrents?: MakerTorrent[];
};

/** 片商 / 导演 / 系列实体详情 */
export type MakerEntityKind = 'maker' | 'director' | 'series';

export type MakerEntity = {
  kind: MakerEntityKind;
  id: string;
  type: number;
  name: string;
  videosCount: number;
  shareUrl: string | null;
  hasCollected: boolean;
};

/** 演员详情 */
export type MakerActorDetail = {
  id: string;
  type: number;
  name: string;
  nameZht: string | null;
  otherName: string | null;
  avatarUrl: string | null;
  birthday: string | null;
  age: number;
  constellation: string | null;
  bloodType: string | null;
  height: number;
  bust: number;
  cup: string | null;
  waist: number;
  hips: number;
  birthplace: string | null;
  twitterId: string | null;
  instagramId: string | null;
  videosCount: number;
  shareUrl: string | null;
  tags: Array<{ id: string; name: string; videosCount: number }>;
  filterTags: Array<{ id: string; name: string }>;
};

/** 推荐演员三组 */
export type MakerActorRecommend = {
  newActors: MakerActor[];
  monthlyActors: MakerActor[];
  recommendActors: MakerActor[];
};

/** 片单 */
export type MakerList = {
  id: string;
  name: string;
  description: string | null;
  moviesCount: number;
  viewsCount: number;
  collectionsCount: number;
  isDefault: boolean;
  shareUrl: string | null;
  createdAt: string | null;
};

export type MakerListDetail = MakerList & {
  isCreator: boolean;
  hasCollected: boolean;
};

/** AVDB 自有种子库资源 */
export type MakerTorrent = {
  id: string;
  emby: number;
  number: string;
  site: string | null;
  website: string | null;
  section: string | null;
  category: string | null;
  title: string;
  sizeMb: number;
  sizeBytes: number;
  postTime: string | null;
  seeders: number;
  /** magnet 或 ed2k */
  downloadUrl: string;
  previewImage: string | null;
  free: boolean;
  tags: string[];
  chinese: boolean;
  uncensored: boolean;
  uc: boolean;
  hd: boolean;
  uhd: boolean;
  mosaic: boolean;
};

export type MakerTorrentPage = {
  keyword: string;
  exact: boolean;
  page: number;
  total: number;
  items: MakerTorrent[];
  hasMore: boolean;
};

export async function fetchMakerRank(opts: {
  category: MakerCategoryId;
  period: MakerPeriod;
  signal?: AbortSignal;
}): Promise<MakerRankPage> {
  const params = new URLSearchParams({
    category: opts.category,
    period: opts.period,
  });
  const res = await apiFetch(`/makers/rank?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerRankPage;
}

export async function fetchMakerPlayback(opts: {
  period: MakerPeriod;
  filterBy?: MakerPlaybackFilter;
  signal?: AbortSignal;
}): Promise<MakerMoviePage> {
  const params = new URLSearchParams({
    period: opts.period,
    filter_by: opts.filterBy ?? 'all',
  });
  const res = await apiFetch(`/makers/playback?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerMoviePage;
}

export async function fetchMakerLatest(opts: {
  category: MakerCategoryId;
  page?: number;
  limit?: number;
  sortBy?: MakerLatestSort;
  filterBy?: MakerLatestFilter;
  signal?: AbortSignal;
}): Promise<MakerMoviePage> {
  const params = new URLSearchParams({
    category: opts.category,
    page: String(opts.page ?? 1),
    limit: String(opts.limit ?? 24),
    sort_by: opts.sortBy ?? 'update',
    filter_by: opts.filterBy ?? 'all',
  });
  const res = await apiFetch(`/makers/latest?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerMoviePage;
}

export async function fetchMakerTop(opts: {
  category: MakerCategoryId;
  page?: number;
  /** 年份榜（留空为按类别榜） */
  year?: string;
  signal?: AbortSignal;
}): Promise<MakerMoviePage> {
  const params = new URLSearchParams({
    category: opts.category,
    page: String(opts.page ?? 1),
  });
  if (opts.year) params.set('year', opts.year);
  const res = await apiFetch(`/makers/top?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerMoviePage;
}

export async function fetchMakerYears(
  signal?: AbortSignal,
): Promise<string[]> {
  const res = await apiFetch('/makers/years', { signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { years?: string[] };
  return data.years || [];
}

export async function fetchMakerRecommend(
  signal?: AbortSignal,
): Promise<MakerMovie[]> {
  const res = await apiFetch(`/makers/recommend`, { signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: MakerMovie[] };
  return data.items || [];
}

export async function fetchMakerHotReviews(opts: {
  period: MakerPeriod;
  signal?: AbortSignal;
}): Promise<MakerHotReview[]> {
  const params = new URLSearchParams({ period: opts.period });
  const res = await apiFetch(`/makers/hot-reviews?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: MakerHotReview[] };
  return data.items || [];
}

export async function fetchMakerReviews(opts: {
  movieId: string;
  page?: number;
  limit?: number;
  signal?: AbortSignal;
}): Promise<{ items: MakerReview[]; hasMore: boolean }> {
  const params = new URLSearchParams({
    movie_id: opts.movieId,
    page: String(opts.page ?? 1),
    limit: String(opts.limit ?? 20),
  });
  const res = await apiFetch(`/makers/reviews?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: MakerReview[]; hasMore?: boolean };
  return { items: data.items || [], hasMore: !!data.hasMore };
}

export async function fetchMakerActors(opts: {
  category: MakerCategoryId;
  page?: number;
  limit?: number;
  signal?: AbortSignal;
}): Promise<{ items: MakerActor[]; hasMore: boolean }> {
  const params = new URLSearchParams({
    category: opts.category,
    page: String(opts.page ?? 1),
    limit: String(opts.limit ?? 24),
  });
  const res = await apiFetch(`/makers/actors?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: MakerActor[]; hasMore?: boolean };
  return { items: data.items || [], hasMore: !!data.hasMore };
}

export async function fetchMakerTags(
  category: MakerCategoryId,
  signal?: AbortSignal,
): Promise<MakerTagsPage> {
  const res = await apiFetch(`/makers/tags?category=${category}`, { signal });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerTagsPage;
}

export async function fetchMakerBrowse(opts: {
  category: MakerCategoryId;
  /** 标签组 id：main / year / month / duration / 其它内容标签组 */
  group?: string;
  tagId?: string;
  /** 逗号分隔多选（仅内容标签组） */
  tagIds?: string[];
  actorId?: string;
  year?: string;
  /** 片商 id */
  makerId?: string;
  /** 导演 id */
  directorId?: string;
  /** 片单 id */
  listId?: string;
  /** 发行商 id */
  publisherId?: string;
  /** 系列 id（需配合 seriesType） */
  seriesId?: string;
  seriesType?: string;
  /** release 按发行日期排序 */
  sortBy?: 'release';
  orderBy?: 'asc' | 'desc';
  page?: number;
  limit?: number;
  signal?: AbortSignal;
}): Promise<MakerMoviePage> {
  const params = new URLSearchParams({
    category: opts.category,
    page: String(opts.page ?? 1),
    limit: String(opts.limit ?? 24),
  });
  if (opts.group) params.set('group', opts.group);
  if (opts.tagId) params.set('tag_id', opts.tagId);
  if (opts.tagIds?.length) params.set('tag_ids', opts.tagIds.join(','));
  if (opts.actorId) params.set('actor_id', opts.actorId);
  if (opts.year) params.set('year', opts.year);
  if (opts.makerId) params.set('maker_id', opts.makerId);
  if (opts.directorId) params.set('director_id', opts.directorId);
  if (opts.listId) params.set('list_id', opts.listId);
  if (opts.publisherId) params.set('publisher_id', opts.publisherId);
  if (opts.seriesId) params.set('series_id', opts.seriesId);
  if (opts.seriesType) params.set('series_type', opts.seriesType);
  if (opts.sortBy) params.set('sort_by', opts.sortBy);
  if (opts.orderBy) params.set('order_by', opts.orderBy);
  const res = await apiFetch(`/makers/browse?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerMoviePage;
}

export async function fetchMakerSearch(
  q: string,
  type: MakerSearchType = 'maker',
  signal?: AbortSignal,
): Promise<MakerSearchItem[]> {
  const res = await apiFetch(
    `/makers/search?q=${encodeURIComponent(q)}&type=${type}`,
    { signal },
  );
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: MakerSearchItem[] };
  return data.items || [];
}

export async function fetchMakerMovieSearch(opts: {
  q: string;
  page?: number;
  limit?: number;
  /** 影片筛选：all 全部 / subtitle 中文字幕 / magnets 有磁力 / playable 可播放 */
  filterBy?: MakerMovieSearchFilter;
  /** 内容类别过滤：0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫 */
  movieType?: MakerCategoryId;
  /** 排序：release / update / relevance */
  sortBy?: 'release' | 'update' | 'relevance';
  signal?: AbortSignal;
}): Promise<MakerMoviePage> {
  const params = new URLSearchParams({
    q: opts.q,
    page: String(opts.page ?? 1),
    limit: String(opts.limit ?? 24),
  });
  if (opts.filterBy && opts.filterBy !== 'all') {
    params.set('filter_by', opts.filterBy);
  }
  if (opts.movieType) params.set('movie_type', opts.movieType);
  if (opts.sortBy) params.set('sort_by', opts.sortBy);
  const res = await apiFetch(`/makers/movie-search?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerMoviePage;
}

export async function fetchMakerMovies(opts: {
  name: string;
  page?: number;
  limit?: number;
  signal?: AbortSignal;
}): Promise<MakerMoviePage> {
  const params = new URLSearchParams({
    name: opts.name,
    page: String(opts.page ?? 1),
    limit: String(opts.limit ?? 24),
  });
  const res = await apiFetch(`/makers/movies?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerMoviePage;
}

export async function fetchMakerMovie(
  id: string,
  signal?: AbortSignal,
): Promise<MakerMovieDetail> {
  const res = await apiFetch(`/makers/movie/${encodeURIComponent(id)}`, { signal });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerMovieDetail;
}

export async function fetchMakerEntity(
  kind: MakerEntityKind,
  id: string,
  signal?: AbortSignal,
): Promise<MakerEntity> {
  const params = new URLSearchParams({ kind, id });
  const res = await apiFetch(`/makers/entity?${params.toString()}`, { signal });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerEntity;
}

export async function fetchMakerActorDetail(
  id: string,
  signal?: AbortSignal,
): Promise<MakerActorDetail> {
  const params = new URLSearchParams({ id });
  const res = await apiFetch(`/makers/actor-detail?${params.toString()}`, {
    signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerActorDetail;
}

export async function fetchMakerActorRecommend(
  signal?: AbortSignal,
): Promise<MakerActorRecommend> {
  const res = await apiFetch('/makers/actor-recommend', { signal });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerActorRecommend;
}

export async function fetchMakerRelatedLists(
  movieId: string,
  signal?: AbortSignal,
): Promise<MakerList[]> {
  const params = new URLSearchParams({ movie_id: movieId, limit: '10' });
  const res = await apiFetch(`/makers/lists/related?${params.toString()}`, {
    signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: MakerList[] };
  return data.items || [];
}

export async function fetchMakerListDetail(
  id: string,
  signal?: AbortSignal,
): Promise<MakerListDetail> {
  const params = new URLSearchParams({ id });
  const res = await apiFetch(`/makers/list-detail?${params.toString()}`, {
    signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerListDetail;
}

export async function fetchMakerRecentViewed(
  signal?: AbortSignal,
): Promise<MakerMovie[]> {
  const res = await apiFetch('/makers/recent-viewed', { signal });
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: MakerMovie[] };
  return data.items || [];
}

export async function fetchMakerTorrents(opts: {
  keyword: string;
  page?: number;
  limit?: number;
  /** 仅保留番号完全一致的记录 */
  exact?: boolean;
  signal?: AbortSignal;
}): Promise<MakerTorrentPage> {
  const params = new URLSearchParams({
    keyword: opts.keyword,
    page: String(opts.page ?? 1),
    limit: String(opts.limit ?? 24),
  });
  if (opts.exact) params.set('exact', 'true');
  const res = await apiFetch(`/makers/torrents?${params.toString()}`, {
    signal: opts.signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerTorrentPage;
}

/** 在线播放源：片商类插件 / Stremio 插件 / AVDB 播放源聚合 */
export type MakerPlaySource = MediaStream & {
  /** plugin 片商类插件 / stremio 社区插件 / avdb AVDB 播放源 */
  source: 'plugin' | 'stremio' | 'avdb' | string;
};

export type MakerPlaySources = {
  streams: MakerPlaySource[];
  total: number;
  reason: string;
};

export async function fetchMakerPlaySources(opts: {
  movieId: string;
  number?: string;
  title?: string;
  signal?: AbortSignal;
}): Promise<MakerPlaySources> {
  const params = new URLSearchParams();
  if (opts.number) params.set('number', opts.number);
  if (opts.title) params.set('title', opts.title);
  const query = params.toString();
  const res = await apiFetch(
    `/makers/movie/${encodeURIComponent(opts.movieId)}/play-sources${
      query ? `?${query}` : ''
    }`,
    { signal: opts.signal },
  );
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as MakerPlaySources;
}
