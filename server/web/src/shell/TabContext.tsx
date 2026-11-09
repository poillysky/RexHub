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

/** 主 Tab：仓库 / 影视 / 片商 / 短剧 / 更多 */
export const TAB_ROUTES = ['/', '/media', '/makers', '/drama', '/settings'] as const;
export type TabRoute = (typeof TAB_ROUTES)[number];

// 保持 pathname=/，只用 hash，避免命中 app/*/page 的 redirect
function tabToUrl(tab: TabRoute): string {
  if (tab === '/') return '/';
  return `/#${tab.slice(1)}`;
}

function readTabFromLocation(): TabRoute | null {
  const path = window.location.pathname;
  const hash = window.location.hash.replace(/^#/, '');
  const HASH_TO_TAB: Record<string, TabRoute> = {
    media: '/media',
    makers: '/makers',
    drama: '/drama',
    settings: '/settings',
  };
  if (TAB_ROUTES.includes(path as TabRoute) && path !== '/') {
    return path as TabRoute;
  }
  if (hash && HASH_TO_TAB[hash]) return HASH_TO_TAB[hash];
  return null;
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
  return () => {
    window.removeEventListener('hashchange', onChange);
    window.removeEventListener('popstate', onChange);
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
  const [activeTabState, setActiveTab] = useState<TabRoute | null>(null);
  const [scrollProgressState, setScrollProgress] = useState<number | null>(null);
  const [tabReselect, setTabReselect] = useState(0);
  const activeTab = activeTabState ?? locatedTab ?? '/';
  const scrollProgress =
    scrollProgressState ?? (locatedTab ? TAB_ROUTES.indexOf(locatedTab) : 0);
  const activeTabRef = useRef<TabRoute>(activeTab);

  useEffect(() => {
    activeTabRef.current = activeTab;
  }, [activeTab]);

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

      setActiveTab(tab);
      setScrollProgress(index);

      const url = tabToUrl(tab);
      if (`${window.location.pathname}${window.location.hash}` !== url) {
        window.history.replaceState(null, '', url);
      }
    },
    [prepareTabSwitch],
  );

  useEffect(() => {
    if (!locatedTab) return;
    const url = tabToUrl(locatedTab);
    if (`${window.location.pathname}${window.location.hash}` !== url) {
      window.history.replaceState(null, '', url);
    }
  }, [locatedTab]);

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
