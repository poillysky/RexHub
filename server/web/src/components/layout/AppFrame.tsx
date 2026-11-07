'use client';

import './app-frame.css';

/**
 * 全屏应用容器：PWA 直接铺满视口，不再在桌面浏览器里套 iPhone 外框。
 */
export function AppFrame({ children }: { children: React.ReactNode }) {
  return (
    <div className="app-stage">
      <div className="app-content">
        {children}
        <div id="app-overlay-root" className="app-overlay-root" />
      </div>
    </div>
  );
}
