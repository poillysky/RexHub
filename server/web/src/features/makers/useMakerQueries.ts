'use client';

import { useQuery } from '@tanstack/react-query';
import {
  fetchMakerAccount,
  fetchMakerActorDetail,
  fetchMakerActorRecommend,
  fetchMakerActors,
  fetchMakerBrowse,
  fetchMakerEntity,
  fetchMakerHotReviews,
  fetchMakerLatest,
  fetchMakerListDetail,
  fetchMakerMovie,
  fetchMakerMovieSearch,
  fetchMakerMovies,
  fetchMakerPlayback,
  fetchMakerRank,
  fetchMakerRecentViewed,
  fetchMakerRecommend,
  fetchMakerRelatedLists,
  fetchMakerReviews,
  fetchMakerSearch,
  fetchMakerTags,
  fetchMakerTop,
  fetchMakerTorrents,
  fetchMakerYears,
  type MakerCategoryId,
  type MakerEntityKind,
  type MakerLatestFilter,
  type MakerLatestSort,
  type MakerMovieSearchFilter,
  type MakerPeriod,
  type MakerPlaybackFilter,
  type MakerSearchType,
} from '@/lib/api/makers';

export function useMakerRank(category: MakerCategoryId, period: MakerPeriod) {
  return useQuery({
    queryKey: ['maker-rank', category, period],
    queryFn: ({ signal }) => fetchMakerRank({ category, period, signal }),
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerPlayback(
  period: MakerPeriod,
  filterBy: MakerPlaybackFilter = 'all',
) {
  return useQuery({
    queryKey: ['maker-playback', period, filterBy],
    queryFn: ({ signal }) => fetchMakerPlayback({ period, filterBy, signal }),
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerLatest(
  category: MakerCategoryId,
  page: number,
  sortBy: MakerLatestSort = 'update',
  filterBy: MakerLatestFilter = 'all',
) {
  return useQuery({
    queryKey: ['maker-latest', category, page, sortBy, filterBy],
    queryFn: ({ signal }) =>
      fetchMakerLatest({ category, page, sortBy, filterBy, signal }),
    staleTime: 2 * 60 * 1000,
  });
}

export function useMakerTop(
  category: MakerCategoryId,
  page: number,
  year = '',
) {
  return useQuery({
    queryKey: ['maker-top', category, page, year],
    queryFn: ({ signal }) => fetchMakerTop({ category, page, year, signal }),
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerYears(enabled = true) {
  return useQuery({
    queryKey: ['maker-years'],
    queryFn: ({ signal }) => fetchMakerYears(signal),
    staleTime: 30 * 60 * 1000,
    enabled,
  });
}

export function useMakerRecommend() {
  return useQuery({
    queryKey: ['maker-recommend'],
    queryFn: ({ signal }) => fetchMakerRecommend(signal),
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerHotReviews(period: MakerPeriod) {
  return useQuery({
    queryKey: ['maker-hot-reviews', period],
    queryFn: ({ signal }) => fetchMakerHotReviews({ period, signal }),
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerReviews(movieId: string, page: number) {
  return useQuery({
    queryKey: ['maker-reviews', movieId, page],
    queryFn: ({ signal }) => fetchMakerReviews({ movieId, page, signal }),
    enabled: !!movieId,
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerActors(category: MakerCategoryId, page: number) {
  return useQuery({
    queryKey: ['maker-actors', category, page],
    queryFn: ({ signal }) => fetchMakerActors({ category, page, signal }),
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerTags(category: MakerCategoryId) {
  return useQuery({
    queryKey: ['maker-tags', category],
    queryFn: ({ signal }) => fetchMakerTags(category, signal),
    staleTime: 30 * 60 * 1000,
  });
}

export function useMakerBrowse(
  category: MakerCategoryId,
  group: string,
  tagId: string,
  actorId: string,
  page: number,
  tagIds?: string[],
  dims?: {
    makerId?: string;
    directorId?: string;
    listId?: string;
    publisherId?: string;
    seriesId?: string;
    seriesType?: string;
    sortBy?: 'release';
    orderBy?: 'asc' | 'desc';
  },
) {
  return useQuery({
    queryKey: [
      'maker-browse',
      category,
      group,
      tagId,
      actorId,
      tagIds,
      page,
      dims,
    ],
    queryFn: ({ signal }) =>
      fetchMakerBrowse({
        category,
        group,
        tagId,
        actorId,
        tagIds,
        page,
        ...dims,
        signal,
      }),
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerSearch(
  q: string,
  type: MakerSearchType = 'maker',
) {
  const keyword = q.trim();
  return useQuery({
    queryKey: ['maker-search', type, keyword],
    queryFn: ({ signal }) => fetchMakerSearch(keyword, type, signal),
    enabled: keyword.length > 0,
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerMovieSearch(
  q: string,
  page: number,
  filterBy: MakerMovieSearchFilter = 'all',
  movieType?: MakerCategoryId,
  sortBy?: 'release' | 'update' | 'relevance',
) {
  const keyword = q.trim();
  return useQuery({
    queryKey: ['maker-movie-search', keyword, page, filterBy, movieType, sortBy],
    queryFn: ({ signal }) =>
      fetchMakerMovieSearch({
        q: keyword,
        page,
        filterBy,
        movieType,
        sortBy,
        signal,
      }),
    enabled: keyword.length > 0,
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerMovies(name: string, page: number) {
  return useQuery({
    queryKey: ['maker-movies', name, page],
    queryFn: ({ signal }) => fetchMakerMovies({ name, page, signal }),
    enabled: !!name.trim(),
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerMovie(id: string) {
  return useQuery({
    queryKey: ['maker-movie', id],
    queryFn: ({ signal }) => fetchMakerMovie(id, signal),
    enabled: !!id,
    staleTime: 5 * 60 * 1000,
  });
}

export function useMakerEntity(kind: MakerEntityKind, id: string) {
  return useQuery({
    queryKey: ['maker-entity', kind, id],
    queryFn: ({ signal }) => fetchMakerEntity(kind, id, signal),
    enabled: !!id,
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerActorDetail(id: string) {
  return useQuery({
    queryKey: ['maker-actor-detail', id],
    queryFn: ({ signal }) => fetchMakerActorDetail(id, signal),
    enabled: !!id,
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerActorRecommend() {
  return useQuery({
    queryKey: ['maker-actor-recommend'],
    queryFn: ({ signal }) => fetchMakerActorRecommend(signal),
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerRelatedLists(movieId: string) {
  return useQuery({
    queryKey: ['maker-related-lists', movieId],
    queryFn: ({ signal }) => fetchMakerRelatedLists(movieId, signal),
    enabled: !!movieId,
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerListDetail(id: string) {
  return useQuery({
    queryKey: ['maker-list-detail', id],
    queryFn: ({ signal }) => fetchMakerListDetail(id, signal),
    enabled: !!id,
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerRecentViewed() {
  return useQuery({
    queryKey: ['maker-recent-viewed'],
    queryFn: ({ signal }) => fetchMakerRecentViewed(signal),
    staleTime: 2 * 60 * 1000,
  });
}

export function useMakerAccount() {
  return useQuery({
    queryKey: ['maker-account'],
    queryFn: ({ signal }) => fetchMakerAccount(signal),
    staleTime: 10 * 60 * 1000,
  });
}

export function useMakerTorrents(
  keyword: string,
  page: number,
  exact = false,
) {
  const kw = keyword.trim();
  return useQuery({
    queryKey: ['maker-torrents', kw, page, exact],
    queryFn: ({ signal }) =>
      fetchMakerTorrents({ keyword: kw, page, exact, signal }),
    enabled: kw.length > 0,
    staleTime: 5 * 60 * 1000,
  });
}
