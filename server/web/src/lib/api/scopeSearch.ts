/**
 * 范围搜索（影视 / 片商）：聚合多源结果。
 *
 * 后端 `GET /search/scope` 直接返回裸 JSON，不包 Envelope。
 */
import { apiFetch, parseError } from './client';
import type { FilterSize, FilterTime, SortType } from '@/types/resource';

export type ScopeSearchScope = 'movie' | 'maker';

export type ScopeSearchSource =
  | 'bitmagnet'
  | 'cloudsaver'
  | 'sehuatang'
  | 'avdb';

export type ScopeDetailKind = 'maker' | 'series' | 'director' | 'actor';

export type ScopeSearchLink = {
  label: string;
  url: string;
  password: string;
};

export type ScopeSearchItem = {
  id: string;
  hash: string | null;
  source: ScopeSearchSource;
  sourceLabel: string;
  category: 'torrent' | 'pan' | 'movie';
  title: string;
  sizeBytes: number;
  sizeLabel: string;
  publishedAt: string | null;
  magnet: string | null;
  ed2k: string | null;
  links: ScopeSearchLink[];
  thumbUrl: string | null;
  detailKind: ScopeDetailKind | null;
  detailId: string | null;
};

export type ScopeSearchResult = {
  scope: ScopeSearchScope;
  keyword: string;
  page: number;
  sourceErrors: Record<string, string>;
  items: ScopeSearchItem[];
  hasMore: boolean;
};

export async function fetchScopeSearch(opts: {
  scope: ScopeSearchScope;
  keyword: string;
  page?: number;
  pageSize?: number;
  sortType: SortType;
  filterTime: FilterTime;
  filterSize: FilterSize;
  source?: ScopeSearchSource | 'all';
  signal?: AbortSignal;
}): Promise<ScopeSearchResult> {
  const q = new URLSearchParams();
  q.set('scope', opts.scope);
  q.set('keyword', opts.keyword);
  q.set('page', String(opts.page ?? 1));
  q.set('page_size', String(opts.pageSize ?? 20));
  q.set('sort_type', opts.sortType);
  q.set('filter_time', opts.filterTime);
  q.set('filter_size', opts.filterSize);
  if (opts.source && opts.source !== 'all') q.set('source', opts.source);
  const res = await apiFetch(`/search/scope?${q}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as ScopeSearchResult;
}
