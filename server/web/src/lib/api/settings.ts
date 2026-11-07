/**
 * 论坛 / TMDB / 字幕 / 网络设置
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { API_BASE, apiFetch, parseError } from './client';
import type { Envelope } from './client';
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

export type ForumRegionId = 'japan' | 'china' | 'western' | 'mixed' | 'other';

export type SehuatangForumSettings = {
  regionByKey: Record<string, ForumRegionId>;
  updated_at?: string;
};

export async function getSehuatangForumSettings(): Promise<SehuatangForumSettings> {
  const res = await apiFetch('/settings/forum/sehuatang');
  if (!res.ok) throw new Error(await parseError(res));
  const data = ((await res.json()) as Envelope<SehuatangForumSettings>).data;
  return {
    regionByKey: (data?.regionByKey || {}) as Record<string, ForumRegionId>,
    updated_at: data?.updated_at,
  };
}

export async function putSehuatangForumSettings(body: {
  regionByKey: Record<string, ForumRegionId>;
}): Promise<SehuatangForumSettings> {
  const res = await apiFetch('/settings/forum/sehuatang', {
    method: 'PUT',
    body: JSON.stringify({ regionByKey: body.regionByKey }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = ((await res.json()) as Envelope<SehuatangForumSettings>).data;
  return {
    regionByKey: (data?.regionByKey || {}) as Record<string, ForumRegionId>,
    updated_at: data?.updated_at,
  };
}

export type TmdbConfig = {
  configured?: boolean;
  fromEnv?: boolean;
  apiKeyHint?: string;
  apiKey?: string;
  updated_at?: string;
};

export async function getTmdb(): Promise<TmdbConfig> {
  const res = await apiFetch('/settings/tmdb');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<TmdbConfig>).data;
}

export async function putTmdb(body: { apiKey: string }): Promise<TmdbConfig> {
  const res = await apiFetch('/settings/tmdb', {
    method: 'PUT',
    body: JSON.stringify({ apiKey: body.apiKey }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<TmdbConfig>).data;
}

export async function testTmdb(body: {
  apiKey?: string;
}): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/settings/tmdb/test', {
    method: 'POST',
    body: JSON.stringify({ apiKey: body.apiKey || '' }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{ ok: boolean }> & { message: string };
  return { ok: Boolean(json.data?.ok), message: json.message || '' };
}

export type NetworkConfig = {
  proxyUrl?: string;
  proxyEnabled?: boolean;
  configured?: boolean;
  fromEnv?: boolean;
  effectiveProxyUrl?: string;
  flareSolverrUrl?: string;
  flareSolverrEnabled?: boolean;
  flareSolverrConfigured?: boolean;
  effectiveFlareSolverrUrl?: string;
  githubApiUrl?: string;
  githubTokenSet?: boolean;
  githubTokenHint?: string;
  githubMirror?: string;
  githubMirrorPresets?: { url: string; label: string }[];
  updated_at?: string;
};

export async function getNetwork(): Promise<NetworkConfig> {
  const res = await apiFetch('/settings/network');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<NetworkConfig>).data;
}

export async function putNetwork(body: {
  proxyUrl: string;
  proxyEnabled?: boolean;
  flareSolverrUrl?: string;
  flareSolverrEnabled?: boolean;
  githubApiUrl?: string;
  githubToken?: string;
  githubMirror?: string;
}): Promise<NetworkConfig> {
  const res = await apiFetch('/settings/network', {
    method: 'PUT',
    body: JSON.stringify({
      proxyUrl: body.proxyUrl,
      proxyEnabled: body.proxyEnabled,
      flareSolverrUrl: body.flareSolverrUrl,
      flareSolverrEnabled: body.flareSolverrEnabled,
      githubApiUrl: body.githubApiUrl,
      githubToken: body.githubToken,
      githubMirror: body.githubMirror,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<NetworkConfig>).data;
}

export async function testNetwork(body: {
  proxyUrl?: string;
}): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/settings/network/test', {
    method: 'POST',
    body: JSON.stringify({ proxyUrl: body.proxyUrl || '' }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{ ok: boolean }> & {
    message: string;
  };
  return { ok: Boolean(json.data?.ok), message: json.message || '' };
}

export async function testFlareSolverr(body: {
  flareSolverrUrl?: string;
}): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/settings/network/flare-test', {
    method: 'POST',
    body: JSON.stringify({ flareSolverrUrl: body.flareSolverrUrl || '' }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{ ok: boolean }> & {
    message: string;
  };
  return { ok: Boolean(json.data?.ok), message: json.message || '' };
}


export type AvdbSettings = {
  enabled: boolean;
  baseUrl: string;
  hasApiKey: boolean;
  timeoutSec: number;
  tokenPageUrl: string;
  note: string;
};

/** AVDB 开放接口：令牌走请求头 X-API-Key，令牌页在 {baseUrl}/tokens */
export async function getAvdbSettings(): Promise<AvdbSettings> {
  const res = await apiFetch('/settings/avdb');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AvdbSettings>).data;
}

