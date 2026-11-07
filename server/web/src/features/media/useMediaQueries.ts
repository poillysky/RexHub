'use client';

import { keepPreviousData, useInfiniteQuery, useQuery } from '@tanstack/react-query';
import {
  fetchMediaCharts,
  fetchMediaDiscover,
  fetchMediaGenres,
  fetchMediaMeta,
  fetchMpDetail,
  fetchMpList,
  fetchMpMediaSearch,
  fetchMpPerson,
  fetchMpPersonWorks,
  fetchMpRelated,
  fetchMpSearch,
  type MpListParams,
  type MpListResult,
  type MpSearchMode,
  type MpSearchResult,
  type MediaCategoryId,
  type MediaChartResult,
  type MediaDiscoverResult,
  type MediaGenre,
  type MediaMeta,
  type MediaRelatedResult,
  type MediaSearchResult,
  type MediaSourceId,
} from '@/lib/api';

/** 影视模块统一 query key，跨组件复用同一份缓存。 */
export const mediaKeys = {
  all: ['media'] as const,
  meta: () => ['media', 'meta'] as const,
  charts: (source: MediaSourceId, category: MediaCategoryId, chart: string, page: number) =>
    ['media', 'charts', source, category, chart, page] as const,
  detail: (source: MediaSourceId, id: string, mediaType?: 'movie' | 'tv') =>
    ['media', 'detail', source, id, mediaType ?? null] as const,
  related: (source: MediaSourceId, id: string, mediaType: 'movie' | 'tv') =>
    ['media', 'related', source, id, mediaType] as const,
  genres: (mediaType: 'movie' | 'tv') => ['media', 'genres', mediaType] as const,
  discover: (mediaType: 'movie' | 'tv', genre: string, sortBy: string, year: string, page: number) =>
    ['media', 'discover', mediaType, genre, sortBy, year, page] as const,
  search: (source: MediaSourceId, q: string, page: number) =>
    ['media', 'search', source, q, page] as const,
  person: (source: MediaSourceId, personId: string) =>
    ['media', 'person', source, personId] as const,
  personWorks: (source: MediaSourceId, personId: string) =>
    ['media', 'person-works', source, personId] as const,
  mp: (path: string, params: MpListParams) =>
    ['media', 'mp', path, params] as const,
  ptSearch: (keyword: string, page: number, mode: MpSearchMode = 'title') =>
    ['media', 'pt-search', mode, keyword, page] as const,
};

type Opts = { enabled?: boolean };

const detailStale = 5 * 60 * 1000;

export function useMediaMeta(opts: Opts = {}) {
  return useQuery<MediaMeta>({
    queryKey: mediaKeys.meta(),
    queryFn: ({ signal }) => fetchMediaMeta(signal),
    enabled: opts.enabled ?? true,
    staleTime: 5 * 60 * 1000,
  });
}

export function useMediaCharts(opts: {
  source: MediaSourceId;
  category: MediaCategoryId;
  chart: string;
  page?: number;
  enabled?: boolean;
}) {
  const page = opts.page ?? 1;
  return useQuery<MediaChartResult>({
    queryKey: mediaKeys.charts(opts.source, opts.category, opts.chart, page),
    queryFn: ({ signal }) =>
      fetchMediaCharts({
        source: opts.source,
        category: opts.category,
        chart: opts.chart,
        page,
        signal,
      }),
    enabled: opts.enabled ?? true,
    placeholderData: keepPreviousData,
  });
}

export function useMediaDetail(
  opts: { source: MediaSourceId; id: string; mediaType?: 'movie' | 'tv' } & Opts,
) {
  return useQuery({
    queryKey: mediaKeys.detail(opts.source, opts.id, opts.mediaType),
    queryFn: ({ signal }) =>
      fetchMpDetail({
        source: opts.source,
        id: opts.id,
        mediaType: opts.mediaType,
        signal,
      }),
    enabled: (opts.enabled ?? true) && Boolean(opts.id),
    staleTime: detailStale,
  });
}

export function useMediaRelated(
  opts: { source: MediaSourceId; id: string; mediaType: 'movie' | 'tv' } & Opts,
) {
  return useQuery<MediaRelatedResult>({
    queryKey: mediaKeys.related(opts.source, opts.id, opts.mediaType),
    queryFn: ({ signal }) =>
      fetchMpRelated({
        source: opts.source,
        id: opts.id,
        mediaType: opts.mediaType,
        signal,
      }),
    enabled: (opts.enabled ?? true) && Boolean(opts.id),
    staleTime: detailStale,
  });
}

