/**
 * 资源库 / Bitmagnet 连接与备份
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { apiFetch, parseError } from './client';
import type { Envelope } from './client';
import type { ResourceDbConfig } from '@/types/resource';

export async function getResourceDb(): Promise<ResourceDbConfig> {
  const res = await apiFetch('/settings/resource-db');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<ResourceDbConfig>).data;
}

export async function putResourceDb(body: {
  enabled: boolean;
  dsn: string;
  note: string;
}): Promise<ResourceDbConfig> {
  const res = await apiFetch('/settings/resource-db', {
    method: 'PUT',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<ResourceDbConfig>).data;
}

export async function testResourceDb(dsn: string): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/settings/resource-db/test', {
    method: 'POST',
    body: JSON.stringify({ enabled: true, dsn, note: '' }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{ ok: boolean }> & { message: string };
  return { ok: Boolean(json.data?.ok), message: json.message || '' };
}

export type ResourceDbBackupItem = {
  filename: string;
  relPath: string;
  bytes: number;
  mtime: string;
};

export type ResourceDbBackupExportResult = {
  filename: string;
  relPath: string;
  bytes: number;
  elapsedMs: number;
  createdAt: string;
  tables: Array<{ name: string; rows: number; bytes: number; elapsedMs: number }>;
};

/** 导出/导入的实时进度（后端按库类型维护单槽） */
export type DbBackupProgress = {
  action: 'export' | 'import' | null;
  percent: number;
  message: string;
  running: boolean;
};

async function fetchBackupProgress(path: string): Promise<DbBackupProgress> {
  const res = await apiFetch(path);
  if (!res.ok) throw new Error(await parseError(res));
  const data = ((await res.json()) as Envelope<DbBackupProgress>).data;
  return {
    action: data?.action || null,
    percent: Math.max(0, Math.min(100, Math.round(Number(data?.percent) || 0))),
    message: data?.message || '',
    running: Boolean(data?.running),
  };
}

export function getResourceDbBackupProgress(): Promise<DbBackupProgress> {
  return fetchBackupProgress('/settings/resource-db/backups/progress');
}

export function getBitmagnetDbBackupProgress(): Promise<DbBackupProgress> {
  return fetchBackupProgress('/settings/bitmagnet-db/backups/progress');
}

export async function listResourceDbBackups(): Promise<ResourceDbBackupItem[]> {
  const res = await apiFetch('/settings/resource-db/backups');
  if (!res.ok) throw new Error(await parseError(res));
  const data = ((await res.json()) as Envelope<{ items: ResourceDbBackupItem[] }>).data;
  return data?.items || [];
}

export async function exportResourceDbBackup(): Promise<ResourceDbBackupExportResult> {
  const res = await apiFetch('/settings/resource-db/backups/export', { method: 'POST' });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<ResourceDbBackupExportResult>).data;
}

export async function uploadImportResourceDbBackup(
  file: File,
): Promise<{
  filename: string;
  bytes: number;
  elapsedMs: number;
  tables: Array<{ name: string; rows: number }>;
}> {
  const body = new FormData();
  body.append('file', file);
  const res = await apiFetch('/settings/resource-db/backups/upload-import', {
    method: 'POST',
    body,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (
    (await res.json()) as Envelope<{
      filename: string;
      bytes: number;
      elapsedMs: number;
      tables: Array<{ name: string; rows: number }>;
    }>
  ).data;
}

export async function listBitmagnetDbBackups(): Promise<ResourceDbBackupItem[]> {
  const res = await apiFetch('/settings/bitmagnet-db/backups');
  if (!res.ok) throw new Error(await parseError(res));
  const data = ((await res.json()) as Envelope<{ items: ResourceDbBackupItem[] }>).data;
  return data?.items || [];
}

export async function exportBitmagnetDbBackup(): Promise<ResourceDbBackupExportResult> {
  const res = await apiFetch('/settings/bitmagnet-db/backups/export', { method: 'POST' });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<ResourceDbBackupExportResult>).data;
}

export async function uploadImportBitmagnetDbBackup(
  file: File,
): Promise<{
  filename: string;
  bytes: number;
  elapsedMs: number;
  tables: Array<{ name: string; rows: number }>;
}> {
  const body = new FormData();
  body.append('file', file);
  const res = await apiFetch('/settings/bitmagnet-db/backups/upload-import', {
    method: 'POST',
    body,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (
    (await res.json()) as Envelope<{
      filename: string;
      bytes: number;
      elapsedMs: number;
      tables: Array<{ name: string; rows: number }>;
    }>
  ).data;
}

export type BitmagnetDbConfig = ResourceDbConfig;

export async function getBitmagnetDb(): Promise<BitmagnetDbConfig> {
  const res = await apiFetch('/settings/bitmagnet-db');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<BitmagnetDbConfig>).data;
}

export async function putBitmagnetDb(body: {
  enabled: boolean;
  dsn: string;
  note: string;
}): Promise<BitmagnetDbConfig> {
  const res = await apiFetch('/settings/bitmagnet-db', {
    method: 'PUT',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<BitmagnetDbConfig>).data;
}

export async function testBitmagnetDb(
  dsn: string,
): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/settings/bitmagnet-db/test', {
    method: 'POST',
    body: JSON.stringify({ enabled: true, dsn, note: '' }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{ ok: boolean }> & { message: string };
  return { ok: Boolean(json.data?.ok), message: json.message || '' };
}

/* —— Settings: TMDB / 115 / forum —— */