export async function putAvdbSettings(body: {
  enabled: boolean;
  baseUrl: string;
  apiKey?: string;
  timeoutSec?: number;
  note?: string;
}): Promise<AvdbSettings> {
  const res = await apiFetch('/settings/avdb', {
    method: 'PUT',
    body: JSON.stringify({
      enabled: body.enabled,
      baseUrl: body.baseUrl,
      apiKey: body.apiKey || '',
      timeoutSec: body.timeoutSec ?? 15,
      note: body.note || '',
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AvdbSettings>).data;
}

export async function testAvdb(): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/avdb/health');
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{
    ok: boolean;
    configured: boolean;
    baseUrl: string;
    message: string;
  }>;
  return {
    ok: Boolean(json.data?.ok),
    message: json.data?.message || json.message || '',
  };
}

export type MoviePilotSettings = {
  enabled: boolean;
  baseUrl: string;
  hasApiKey: boolean;
  timeoutSec: number;
  note: string;
};

/** MoviePilot 开放接口：令牌走 ?apikey= 查询参数 */
export async function getMoviePilotSettings(): Promise<MoviePilotSettings> {
  const res = await apiFetch('/settings/moviepilot');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<MoviePilotSettings>).data;
}

export async function putMoviePilotSettings(body: {
  enabled: boolean;
  baseUrl: string;
  apiKey?: string;
  timeoutSec?: number;
  note?: string;
}): Promise<MoviePilotSettings> {
  const res = await apiFetch('/settings/moviepilot', {
    method: 'PUT',
    body: JSON.stringify({
      enabled: body.enabled,
      baseUrl: body.baseUrl,
      apiKey: body.apiKey || '',
      timeoutSec: body.timeoutSec ?? 15,
      note: body.note || '',
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<MoviePilotSettings>).data;
}

export async function testMoviePilot(): Promise<{
  ok: boolean;
  message: string;
}> {
  const res = await apiFetch('/moviepilot/health');
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{
    ok: boolean;
    configured: boolean;
    baseUrl: string;
    message: string;
  }>;
  return {
    ok: Boolean(json.data?.ok),
    message: json.data?.message || json.message || '',
  };
}

export type MorePlaySettings = {
  enabled: boolean;
  baseUrl: string;
  timeoutSec: number;
  searchSite: string;
};

export type MorePlaySite = {
  id: string;
  name: string;
};

/** MorePlay（CatPawOpen）影视在线播放服务 */
export async function getMorePlaySettings(): Promise<MorePlaySettings> {
  const res = await apiFetch('/settings/moreplay');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<MorePlaySettings>).data;
}

export async function putMorePlaySettings(body: {
  enabled: boolean;
  baseUrl: string;
  timeoutSec?: number;
  searchSite?: string;
}): Promise<MorePlaySettings> {
  const res = await apiFetch('/settings/moreplay', {
    method: 'PUT',
    body: JSON.stringify({
      enabled: body.enabled,
      baseUrl: body.baseUrl,
      timeoutSec: body.timeoutSec ?? 15,
      searchSite: body.searchSite || 'nodejs_wogg',
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<MorePlaySettings>).data;
}

export async function getMorePlaySites(): Promise<MorePlaySite[]> {
  const res = await apiFetch('/moreplay/sites');
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{ sites: MorePlaySite[] }>;
  return Array.isArray(json.data?.sites) ? json.data.sites : [];
}

export async function testMorePlay(): Promise<{
  ok: boolean;
  message: string;
  serviceName?: string;
  siteCount?: number;
}> {
  const res = await apiFetch('/moreplay/health');
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{
    ok: boolean;
    configured: boolean;
    baseUrl: string;
    message: string;
    serviceName?: string;
    siteCount?: number;
  }>;
  return {
    ok: Boolean(json.data?.ok),
    message: json.data?.message || json.message || '',
    serviceName: json.data?.serviceName,
    siteCount: json.data?.siteCount,
  };
}
