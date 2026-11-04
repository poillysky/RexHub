/**
 * PWA 管理接口：插件、Stremio 插件库、NAS 服务卡片、115 网盘。
 *
 * 后端原 /admin HTML 管理台已移除，写操作改由这里调用 /api/admin/*（Web 会话 Cookie）。
 * 对外统一从 `@/lib/api` 导入。
 */
import { API_BASE, apiFetch, parseError } from './client';
import type { Envelope } from './client';

export type AdminOption = { key?: string; label: string; minutes?: number };

export type PluginRow = {
  id: string;
  title: string;
  title_override?: string;
  description?: string;
  description_override?: string;
  version?: string;
  required_version?: string;
  author?: string;
  category?: string;
  enabled?: boolean;
  note?: string;
  api_url?: string;
  api_key?: string;
  proxy_url?: string;
  proxy_enabled?: boolean;
  source_bytes?: number;
  source_encrypted?: boolean;
  source_error?: string;
  updated_at?: number;
  analysis?: { ok?: boolean; error?: string; modules?: unknown[] };
};

export type FeedWidget = PluginRow & { url?: string; source_file?: string };

export type PluginFeed = {
  url: string;
  title?: string;
  widgets?: FeedWidget[];
  updated_at?: number;
  error?: string;
};

export type PluginCatalog = {
  plugins: PluginRow[];
  feeds: PluginFeed[];
  auto_update: {
    enabled: boolean;
    interval_minutes: number;
    last_run: number;
    last_result: string;
  };
  stats: { total: number; enabled: number; feeds: number };
  categories: { key: string; label: string }[];
  intervals: { minutes: number; label: string }[];
};

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

export const getAdminPlugins = () => json<PluginCatalog>(apiFetch('/admin/plugins'));

export const savePlugin = (source: string, category: string) =>
  json<{ id: string; title: string; created: boolean }>(
    send('/admin/plugins', 'POST', { source, category }),
  );

export const updatePlugin = (
  id: string,
  body: {
    title?: string;
    description?: string;
    note?: string;
    apiUrl?: string;
    apiKey?: string;
    proxyUrl?: string;
    proxyEnabled?: boolean;
    enabled?: boolean;
    category?: string;
  },
) => json<PluginRow>(send(`/admin/plugins/${encodeURIComponent(id)}`, 'PUT', body));

export const setPluginEnabled = (id: string, enabled: boolean) =>
  json<{ ok: boolean }>(
    send(`/admin/plugins/${encodeURIComponent(id)}/enabled`, 'PUT', { enabled }),
  );

export const deletePlugin = (id: string) =>
  json<{ ok: boolean }>(send(`/admin/plugins/${encodeURIComponent(id)}`, 'DELETE'));

export const addPluginFeed = (url: string) =>
  json<PluginFeed>(send('/admin/plugins/feeds', 'POST', { url }));

export const deletePluginFeed = (url: string) =>
  json<{ ok: boolean }>(
    send(`/admin/plugins/feeds?url=${encodeURIComponent(url)}`, 'DELETE'),
  );

export const refreshPluginFeed = (url: string) =>
  json<PluginFeed>(send('/admin/plugins/feeds/refresh', 'POST', { url }));

export const refreshAllPluginFeeds = () =>
  json<{ total: number; ok: number; errors: string[] }>(
    send('/admin/plugins/feeds/refresh-all', 'POST'),
  );

export const updatePluginFeedWidget = (body: {
  feedUrl: string;
  widgetId: string;
  title?: string;
  description?: string;
  note?: string;
  apiUrl?: string;
  enabled?: boolean;
}) => json<FeedWidget>(send('/admin/plugins/feeds/widget', 'PUT', body));

export const setPluginFeedWidgetEnabled = (
  feedUrl: string,
  widgetId: string,
  enabled: boolean,
) =>
  json<FeedWidget>(
    send('/admin/plugins/feeds/widget/enabled', 'PUT', { feedUrl, widgetId, enabled }),
  );

export const setPluginAutoUpdate = (enabled: boolean, interval?: number) =>
  json<PluginCatalog['auto_update']>(
    send(`/admin/plugins/auto-update?interval=${interval || 0}`, 'PUT', { enabled }),
  );

// ---------- Stremio 插件库 ----------

export type StremioAddon = {
  slug: string;
  id?: string;
  transport?: string;
  manifest_url?: string;
  manifest?: { name?: string; description?: string; types?: string[]; version?: string };
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
};

export type StremioCatalog = {
  repositories: StremioRepository[];
  addons: StremioAddon[];
  stats: { repositories: number; addons: number; enabled: number };
  presets: { title: string; url: string }[];
  official: string;
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

// ---------- NAS 服务 ----------

export type ServiceItem = {
  id: string;
  name: string;
  category: string;
  categoryLabel?: string;
  host: string;
  port: number;
  url: string;
  notes: string;
  online?: boolean | null;
  latency?: number | null;
};

export type ServiceCatalog = {
  items: ServiceItem[];
  categories: { key: string; label: string }[];
};

export const getAdminServices = () =>
  json<ServiceCatalog>(apiFetch('/admin/services'));

export type ServiceProbe = {
  items: (ServiceItem & { categoryLabel: string })[];
  online: number;
  total: number;
};

/** App 侧只读服务卡片（带端口探测在线状态），供「服务管理」展示。 */
export async function getServiceProbes(): Promise<ServiceProbe> {
  const res = await apiFetch('/services');
  if (!res.ok) throw new Error(await parseError(res));
  const data = (await res.json()) as { items?: ServiceItem[] };
  const items = (data.items || []).map((item) => ({
    ...item,
    categoryLabel: item.categoryLabel || '',
  }));
  return {
    items,
    total: items.length,
    online: items.filter((item) => item.online).length,
  };
}

export const saveAdminService = (body: Partial<ServiceItem>) =>
  json<{ ok: boolean; id: string; created: boolean }>(
    send('/admin/services', 'POST', body),
  );

export const deleteAdminService = (id: string) =>
  json<{ ok: boolean }>(send(`/admin/services/${encodeURIComponent(id)}`, 'DELETE'));

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

/** 读取 115 登录状态（PWA 走 Web 会话，不必带 Bearer）。 */
export async function getPan115Account(): Promise<{
  configured: boolean;
  cookieHint?: string;
}> {
  const res = await apiFetch('/pan/account');
  if (!res.ok) return { configured: false };
  const data = (await res.json()) as { configured?: boolean; cookieHint?: string };
  return { configured: Boolean(data?.configured), cookieHint: data?.cookieHint };
}

/** 账号详情：与 iOS 共用 /pan/account；115 未绑定时返回 null，不抛错。 */
export async function getPan115Snapshot(): Promise<Pan115Account | null> {
  const res = await apiFetch('/pan/account');
  if (!res.ok) return null;
  const data = (await res.json()) as (Pan115Account & { bound?: boolean }) | null;
  return data && data.bound !== false ? data : null;
}
