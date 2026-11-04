/** 设置 Hub 条目状态缓存：避免每次打开「更多」都全量打接口 */

export type SettingsHubTone = 'ok' | 'warn' | 'mute';

export type SettingsHubEntryId =
  | 'users'
  | 'bitmagnet'
  | 'p115'
  | 'network'
  | 'cloudsaver'
  | 'ai'
  | 'forum'
  | 'appearance'
  | 'video'
  | 'drama'
  | 'maker'
  | 'subtitle'
  | 'danmu'
  | 'stremio';

/** 单个插件分类的启用情况 → Hub 显示文案与色标 */
export function pluginCategoryStatus(
  items: { category?: string; enabled?: boolean }[],
  category: string,
): { text: string; tone: SettingsHubTone } {
  const rows = items.filter((item) => item.category === category);
  if (!rows.length) return { text: '未添加', tone: 'mute' };
  const on = rows.filter((row) => row.enabled !== false).length;
  return { text: `${on}/${rows.length} 启用`, tone: on ? 'ok' : 'warn' };
}

export type SettingsHubMeta = Record<
  SettingsHubEntryId,
  { text: string; tone: SettingsHubTone }
>;

const TTL_MS = 90_000;

let cachedMeta: SettingsHubMeta | null = null;
let cachedAt = 0;

export function getCachedSettingsHubMeta(): SettingsHubMeta | null {
  return cachedMeta;
}

const APPEARANCE_TEXT: Record<string, string> = {
  system: '系统',
  light: '浅色',
  dark: '深色',
};

/** 外观状态来自本机 localStorage，不依赖后端；兜底旧缓存缺项与过期值 */
export function withAppearanceStatus(
  meta: SettingsHubMeta,
  mode: string,
): SettingsHubMeta {
  return {
    ...meta,
    appearance: { text: APPEARANCE_TEXT[mode] ?? '系统', tone: 'mute' },
  };
}

export function setCachedSettingsHubMeta(meta: SettingsHubMeta): void {
  cachedMeta = meta;
  cachedAt = Date.now();
}

export function patchCachedSettingsHubMeta(
  id: SettingsHubEntryId,
  text: string,
  tone: SettingsHubTone,
): void {
  if (!cachedMeta) return;
  cachedMeta = { ...cachedMeta, [id]: { text, tone } };
  cachedAt = Date.now();
}

export function isSettingsHubMetaFresh(ttlMs = TTL_MS): boolean {
  return cachedMeta != null && Date.now() - cachedAt < ttlMs;
}

export function clearSettingsHubMetaCache(): void {
  cachedMeta = null;
  cachedAt = 0;
}
