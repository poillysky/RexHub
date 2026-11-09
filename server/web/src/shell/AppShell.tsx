'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useRef, useEffect, useState, type MouseEvent } from 'react';
import {
  Search,
  Clapperboard,
  Building2,
  Drama,
  Settings,
  ChevronLeft,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { startViewTransition } from '@/lib/pwa';
import { HapticsProvider, useHaptics } from './HapticsProvider';
import { useTabNavigation, type TabRoute } from './TabContext';
import { TabPaneSizeContext } from './TabPane';

const NAV_ITEMS: { tab: TabRoute; label: string; icon: typeof Search }[] = [
  { tab: '/', label: '搜索', icon: Search },
  { tab: '/media', label: '影视', icon: Clapperboard },
  { tab: '/makers', label: '片商', icon: Building2 },
  { tab: '/drama', label: '短剧', icon: Drama },
  { tab: '/settings', label: '更多', icon: Settings },
];


export function AppShell({ children }: { children: React.ReactNode }) {
  const tabCtx = useTabNavigation();
  const router = useRouter();
  const viewportRef = useRef<HTMLDivElement>(null);
  /** 视口尺寸：Tab 页与轨道位移都以此为准（预览框内 ≠ 100vw） */
  const [paneSize, setPaneSize] = useState({ width: 0, height: 0 });

  useEffect(() => {
    const el = viewportRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setPaneSize({ width, height });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Tabbed mode: inside TabProvider (main app)
  // Standalone mode: export/settings pages (no tab context)
  const isTabbed = !!tabCtx;

  /** Navigate back with View Transition animation (reverse pop) */
  const handleBackClick = (e: MouseEvent<HTMLAnchorElement>) => {
    e.preventDefault();
    document.documentElement.classList.add('vt-back');
    startViewTransition(() => {
      router.push('/');
    });
  };

  return (
    <HapticsProvider>
    {/* 
      IMPORTANT: The nav MUST be inside this h-dvh flex-col container as a 
      normal flex child (shrink-0), NOT position:fixed. On iOS standalone PWAs,
      position:fixed bottom-0 does not reach the actual screen bottom — it 
      floats above the home indicator. Normal flex flow inside h-dvh pushes 
      the nav to the true screen bottom. See notes/ios-pwa-layout.md.
    */}
    <div
      className={cn(
        'app-shell flex flex-col overflow-hidden',
        isTabbed ? 'h-dvh' : 'min-h-dvh',
      )}
      style={{
        backgroundColor: 'var(--app-bg-solid, #f2f2f7)',
        backgroundImage: 'var(--app-bg)',
        height: isTabbed ? 'var(--app-height, 100vh)' : undefined,
        maxHeight: isTabbed ? 'var(--app-height, 100vh)' : undefined,
      }}
    >
      {isTabbed ? (
        <div
          ref={viewportRef}
          className="app-tab-viewport flex-1 min-h-0 w-full"
        >
          <div
            className="app-tab-track"
            style={{
              transform:
                paneSize.width > 0
                  ? `translate3d(-${tabCtx.scrollProgress * paneSize.width}px, 0, 0)`
                  : `translate3d(-${(tabCtx.scrollProgress / NAV_ITEMS.length) * 100}%, 0, 0)`,
            }}
          >
            <TabPaneSizeContext.Provider value={paneSize}>
              {children}
            </TabPaneSizeContext.Provider>
          </div>
        </div>
      ) : (
        <>
          <header
            className="sticky top-0 z-40"
            style={{
              paddingTop: 'var(--nav-safe-top)',
              background: 'rgba(247, 250, 255, 0.88)',
              WebkitBackdropFilter: 'saturate(180%) blur(16px)',
              backdropFilter: 'saturate(180%) blur(16px)',
              borderBottom: '0.5px solid var(--hairline)',
            }}
          >
            <div className="flex h-12 w-full items-center px-3">
              <Link
                href="/"
                onClick={handleBackClick}
                className="app-back"
              >
                <ChevronLeft className="h-5 w-5" />
                <span>返回</span>
              </Link>
            </div>
          </header>
          <main className="w-full flex-1 px-0 pb-4 pt-0">
            <div className="animate-fade-in-up h-full">
              {children}
            </div>
          </main>
        </>
      )}
      {/* Nav is a flex child (shrink-0) INSIDE the h-dvh container — not fixed */}
      <BottomNav
        navItems={NAV_ITEMS}
        isTabbed={isTabbed}
        tabCtx={tabCtx}
      />
    </div>
    </HapticsProvider>
  );
}

/* ─────────────────────────────────────────────
   Bottom nav — tap only, no swipe / drag switch
   
   CRITICAL: Uses shrink-0 in normal flex flow,
   NOT position:fixed. See notes/ios-pwa-layout.md
   ───────────────────────────────────────────── */

interface BottomNavProps {
  navItems: typeof NAV_ITEMS;
  isTabbed: boolean;
  tabCtx: ReturnType<typeof useTabNavigation>;
}

function BottomNav({ navItems, isTabbed, tabCtx }: BottomNavProps) {
  const navRef = useRef<HTMLElement>(null);
  const haptics = useHaptics();
  const prevActiveTab = useRef(tabCtx?.activeTab);

  useEffect(() => {
    if (!isTabbed || !tabCtx) return;
    if (tabCtx.activeTab !== prevActiveTab.current) {
      prevActiveTab.current = tabCtx.activeTab;
      haptics.trigger('selection');
    }
  }, [tabCtx?.activeTab, isTabbed, haptics, tabCtx]);

  return (
    <nav
      ref={navRef}
      className="app-tabbar"
      role="navigation"
      aria-label="主导航"
      style={{
        paddingLeft: 'env(safe-area-inset-left)',
        paddingRight: 'env(safe-area-inset-right)',
        paddingBottom: 'env(safe-area-inset-bottom, 0px)',
      }}
    >
      <div className="app-tabbar__inner">
        {navItems.map(({ tab, label, icon: Icon }, index) => {
          const isActive = isTabbed ? tabCtx?.activeTab === tab : false;

          if (isTabbed) {
            return (
              <button
                key={tab}
                type="button"
                data-tab-index={index}
                onClick={() => tabCtx?.scrollToTab(tab)}
                className={cn(
                  'app-tab-item',
                  isActive && 'app-tab-item--active',
                )}
                aria-current={isActive ? 'page' : undefined}
              >
                <Icon aria-hidden strokeWidth={2} />
                <span className="leading-none">{label}</span>
              </button>
            );
          }

          return (
            <Link
              key={tab}
              href={tab === '/' ? '/' : `/#${tab.slice(1)}`}
              data-tab-index={index}
              className="app-tab-item"
            >
              <Icon aria-hidden strokeWidth={1.75} />
              <span className="leading-none">{label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
