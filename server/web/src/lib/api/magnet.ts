/**
 * 磁力搜索、盘搜、CloudSaver
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { apiFetch, parseError } from './client';
import type { Envelope } from './client';

export type MagnetFile = {
  index: number;
  path: string;
  size: number;
  extension?: string;
};

export type MagnetHit = {
  title: string;
  path: string;
  hash?: string;
  name?: string;
  infoHash?: string;
  detailUrl?: string;
  size?: number;
  sizeText?: string;
  fileCount?: number | null;
  files_count?: number | null;
  files?: MagnetFile[] | null;
  single_file?: boolean;
  seeders?: number | null;
  leechers?: number | null;
  created_at?: number;
  createdAt?: string;
  magnet?: string | null;
  magnet_uri?: string | null;
  magnets?: string[] | null;
};

export type CloudSaverSettings = {
  enabled: boolean;
  baseUrl: string;
  username: string;
  hasPassword?: boolean;
  timeoutSec: number;
  note?: string;
};

export async function getCloudSaverSettings(): Promise<CloudSaverSettings> {
  const res = await apiFetch('/settings/cloudsaver');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<CloudSaverSettings>).data;
}

export async function putCloudSaverSettings(body: {
  enabled: boolean;
  baseUrl: string;
  username: string;
  password?: string;
  timeoutSec?: number;
  note?: string;
}): Promise<CloudSaverSettings> {
  const res = await apiFetch('/settings/cloudsaver', {
    method: 'PUT',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<CloudSaverSettings>).data;
}

export async function testCloudSaver(body: {
  baseUrl: string;
  username: string;
  password?: string;
  timeoutSec?: number;
}): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/cloudsaver/test', {
    method: 'POST',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = ((await res.json()) as Envelope<{ ok?: boolean; message?: string }>).data;
  return {
    ok: Boolean(data?.ok),
    message: data?.message || (data?.ok ? '登录成功' : '登录失败'),
  };
}

export async function fetchMagnetDetail(
  hash: string,
  signal?: AbortSignal,
): Promise<MagnetHit> {
  const q = new URLSearchParams();
  q.set('hash', hash);
  const res = await apiFetch(`/magnet/detail?${q}`, { signal });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<MagnetHit>).data;
}

export type MagnetPreviewShot = {
  time?: number | null;
  screenshot: string;
};

export type MagnetPreview = {
  hash: string;
  name?: string;
  file_type?: string;
  size?: number;
  count?: number;
  screenshots: MagnetPreviewShot[];
  error?: string;
};

export async function fetchMagnetPreview(
  hash: string,
  signal?: AbortSignal,
): Promise<MagnetPreview> {
  const q = new URLSearchParams();
  q.set('hash', hash);
  const res = await apiFetch(`/magnet/preview?${q}`, { signal });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<MagnetPreview>).data;
}

