'use client';

import {
  createContext,
  useContext,
  useCallback,
  useRef,
  useState,
  useEffect,
  useSyncExternalStore,
  type ReactNode,
} from 'react';
import { unlockPinnedPage, pinDocumentScroll } from '@/lib/iosKeyboard';
import {
  initNavDepth,
  NAV_EVENT,
  navPush,
  rememberedTabUrl,
  tabFromHash,
} from './nav/urlNav';

/** 主 Tab：仓库 / 影视 / 片商 / 短剧 / 更多 */
export const TAB_ROUTES = ['/', '/media', '/makers', '/drama', '/settings'] as const;
export type TabRoute = (typeof TAB_ROUTES)[number];

function readTabFromLocation(): TabRoute | null {
  if (typeof window === 'undefined') return null;
  const path = window.location.pathname;
  if (TAB_ROUTES.includes(path as TabRoute) && path !== '/') {
    return path as TabRoute;
  }
  if (window.location.hash) return tabFromHash(window.location.hash);
  return '/';
}

interface TabContextValue {
  activeTab: TabRoute;
  /** 当前 Tab 索引（指示条 / 轨道位移） */
  scrollProgress: number;
  scrollToTab: (tab: TabRoute) => void;
  /** 再次点击当前 Tab：子页应回到 Hub */
  tabReselect: number;
}

function subscribeTabLocation(onChange: () => void) {
  window.addEventListener('hashchange', onChange);
  window.addEventListener('popstate', onChange);
  window.addEventListener(NAV_EVENT, onChange);
  return () => {
    window.removeEventListener('hashchange', onChange);
    window.removeEventListener('popstate', onChange);
    window.removeEventListener(NAV_EVENT, onChange);
  };
}

const TabCtx = createContext<TabContextValue | null>(null);

export function useTabNavigation() {
  return useContext(TabCtx);
}

export function TabProvider({ children }: { children: ReactNode }) {
  /** 水合前的服务端快照固定为 null，水合后自动换成真实 hash/path */
  const locatedTab = useSyncExternalStore(
    subscribeTabLocation,
    readTabFromLocation,
    () => null,
  );
  const [tabReselect, setTabReselect] = useState(0);
  /** 地址栏即 Tab 真相：返回 / 前进跨 Tab 时自动跟随 */
  const activeTab = locatedTab ?? '/';
  const scrollProgress = TAB_ROUTES.indexOf(activeTab);
  const activeTabRef = useRef<TabRoute>(activeTab);

  useEffect(() => {
    activeTabRef.current = activeTab;
  }, [activeTab]);

  useEffect(() => {
    initNavDepth();
  }, []);

  const prepareTabSwitch = useCallback(() => {
    const root = document.documentElement;
    const active = document.activeElement;
    if (active instanceof HTMLElement) {
      try {
        active.blur();
      } catch {
        /* ignore */
      }
    }
    root.dataset.keyboard = '0';
    root.style.setProperty('--keyboard-inset', '0px');
    root.style.setProperty('--form-keyboard-inset', '0px');
    root.style.setProperty('--form-lift', '0px');
    delete root.dataset.formKeyboard;
    delete root.dataset.pageLock;
    delete root.dataset.scrollLock;
    try {
      unlockPinnedPage();
      pinDocumentScroll();
    } catch {
      /* ignore */
    }
  }, []);

  const scrollToTab = useCallback(
    (tab: TabRoute) => {
      const index = TAB_ROUTES.indexOf(tab);
      if (index === -1) return;

      prepareTabSwitch();

      // 再次点当前 Tab → 通知子页回到 Hub（iOS 习惯）
      if (tab === activeTabRef.current) {
        setTabReselect((n) => n + 1);
        return;
      }

      // 压一层历史：系统返回可以回到上一个浏览页面；
      // navPush 会触发 NAV_EVENT，activeTab 随地址栏更新。
      navPush(rememberedTabUrl(tab));
    },
    [prepareTabSwitch],
  );

  return (
    <TabCtx.Provider
      value={{
        activeTab,
        scrollProgress,
        scrollToTab,
        tabReselect,
      }}
    >
      {children}
    </TabCtx.Provider>
  );
}
