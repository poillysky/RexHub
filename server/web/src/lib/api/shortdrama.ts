/**
 * 短剧：站点 / 片单 / 详情 / 播放流。
 *
 * 数据由 RexHub 聚合插件产出，前端只连本服务（同源，带 cookie）。
 */
import { API_BASE, apiFetch, parseError } from './client';

export type DramaSite = {
  id: string;
  name: string;
  enabled: boolean;
  capabilities: string[];
  ui?: {
    shortdrama?: {
      title?: string;
      subtitle?: string;
      accent?: string;
      icon?: string;
      logo?: string;
      badge?: string;
    };
  };
};

export type DramaCard = {
  site: string;
  siteName: string;
  id: string;
  title: string;
  cover: string;
  description: string;
  season: number;
  episodeCount: number;
};

export type DramaEpisode = {
  id: string;
  title: string;
  episode: number;
  duration: number;
  disabled: boolean;
};

export type DramaSeries = {
  site: string;
  siteName: string;
  id: string;
  title: string;
  cover: string;
  description: string;
  season: number;
  episodeCount: number;
  albumId: string;
  complete: boolean;
  episodes: DramaEpisode[];
  seasons: DramaCard[];
};

export type DramaPage = {
  site: string;
  siteName: string;
  items: DramaCard[];
  hasMore: boolean;
  nextPage: number | null;
};

export type DramaFilterItem = {
  id: string;
  title: string;
};

export type DramaFilterGroup = {
  title: string;
  items: DramaFilterItem[];
};

export type DramaRank = {
  id: string;
  title: string;
  filters?: DramaFilterGroup[];
};

export type DramaRankGroup = {
  id: string;
  title: string;
  ranks: DramaRank[];
};

async function getJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  const res = await apiFetch(path, { signal });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as T;
}

export async function fetchDramaSites(signal?: AbortSignal): Promise<DramaSite[]> {
  const data = await getJson<{ items: DramaSite[] }>('/shortdrama/sites', signal);
  return data.items ?? [];
}

export async function fetchDramaCatalog(
  site: string,
  page = 1,
  signal?: AbortSignal,
): Promise<DramaPage> {
  const params = new URLSearchParams({ page: String(page) });
  return getJson<DramaPage>(
    `/shortdrama/${encodeURIComponent(site)}/catalog?${params}`,
    signal,
  );
}

export async function fetchDramaSearch(
  site: string,
  q: string,
  page = 1,
  signal?: AbortSignal,
): Promise<DramaPage> {
  const params = new URLSearchParams({ q, page: String(page) });
  return getJson<DramaPage>(
    `/shortdrama/${encodeURIComponent(site)}/search?${params}`,
    signal,
  );
}

export async function fetchDramaRankGroups(
  site: string,
  signal?: AbortSignal,
): Promise<DramaRankGroup[]> {
  const data = await getJson<{ groups: DramaRankGroup[] }>(
    `/shortdrama/${encodeURIComponent(site)}/lists`,
    signal,
  );
  return data.groups ?? [];
}

export async function fetchDramaRank(
  site: string,
  group: string,
  rank: string,
  page = 1,
  signal?: AbortSignal,
  filter = '',
): Promise<DramaPage> {
  const params = new URLSearchParams({ group, rank, page: String(page) });
  if (filter) params.set('filter', filter);
  return getJson<DramaPage>(
    `/shortdrama/${encodeURIComponent(site)}/rank?${params}`,
    signal,
  );
}

export async function fetchDramaSeries(
  site: string,
  seriesId: string,
  signal?: AbortSignal,
): Promise<DramaSeries> {
  return getJson<DramaSeries>(
    `/shortdrama/${encodeURIComponent(site)}/series/${encodeURIComponent(seriesId)}`,
    signal,
  );
}

/** 播放地址：同源转发，video 标签直接当 src 用。 */
export function dramaStreamUrl(site: string, episodeId: string): string {
  return `${API_BASE}/shortdrama/${encodeURIComponent(site)}/episodes/${encodeURIComponent(episodeId)}/stream`;
}
