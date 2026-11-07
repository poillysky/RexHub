'use client';

import type { P115SaveSource } from '@/lib/api';

/**
 * 继承类保存来源：影视 / 片商页面跳去搜索时写入，
 * 搜索页默认态 search 不属于"继承来源"，不入此标记。
 */
export type InheritedSaveSource = Exclude<P115SaveSource, 'search'>;

export const P115_SAVE_SOURCE_KEY = 'nextweb:p115-save-source';

/** 保存来源 → 中文名（转存落点展示用） */
export const P115_SOURCE_LABEL: Record<P115SaveSource, string> = {
  search: '搜索',
  media: '影视',
  maker: '片商',
};

const MAKER_LEGACY = new Set([
  'makers',
  'maker',
  'japan_censored',
  'japan_uncensored',
  'japan_amateur',
  'fc2',
  'china',
  'western',
]);

/** 旧 session 值（warehouse / movie / tv / 片商六区）统一收敛到三类 */
function normalizeRaw(raw: string | null): P115SaveSource | null {
  if (!raw) return null;
  if (raw === 'warehouse' || raw === 'search') return 'search';
  if (raw === 'movie' || raw === 'tv' || raw === 'media') return 'media';
  if (raw === 'maker' || MAKER_LEGACY.has(raw)) return 'maker';
  return null;
}

function readStored(fallback: P115SaveSource): P115SaveSource {
  try {
    return normalizeRaw(sessionStorage.getItem(P115_SAVE_SOURCE_KEY)) ?? fallback;
  } catch {
    return fallback;
  }
}

/** 转存落点：override > session 继承 > search */
export function resolveP115SaveSource(
  override?: P115SaveSource | null,
): P115SaveSource {
  return override ?? readStored('search');
}

/** 写入保存来源（供影视 / 片商跳转搜索时调用） */
export function writeSaveSource(source: InheritedSaveSource | 'search'): void {
  try {
    sessionStorage.setItem(P115_SAVE_SOURCE_KEY, source);
  } catch {
    /* ignore */
  }
}

/** 清除保存来源（回到 search 默认态） */
export function clearSaveSource(): void {
  try {
    sessionStorage.removeItem(P115_SAVE_SOURCE_KEY);
  } catch {
    /* ignore */
  }
}
