'use client';

/**
 * 页面栈 URL 内核：把「当前页」写进地址栏 hash，浏览器返回 / 刷新 / 分享都走同一条路径。
 *
 * - 各主 Tab 使用 `#<tab>/<seg>?<query>`，首页沿用原有的 query 方案
 * - 历史层数记在 history.state 里，用于区分「应用内上一页」与「直接打开深链」
 */

import type { TabRoute } from '../TabContext';

const TAB_HASH: Record<TabRoute, string> = {
  '/': 'home',
  '/media': 'media',
  '/makers': 'makers',
  '/drama': 'drama',
  '/settings': 'settings',
};

const HASH_TO_TAB: Record<string, TabRoute> = {
  home: '/',
  media: '/media',
  makers: '/makers',
  drama: '/drama',
  settings: '/settings',
  // 首页内嵌板块沿用的旧 hash
  boards: '/',
};

export type NavQuery = Record<
  string,
  string | number | boolean | null | undefined
>;

/** 解析当前 hash 属于哪个 Tab（未知 hash 归首页，与旧行为一致） */
export function tabFromHash(hash?: string): TabRoute {
  const raw = (hash ?? window.location.hash).replace(/^#/, '');
  const head = raw.split('?')[0].split('/')[0];
  return HASH_TO_TAB[head] ?? '/';
}

/** 生成某个 Tab 下的页面地址（根路径 + hash，清掉首页残留 query） */
export function makeHref(
  tab: TabRoute,
  segments: Array<string | number | null | undefined> = [],
  query: NavQuery = {},
): string {
  const path = segments
    .filter((s) => s !== null && s !== undefined && s !== '')
    .map((s) => encodeURIComponent(String(s)))
    .join('/');
  const qs = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null || value === '' || value === false) {
      continue;
    }
    qs.set(key, value === true ? '1' : String(value));
  }
  const q = qs.toString();
  const hash = `#${TAB_HASH[tab]}${path ? `/${path}` : ''}${q ? `?${q}` : ''}`;
  return `/${hash}`;
}

export type HashRoute = {
  /** hash 中 Tab 之后的路径段（已解码） */
  segments: string[];
  query: URLSearchParams;
};

/** 读取指定 Tab 的 hash 路由；当前地址不属于该 Tab 时返回 null */
export function readHashRoute(tab: TabRoute): HashRoute | null {
  if (typeof window === 'undefined') return null;
  const raw = window.location.hash.replace(/^#/, '');
  if (!raw) return null;
  const [pathPart, queryPart = ''] = raw.split('?');
  const parts = pathPart.split('/').filter(Boolean);
  if (parts[0] !== TAB_HASH[tab]) return null;
  return {
    segments: parts.slice(1).map((s) => {
      try {
        return decodeURIComponent(s);
      } catch {
        return s;
      }
    }),
    query: new URLSearchParams(queryPart),
  };
}

/** 当前完整地址，用于比较是否需要写入历史 */
export function currentUrl(): string {
  return `${window.location.pathname}${window.location.search}${window.location.hash}`;
}

const NAV_DEPTH = '__navDepth';

function nextState(depth: number): Record<string, unknown> {
  return {
    ...((window.history.state as Record<string, unknown> | null) ?? {}),
    [NAV_DEPTH]: depth,
  };
}

/** 历史层数：直接打开的深链为 0，应用内每进一页 +1 */
export function navDepth(): number {
  if (typeof window === 'undefined') return 0;
  const depth = (window.history.state as Record<string, unknown> | null)?.[
    NAV_DEPTH
  ];
  return typeof depth === 'number' ? depth : 0;
}

export function initNavDepth(): void {
  if (typeof window === 'undefined') return;
  if (inited) return;
  inited = true;
  const state = (window.history.state as Record<string, unknown> | null) ?? {};
  if (typeof state[NAV_DEPTH] !== 'number') {
    window.history.replaceState({ ...state, [NAV_DEPTH]: 0 }, '');
  }
  // 系统返回手势 / 浏览器后退不经过 navBack：监听 popstate 按层数变化判方向
  let prevDepth = navDepth();
  window.addEventListener('popstate', () => {
    const depth = navDepth();
    if (depth < prevDepth) markBack();
    prevDepth = depth;
  });
}

let inited = false;

/* ── 导航方向：子页进场动效据此区分「前进（从右滑入）/ 返回（淡入）」 ── */

/** 刚发生返回的时间戳；窗口足够短，不会误伤紧接着的前进操作 */
const BACK_WINDOW = 450;
let backAt = 0;

export function markBack(): void {
  backAt = Date.now();
}

/** 本次挂载是否由「返回」触发 */
export function navDirection(): 'back' | 'forward' {
  return Date.now() - backAt < BACK_WINDOW ? 'back' : 'forward';
}

/** push 后通知订阅者重新读取地址（pushState 本身不触发事件） */
export const NAV_EVENT = 'nextweb:nav';

export function navPush(href: string): void {
  // 前进：清掉返回标记，避免紧接着的新页面被误判成返回
  backAt = 0;
  window.history.pushState(nextState(navDepth() + 1), '', href);
  window.dispatchEvent(new Event(NAV_EVENT));
}

export function navReplace(href: string): void {
  window.history.replaceState(nextState(navDepth()), '', href);
}

/**
 * 返回上一页；深链直接打开（没有应用内历史）时退回 fallback。
 * @returns true 表示已交给浏览器历史，false 表示走了 fallback
 */
export function navBack(fallbackHref: string): boolean {
  markBack();
  if (navDepth() > 0) {
    window.history.back();
    return true;
  }
  navReplace(fallbackHref);
  return false;
}

/* ── 各 Tab 最近一次停留的地址：切 Tab 时原样恢复 ── */

const tabUrls = new Map<TabRoute, string>();

export function rememberTabUrl(tab: TabRoute, href: string): void {
  tabUrls.set(tab, href);
}

export function rememberedTabUrl(tab: TabRoute): string {
  if (tab === '/') return tabUrls.get(tab) ?? '/';
  return tabUrls.get(tab) ?? makeHref(tab);
}
