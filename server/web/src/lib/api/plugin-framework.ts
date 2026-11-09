/**
 * 插件框架管理接口（/api/admin/plugin-framework）。
 *
 * 插件 = Manifest 描述的统一扩展：能力（capabilities）、运行时（runtime）、
 * 配置表单（config）全部由后端声明，前端只负责渲染与操作。
 */

import { apiFetch, parseError } from './client';

export type PluginConfigField = {
  key: string;
  title: string;
  type: 'text' | 'password' | 'number' | 'boolean' | 'select' | 'textarea';
  default?: string;
  description?: string;
  required?: boolean;
  secret?: boolean;
  options?: { value: string; label: string }[];
};

export type PluginEndpoint = { path: string; method: string };

export type PluginRuntime = {
  type: 'http' | 'shared' | 'isolated';
  engine?: string;
  entrypoint?: string;
  port?: number;
  base_url?: string;
};

export type WidgetModule = {
  id: string;
  title: string;
  functionName: string;
  type: string;
  cacheDuration?: number;
  requiresWebView?: boolean;
  params?: unknown[];
};

export type WidgetMeta = {
  id?: string;
  title?: string;
  version?: string;
  description?: string;
  author?: string;
  detailCacheDuration?: number;
  globalParams?: unknown[];
  modules?: WidgetModule[];
  search?: { title?: string; functionName?: string; params?: unknown[] } | null;
};

export type PluginUi = {
  shortdrama?: {
    title?: string;
    subtitle?: string;
    accent?: string;
    icon?: string;
    logo?: string;
    badge?: string;
  };
};

export type PluginEntry = {
  id: string;
  name: string;
  description?: string;
  author?: string;
  category?: string;
  protocol?: 'native' | 'widget-js' | 'stremio' | 'process';
  api_version?: string;
  version?: string;
  installed_version?: string;
  capabilities?: string[];
  endpoints?: Record<string, PluginEndpoint>;
  runtime?: PluginRuntime;
  permissions?: string[];
  enabled: boolean;
  running: boolean;
  installed?: boolean;
  proxy?: boolean;
  proxy_available?: boolean;
  show_in_drama?: boolean;
  ui?: PluginUi;
  state?: string;
  error?: string;
  port?: number;
  base_url?: string;
  uptime?: number;
  restarts?: number;
  started_at?: number | null;
  source_repo?: string;
  source_repo_url?: string;
  source_manifest?: string;
  config?: Record<string, string>;
  healthcheck?: string;
  widget_meta?: WidgetMeta | null;
};

export type PluginFrameworkRepository = {
  id: string;
  name: string;
  url: string;
  branch?: string;
  index_path?: string;
  format?: string;
  enabled: boolean;
  owner?: string;
  repo?: string;
  created_at?: number;
  updated_at?: number;
};

export type PluginMarketEntry = PluginEntry & {
  repository: string;
  repository_url?: string;
  installed: boolean;
  installed_version: string;
  update_available: boolean;
  manifest?: string;
  release?: string;
  sha256?: string;
};

export type PluginMarket = {
  plugins: PluginMarketEntry[];
  errors: { repository: string; error: string }[];
  fetched_at: number;
};

export type PluginOverview = {
  runtime: { node: string };
  repositories: PluginFrameworkRepository[];
  installed: PluginEntry[];
};

