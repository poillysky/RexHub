'use client';

import { useEffect, useMemo, useRef } from 'react';
import { useTabNavigation, type TabRoute } from '../TabContext';
import {
  currentUrl,
  navBack,
  navPush,
  navReplace,
  readHashRoute,
  rememberTabUrl,
  type HashRoute,
} from './urlNav';

/**
 * 监听浏览器前进/后退，把地址栏解析回页面状态。
 * 挂载时也会执行一次，因此刷新 / 分享直达可以还原当前页。
 */
export function useTabLocation(
  tab: TabRoute,
  apply: (route: HashRoute) => void,
): void {
  const applyRef = useRef(apply);

  useEffect(() => {
    applyRef.current = apply;
  }, [apply]);

  useEffect(() => {
    const run = () => {
      const route = readHashRoute(tab);
      if (route) applyRef.current(route);
    };
    run();
    window.addEventListener('popstate', run);
    return () => window.removeEventListener('popstate', run);
  }, [tab]);
}

/**
 * 页面状态 → 地址栏（replace）。
 * 只在该 Tab 可见时写入，避免后台页面改掉当前地址。
 * 首次挂载只登记不写入，给深链解析让路。
 */
export function useTabUrlSync(tab: TabRoute, href: string): void {
  const tabCtx = useTabNavigation();
  const active = tabCtx?.activeTab === tab;
  const first = useRef(true);

  useEffect(() => {
    if (!active) return;
    rememberTabUrl(tab, href);
    if (first.current) {
      first.current = false;
      return;
    }
    if (currentUrl() !== href) navReplace(href);
  }, [active, href, tab]);
}

/** 进页 / 返回：页面本身仍用 React state 渲染，历史只负责顺序 */
export function usePageHistory(
  tab: TabRoute,
  fallbackHref: string,
  onFallback: () => void,
) {
  const fallbackRef = useRef(onFallback);

  useEffect(() => {
    fallbackRef.current = onFallback;
  }, [onFallback]);

  return useMemo(
    () => ({
      push(href: string) {
        navPush(href);
        rememberTabUrl(tab, href);
      },
      replace(href: string) {
        navReplace(href);
        rememberTabUrl(tab, href);
      },
      back() {
        const wentBack = navBack(fallbackHref);
        if (!wentBack) fallbackRef.current();
      },
    }),
    [tab, fallbackHref],
  );
}
