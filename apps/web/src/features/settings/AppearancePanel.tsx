'use client';

import { useEffect, useState } from 'react';
import { Check } from 'lucide-react';
import { AppPush } from '@/components/ui/AppPush';
import type { StatusReporter } from '@/hooks/usePanelAction';
import {
  applyTheme,
  getThemeMode,
  resolveTheme,
  setThemeMode,
  watchSystemTheme,
  type ThemeMode,
} from '@/lib/theme';

const OPTIONS: { id: ThemeMode; title: string; desc: string }[] = [
  { id: 'system', title: '跟随系统', desc: '随设备的深浅色自动切换' },
  { id: 'light', title: '浅色', desc: '始终使用浅色外观' },
  { id: 'dark', title: '深色', desc: '始终使用深色外观' },
];

const LABEL: Record<ThemeMode, string> = {
  system: '跟随系统',
  light: '浅色',
  dark: '深色',
};

export function AppearancePanel({
  onBack,
  onStatus,
}: {
  onBack: () => void;
  onStatus: StatusReporter;
}) {
  // 服务端渲染与首帧都用「跟随系统」，挂载后再读本地存储，避免 hydration 不一致
  const [mode, setMode] = useState<ThemeMode>('system');
  const [resolved, setResolved] = useState<'light' | 'dark'>('light');

  useEffect(() => {
    const m = getThemeMode();
    setMode(m);
    setResolved(resolveTheme(m));
  }, []);

  // 跟随系统时，系统切换深浅色要即时反映
  useEffect(() => {
    const unwatch = watchSystemTheme(() => {
      const m = getThemeMode();
      applyTheme(m);
      if (m === 'system') {
        setResolved(resolveTheme('system'));
        onStatus('跟随系统', 'mute');
      }
    });
    return unwatch;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    onStatus(mode === 'system' ? '系统' : LABEL[mode], 'mute');
    // 仅挂载 / 切换时回报，避免把 onStatus 放进依赖
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode]);

  function choose(next: ThemeMode) {
    setThemeMode(next);
    setMode(next);
    setResolved(resolveTheme(next));
  }

  return (
    <AppPush title="外观" onBack={onBack}>
      <div className="appearance-panel">
        <p className="settings-group-label">主题</p>
        <ul className="settings-group">
          {OPTIONS.map((opt) => (
            <li key={opt.id}>
              <button
                type="button"
                className="settings-nav"
                onClick={() => choose(opt.id)}
              >
                <span className="settings-nav__main">
                  <span className="settings-nav__title">{opt.title}</span>
                  <span className="settings-nav__desc">{opt.desc}</span>
                </span>
                <span className="settings-nav__trail">
                  {mode === opt.id ? (
                    <Check
                      className="appearance-panel__check"
                      size={18}
                      strokeWidth={2.6}
                      aria-hidden
                    />
                  ) : null}
                </span>
              </button>
            </li>
          ))}
        </ul>
        <p className="app-hint">
          当前生效：{resolved === 'dark' ? '深色' : '浅色'}
          {mode === 'system' ? '（跟随系统）' : ''}
        </p>
      </div>
    </AppPush>
  );
}
