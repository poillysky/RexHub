/**
 * 论坛 / 字幕 / 网络设置
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { apiFetch, parseError } from './client';
import type { Envelope } from './client';

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

export type NetworkConfig = {
  proxyUrl?: string;
  proxyEnabled?: boolean;
  configured?: boolean;
  flareSolverrUrl?: string;
  flareSolverrEnabled?: boolean;
  flareSolverrConfigured?: boolean;
  githubApiUrl?: string;
  githubTokenSet?: boolean;
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
  /** 省略表示不改动该字段；空串表示清空 */
  proxyUrl?: string;
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
}): Promise<AvdbSettings> {
  const res = await apiFetch('/settings/avdb', {
    method: 'PUT',
    body: JSON.stringify({
      enabled: body.enabled,
      baseUrl: body.baseUrl,
      apiKey: body.apiKey || '',
      timeoutSec: body.timeoutSec ?? 15,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AvdbSettings>).data;
}

/** 用未保存的草稿测试连接；令牌留空时后端复用已保存的令牌。 */
export async function testAvdb(body: {
  baseUrl: string;
  apiKey?: string;
  timeoutSec?: number;
}): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/avdb/test', {
    method: 'POST',
    body: JSON.stringify({
      baseUrl: body.baseUrl,
      apiKey: body.apiKey || '',
      timeoutSec: body.timeoutSec,
    }),
  });
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
}): Promise<MoviePilotSettings> {
  const res = await apiFetch('/settings/moviepilot', {
    method: 'PUT',
    body: JSON.stringify({
      enabled: body.enabled,
      baseUrl: body.baseUrl,
      apiKey: body.apiKey || '',
      timeoutSec: body.timeoutSec ?? 15,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<MoviePilotSettings>).data;
}

/** 用未保存的草稿测试连接；令牌留空时后端复用已保存的令牌。 */
export async function testMoviePilot(body: {
  baseUrl: string;
  apiKey?: string;
  timeoutSec?: number;
}): Promise<{
  ok: boolean;
  message: string;
}> {
  const res = await apiFetch('/moviepilot/test', {
    method: 'POST',
    body: JSON.stringify({
      baseUrl: body.baseUrl,
      apiKey: body.apiKey || '',
      timeoutSec: body.timeoutSec,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{
    ok: boolean;
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
  /** 自定义搜索站源顺序（最多 3 个，靠前优先） */
  searchSites?: string[];
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
  searchSites?: string[];
}): Promise<MorePlaySettings> {
  const res = await apiFetch('/settings/moreplay', {
    method: 'PUT',
    body: JSON.stringify({
      enabled: body.enabled,
      baseUrl: body.baseUrl,
      timeoutSec: body.timeoutSec ?? 15,
      searchSite: body.searchSite || body.searchSites?.[0] || '',
      searchSites: body.searchSites || (body.searchSite ? [body.searchSite] : []),
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

/** 用未保存的草稿测试连接；地址留空时后端复用已保存的地址。 */
export async function testMorePlay(body: {
  baseUrl: string;
  timeoutSec?: number;
}): Promise<{
  ok: boolean;
  message: string;
  serviceName?: string;
  siteCount?: number;
}> {
  const res = await apiFetch('/moreplay/test', {
    method: 'POST',
    body: JSON.stringify({
      baseUrl: body.baseUrl,
      timeoutSec: body.timeoutSec,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{
    ok: boolean;
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
