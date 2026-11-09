/**
 * 资源浏览 / 搜索 / 翻译
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { apiFetch, parseError } from './client';
import type { Envelope } from './client';
import type { BrowseResult, ResourceItem } from '@/types/resource';

export async function fetchBrowse(opts: {
  page?: number;
  pageSize?: number;
  boardFid?: string;
  board?: string;
  boardParent?: string;
  keyword?: string;
  withTotalCount?: boolean;
  signal?: AbortSignal;
}): Promise<BrowseResult> {
  const q = new URLSearchParams();
  q.set('p', String(opts.page ?? 1));
  q.set('ps', String(opts.pageSize ?? 10));
  q.set('withTotalCount', opts.withTotalCount === true ? '1' : '0');
  if (opts.boardFid) q.set('board_fid', opts.boardFid);
  if (opts.board) q.set('board', opts.board);
  if (opts.boardParent) q.set('board_parent', opts.boardParent);
  if (opts.keyword?.trim()) q.set('keyword', opts.keyword.trim());
  const res = await apiFetch(`/browse?${q}`, { signal: opts.signal });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<BrowseResult>).data;
}

export async function fetchTranslate(
  text: string,
  opts?: { target?: 'en' | 'zh' | string },
): Promise<{
  text: string;
  alreadyEnglish: boolean;
  alreadyChinese?: boolean;
  engine?: string;
  target?: string;
}> {
  const res = await apiFetch('/translate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      text,
      target: opts?.target || 'en',
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (
    (await res.json()) as Envelope<{
      text: string;
      alreadyEnglish: boolean;
      alreadyChinese?: boolean;
      engine?: string;
      target?: string;
    }>
  ).data;
}

export async function fetchResource(
  hash: string,
  signal?: AbortSignal,
): Promise<ResourceItem> {
  const res = await apiFetch(`/resources/${encodeURIComponent(hash)}`, {
    signal,
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<ResourceItem>).data;
}

