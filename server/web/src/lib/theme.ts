/**
 * 外观主题：跟随系统 / 浅色 / 深色。
 *
 * 结果统一落到 <html class="dark theme-dark">（首帧脚本见 app/layout.tsx）：
 * `.dark` 供 Tailwind 变体与既有选择器使用，`theme-dark` 供新样式使用。
 * 不依赖操作系统的媒体查询，手动选深浅色才能真正生效。
 *
 * 主题按设备存在 localStorage；多标签页通过 storage 事件保持一致。
 */

export type ThemeMode = 'system' | 'light' | 'dark';
export type ResolvedTheme = 'light' | 'dark';

export const THEME_KEY = 'theme';

/** 必须与 CSS 的 --app-bg-solid 一致，否则状态栏与内容区会有色差 */
export const THEME_COLOR: Record<ResolvedTheme, string> = {
  light: '#f2f2f7',
  dark: '#05070c',
};

const DARK_QUERY = '(prefers-color-scheme: dark)';
const listeners = new Set<() => void>();

export function getThemeMode(): ThemeMode {
  if (typeof window === 'undefined') return 'system';
  try {
    const v = localStorage.getItem(THEME_KEY);
    if (v === 'light' || v === 'dark') return v;
  } catch {
    /* 隐私模式等取不到存储时按跟随系统 */
  }
  return 'system';
}

export function resolveTheme(mode: ThemeMode): ResolvedTheme {
  if (mode !== 'system') return mode;
  return window.matchMedia(DARK_QUERY).matches ? 'dark' : 'light';
}

function applyThemeClass(resolved: ResolvedTheme): void {
  const root = document.documentElement;
  const dark = resolved === 'dark';
  root.classList.toggle('dark', dark);
  root.classList.toggle('theme-dark', dark);
  root.style.colorScheme = dark ? 'dark' : 'light';
  root.style.backgroundColor = THEME_COLOR[resolved];
  // 可能同时存在带 media 的浅/深两条 theme-color，全部对齐，否则手动切色后状态栏不变
  document.querySelectorAll('meta[name="theme-color"]').forEach((meta) => {
    meta.setAttribute('content', THEME_COLOR[resolved]);
  });
}

function applyTheme(mode: ThemeMode): void {
  applyThemeClass(resolveTheme(mode));
}

function emitTheme(): void {
  listeners.forEach((listener) => listener());
}

/** 订阅主题变化（本标签切换 + 其它标签页修改） */
export function subscribeTheme(onChange: () => void): () => void {
  listeners.add(onChange);
  const onStorage = (event: StorageEvent) => {
    if (event.key === THEME_KEY || event.key === null) onChange();
  };
  window.addEventListener('storage', onStorage);
  return () => {
    listeners.delete(onChange);
    window.removeEventListener('storage', onStorage);
  };
}

export function setThemeMode(mode: ThemeMode): void {
  try {
    if (mode === 'system') localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, mode);
  } catch {
    /* 存不进也不影响本次生效 */
  }
  applyTheme(mode);
  emitTheme();
}

/** 启动时对齐一次，并跟随系统 / 其它标签页的变化实时更新 */
export function initTheme(): () => void {
  const sync = () => applyTheme(getThemeMode());
  sync();
  const mq = window.matchMedia(DARK_QUERY);
  mq.addEventListener('change', sync);
  const onStorage = (event: StorageEvent) => {
    if (event.key === THEME_KEY || event.key === null) sync();
  };
  window.addEventListener('storage', onStorage);
  return () => {
    mq.removeEventListener('change', sync);
    window.removeEventListener('storage', onStorage);
  };
}
