/**
 * 外观主题：跟随系统 / 浅色 / 深色。
 *
 * 结果统一落到 <html class="theme-dark|theme-light">（首帧脚本见 app/layout.tsx），
 * 全站样式一律用 `html.theme-dark ...` 选择器，**不依赖操作系统的媒体查询**，
 * 这样手动选深浅色才能真正生效。
 */

export type ThemeMode = 'system' | 'light' | 'dark';
export type ResolvedTheme = 'light' | 'dark';

export const THEME_KEY = 'theme';

const THEME_COLOR: Record<ResolvedTheme, string> = {
  light: '#f2f2f7',
  dark: '#000000',
};

const DARK_QUERY = '(prefers-color-scheme: dark)';

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
  root.classList.toggle('theme-light', !dark);
  root.style.colorScheme = dark ? 'dark' : 'light';
  root.style.backgroundColor = THEME_COLOR[resolved];
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute('content', THEME_COLOR[resolved]);
}

/** 立即把主题落到 <html> 与 meta[name=theme-color] 上 */
export function applyTheme(mode: ThemeMode): void {
  document.documentElement.classList.toggle('theme-system', mode === 'system');
  applyThemeClass(resolveTheme(mode));
}

export function setThemeMode(mode: ThemeMode): void {
  try {
    if (mode === 'system') localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, mode);
  } catch {
    /* 存不进也不影响本次生效 */
  }
  applyTheme(mode);
}

/** 跟随系统时监听系统深浅色变化；返回取消函数 */
export function watchSystemTheme(onChange: () => void): () => void {
  const mq = window.matchMedia(DARK_QUERY);
  mq.addEventListener('change', onChange);
  return () => mq.removeEventListener('change', onChange);
}

/** 启动时对齐一次，并在「跟随系统」下随系统切换实时更新类名 */
export function initTheme(): () => void {
  applyTheme(getThemeMode());
  return watchSystemTheme(() => {
    if (getThemeMode() === 'system') applyTheme('system');
  });
}
