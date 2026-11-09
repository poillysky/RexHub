/**
 * PWA 管理接口：Stremio 插件库、NAS 服务卡片、115 网盘。
 *
 * 后端原 /admin HTML 管理台已移除，写操作改由这里调用 /api/admin/*（Web 会话 Cookie）。
 * 对外统一从 `@/lib/api` 导入。
 */
import { apiFetch, parseError } from './client';
import type { MediaStream } from './media';

async function json<T>(res: Promise<Response> | Response): Promise<T> {
  const r = await res;
  if (!r.ok) throw new Error(await parseError(r));
  return (await r.json()) as T;
}

function send(path: string, method: string, body?: unknown): Promise<Response> {
  return apiFetch(path, {
    method,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// ---------- Stremio 插件库 ----------

export type StremioAddon = {
  slug: string;
  id?: string;
  transport?: string;
  manifest_url?: string;
  manifest?: {
    name?: string;
    description?: string;
    types?: string[];
    version?: string;
    logo?: string;
    catalogs?: { type?: string; id?: string; name?: string }[];
    resources?: (string | { name?: string })[];
  };
  repository?: string;
  enabled?: boolean;
  error?: string;
  updated_at?: number;
};

export type StremioRepository = {
  url: string;
  title?: string;
  count?: number;
  error?: string;
  fetched_at?: number;
  /** add_repository 的返回：粘贴单个 manifest 时会作为 addon 接入 */
  kind?: 'repository' | 'addon';
};

export type StremioCatalog = {
  repositories: StremioRepository[];
  addons: StremioAddon[];
  stats: { repositories: number; addons: number; enabled: number };
};

export const getStremioCatalog = () => json<StremioCatalog>(apiFetch('/admin/stremio'));

export const addStremioRepository = (url: string, title = '') =>
  json<StremioRepository>(send('/admin/stremio/repositories', 'POST', { url, title }));

export const refreshStremioRepository = (url: string) =>
  json<StremioRepository>(send('/admin/stremio/repositories/refresh', 'POST', { url }));

export const deleteStremioRepository = (url: string) =>
  json<{ ok: boolean }>(
    send(`/admin/stremio/repositories?url=${encodeURIComponent(url)}`, 'DELETE'),
  );

export const addStremioAddon = (url: string) =>
  json<StremioAddon>(send('/admin/stremio/addons', 'POST', { url }));

export const testStremioAddon = (slug: string) =>
  json<{ ok: boolean; message?: string }>(
    send(`/admin/stremio/addons/${encodeURIComponent(slug)}/test`, 'POST'),
  );

export const setStremioAddonEnabled = (slug: string, enabled: boolean) =>
  json<{ ok: boolean }>(
    send(`/admin/stremio/addons/${encodeURIComponent(slug)}/enabled`, 'PUT', { enabled }),
  );

export const deleteStremioAddon = (slug: string) =>
  json<{ ok: boolean }>(
    send(`/admin/stremio/addons/${encodeURIComponent(slug)}`, 'DELETE'),
  );

// ---------- 单个 addon 的内容浏览 ----------

export type AddonCatalogEntry = {
  key: string;
  type: string;
  id: string;
  name: string;
  extraSupported: string[];
  extraRequired: string[];
  hasSearch: boolean;
  hasGenre: boolean;
  hasSkip: boolean;
  genres: string[];
};

export type AddonCatalogs = {
  slug: string;
  name: string;
  hasStream: boolean;
  hasMeta: boolean;
  hasSubtitles: boolean;
  resources: string[];
  catalogs: AddonCatalogEntry[];
};

export type AddonMeta = {
  id: string;
  type: string;
  name: string;
  poster: string;
  background: string;
  releaseInfo: string;
  rating: string;
  description: string;
};

export type AddonVideo = {
  id: string;
  season: number;
  episode: number;
  name: string;
  overview: string;
  thumbnail: string;
  released: string;
};

export type AddonMetaDetail = {
  meta: AddonMeta | null;
  videos: AddonVideo[];
  addon: string;
  reason: string;
};

export type AddonCatalogPage = {
  items: AddonMeta[];
  total: number;
  hasMore: boolean;
  name: string;
  type: string;
  id: string;
};

export type AddonStreams = {
  streams: MediaStream[];
  total: number;
  addon: string;
  reason: string;
};

export const getAddonCatalogs = (slug: string) =>
  json<AddonCatalogs>(apiFetch(`/admin/stremio/addons/${encodeURIComponent(slug)}/catalogs`));

export const getAddonCatalogItems = (
  slug: string,
  opts: { mediaType: string; id: string; genre?: string; search?: string; skip?: number },
) => {
  const params = new URLSearchParams({ mediaType: opts.mediaType, id: opts.id });
  if (opts.genre) params.set('genre', opts.genre);
  if (opts.search) params.set('search', opts.search);
  if (opts.skip) params.set('skip', String(opts.skip));
  return json<AddonCatalogPage>(
    apiFetch(`/admin/stremio/addons/${encodeURIComponent(slug)}/catalog?${params}`),
  );
};

export const getAddonStreams = (
  slug: string,
  opts: { mediaType: string; id: string; season?: number; episode?: number },
) => {
  const params = new URLSearchParams({ mediaType: opts.mediaType, id: opts.id });
  if (opts.season) params.set('season', String(opts.season));
  if (opts.episode) params.set('episode', String(opts.episode));
  return json<AddonStreams>(
    apiFetch(`/admin/stremio/addons/${encodeURIComponent(slug)}/streams?${params}`),
  );
};

export const getAddonMeta = (slug: string, opts: { mediaType: string; id: string }) => {
  const params = new URLSearchParams({ mediaType: opts.mediaType, id: opts.id });
  return json<AddonMetaDetail>(
    apiFetch(`/admin/stremio/addons/${encodeURIComponent(slug)}/meta?${params}`),
  );
};

// ---------- 115 网盘 ----------

/** 115 账号快照（头像 / 用户名 / VIP / 容量），Web 会话鉴权，Cookie 不出服务端。 */
export type Pan115Account = {
  bound: boolean;
  status: 'ok' | 'invalid' | 'pending' | 'unbound' | string;
  username: string;
  total: number | null;
  used: number | null;
  bound_at: number | null;
  checked_at: number | null;
  message: string;
  avatar: string;
  vip_active: boolean;
  vip_forever: boolean;
  vip_expire: string;
};

/** 账号详情：与 iOS 共用 /pan/account；115 未绑定时返回 null，不抛错。 */
export async function getPan115Snapshot(): Promise<Pan115Account | null> {
  const res = await apiFetch('/pan/account');
  if (!res.ok) return null;
  const data = (await res.json()) as (Pan115Account & { bound?: boolean }) | null;
  return data && data.bound !== false ? data : null;
}

// ---------- NAS 服务卡片 ----------