export type PluginUpdate = {
  id: string;
  name: string;
  repository: string;
  installed_version: string;
  latest_version: string;
  category?: string;
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

export const getPluginOverview = () =>
  json<PluginOverview>(apiFetch('/admin/plugin-framework'));

export const getInstalledPlugins = () =>
  json<{ items: PluginEntry[] }>(apiFetch('/admin/plugin-framework/installed'));

export const addPluginRepository = (body: {
  id?: string;
  name?: string;
  url: string;
  branch?: string;
  index_path?: string;
  format?: string;
}) =>
  json<{ repository: PluginFrameworkRepository }>(
    send('/admin/plugin-framework/repositories', 'POST', body),
  );

export const deletePluginRepository = (id: string) =>
  json<{ ok: boolean }>(
    send(`/admin/plugin-framework/repositories/${encodeURIComponent(id)}`, 'DELETE'),
  );

export const refreshPluginRepository = (id: string) =>
  json<{
    repository: PluginFrameworkRepository;
    name: string;
    branch: string;
    fetched_at: number;
    entries: PluginMarketEntry[];
  }>(send(`/admin/plugin-framework/repositories/${encodeURIComponent(id)}/refresh`, 'POST'));

export const getPluginMarket = (repository = '') => {
  const query = repository ? `?repository=${encodeURIComponent(repository)}` : '';
  return json<PluginMarket>(apiFetch(`/admin/plugin-framework/market${query}`));
};

export const getPluginUpdates = () =>
  json<{ items: PluginUpdate[] }>(apiFetch('/admin/plugin-framework/updates'));

export const installPlugin = (repository: string, id: string) =>
  json<{ plugin: PluginEntry; error: string }>(
    send('/admin/plugin-framework/install', 'POST', { repository, id }),
  );

export const updatePlugin = (id: string) =>
  json<{ plugin: PluginEntry; error: string }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/update`, 'POST'),
  );

export const rollbackPlugin = (id: string) =>
  json<{ plugin: PluginEntry; error: string }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/rollback`, 'POST'),
  );

export const enablePlugin = (id: string) =>
  json<{ plugin: PluginEntry; error: string }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/enable`, 'POST'),
  );

export const disablePlugin = (id: string) =>
  json<{ plugin: PluginEntry; error: string }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/disable`, 'POST'),
  );

export const restartPlugin = (id: string) =>
  json<{ plugin: PluginEntry; error: string }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/restart`, 'POST'),
  );

export const getPluginConfig = (id: string) =>
  json<{ config: Record<string, string>; fields: PluginConfigField[]; saved?: string[] }>(
    apiFetch(`/admin/plugin-framework/${encodeURIComponent(id)}/config`),
  );

export const savePluginConfig = (id: string, config: Record<string, string>) =>
  json<{ plugin: PluginEntry; restarted: boolean }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/config`, 'PUT', { config }),
  );

export const savePluginProxy = (id: string, enabled: boolean) =>
  json<{ plugin: PluginEntry; restarted: boolean; error?: string }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/proxy`, 'PUT', { enabled }),
  );

export const savePluginShortdrama = (id: string, enabled: boolean) =>
  json<{ plugin: PluginEntry; enabled: boolean }>(
    send(`/admin/plugin-framework/${encodeURIComponent(id)}/shortdrama`, 'PUT', { enabled }),
  );

export const exportPluginJs = (id: string, baseUrl = '') => {
  const query = baseUrl ? `?base_url=${encodeURIComponent(baseUrl)}` : '';
  return json<{
    filename: string;
    content: string;
    mode: 'source' | 'http' | 'bridge';
    base_url: string;
  }>(apiFetch(`/admin/plugin-framework/${encodeURIComponent(id)}/export${query}`));
};

export const getPluginLogs = (id: string, limit = 120) =>
  json<{ id: string; lines: string[] }>(
    apiFetch(`/admin/plugin-framework/${encodeURIComponent(id)}/logs?limit=${limit}`),
  );

export const getPluginHealth = (id: string) =>
  json<{ ok: boolean; status: number; url?: string; error?: string }>(
    apiFetch(`/admin/plugin-framework/${encodeURIComponent(id)}/health`),
  );

export const uninstallPlugin = (id: string, purgeData = false) =>
  json<{ ok: boolean; data_kept: boolean }>(
    send(
      `/admin/plugin-framework/${encodeURIComponent(id)}?purge_data=${purgeData ? 'true' : 'false'}`,
      'DELETE',
    ),
  );