export function useMediaGenres(opts: { mediaType: 'movie' | 'tv' } & Opts) {
  return useQuery<MediaGenre[]>({
    queryKey: mediaKeys.genres(opts.mediaType),
    queryFn: ({ signal }) => fetchMediaGenres({ mediaType: opts.mediaType, signal }),
    enabled: opts.enabled ?? true,
    staleTime: 30 * 60 * 1000,
  });
}

export function useMediaDiscover(opts: {
  mediaType: 'movie' | 'tv';
  genre?: string;
  sortBy?: string;
  year?: string;
  page?: number;
  enabled?: boolean;
}) {
  const page = opts.page ?? 1;
  return useQuery<MediaDiscoverResult>({
    queryKey: mediaKeys.discover(
      opts.mediaType,
      opts.genre || '',
      opts.sortBy || '',
      opts.year || '',
      page,
    ),
    queryFn: ({ signal }) =>
      fetchMediaDiscover({
        mediaType: opts.mediaType,
        genre: opts.genre,
        sortBy: opts.sortBy,
        year: opts.year,
        page,
        signal,
      }),
    enabled: opts.enabled ?? true,
    placeholderData: keepPreviousData,
  });
}

export function useMediaSearch(opts: {
  source: MediaSourceId;
  q: string;
  page?: number;
  minLength: number;
  enabled?: boolean;
}) {
  const page = opts.page ?? 1;
  const q = opts.q.trim();
  return useQuery<MediaSearchResult>({
    queryKey: mediaKeys.search(opts.source, q, page),
    queryFn: ({ signal }) => fetchMpMediaSearch({ source: opts.source, q, page, signal }),
    enabled: (opts.enabled ?? true) && q.length >= opts.minLength,
    placeholderData: keepPreviousData,
  });
}

/** MoviePilot 影人资料（头像 / 生日 / 简介等） */
export function useMpPerson(opts: {
  source: MediaSourceId;
  personId?: string;
  enabled?: boolean;
}) {
  const personId = String(opts.personId || '').trim();
  return useQuery({
    queryKey: mediaKeys.person(opts.source, personId),
    queryFn: ({ signal }) =>
      fetchMpPerson({ source: opts.source, id: personId, signal }),
    enabled: (opts.enabled ?? true) && Boolean(personId),
    staleTime: 30 * 60 * 1000,
    retry: false,
  });
}

/** MoviePilot 影人作品（每页 24 条，滚动到底加载更多） */
export function useMpPersonWorks(opts: {
  source: MediaSourceId;
  personId?: string;
  enabled?: boolean;
}) {
  const personId = String(opts.personId || '').trim();
  return useInfiniteQuery({
    queryKey: mediaKeys.personWorks(opts.source, personId),
    queryFn: ({ pageParam, signal }) =>
      fetchMpPersonWorks({
        source: opts.source,
        id: personId,
        page: pageParam,
        signal,
      }),
    initialPageParam: 1,
    getNextPageParam: (last) => (last.hasMore ? last.page + 1 : undefined),
    enabled: (opts.enabled ?? true) && Boolean(personId),
    staleTime: 10 * 60 * 1000,
  });
}

/** MoviePilot 推荐 / 探索列表（服务端已归一为 MediaItem） */
export function useMpList(opts: {
  path: string;
  params?: MpListParams;
  enabled?: boolean;
}) {
  const params = opts.params || {};
  return useQuery<MpListResult>({
    queryKey: mediaKeys.mp(opts.path, params),
    queryFn: ({ signal }) =>
      fetchMpList({ path: opts.path, params, signal }),
    enabled: (opts.enabled ?? true) && Boolean(opts.path),
    staleTime: 5 * 60 * 1000,
    placeholderData: keepPreviousData,
  });
}

/** MoviePilot PT 站点聚合搜索：标题模糊 / IMDb 精确（走 MP 的媒体搜索） */
export function useMpSearch(opts: {
  keyword?: string;
  page?: number;
  source?: MediaSourceId;
  id?: string;
  mediaType?: 'movie' | 'tv';
  area?: MpSearchMode;
  enabled?: boolean;
}) {
  const page = opts.page ?? 1;
  const keyword = (opts.keyword || '').trim();
  const area: MpSearchMode = opts.area === 'imdbid' ? 'imdbid' : 'title';
  const byImdb = area === 'imdbid' && Boolean(opts.source && opts.id);
  const label = byImdb ? String(opts.id || '') : keyword;
  return useQuery<MpSearchResult>({
    queryKey: mediaKeys.ptSearch(label, page, area),
    queryFn: ({ signal }) =>
      fetchMpSearch({
        keyword: keyword || undefined,
        page,
        source: opts.source,
        id: opts.id,
        mediaType: opts.mediaType,
        area,
        signal,
      }),
    enabled: (opts.enabled ?? true) && Boolean(label),
    staleTime: 2 * 60 * 1000,
    retry: false,
    placeholderData: keepPreviousData,
  });
}
