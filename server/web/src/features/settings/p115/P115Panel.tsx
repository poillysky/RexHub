'use client';

import { AppPush } from '@/components/ui/AppPush';
import { AppMsg } from '@/components/ui/AppMsg';
import { cn } from '@/lib/utils';
import { TABS } from './format';
import { useP115Panel } from './useP115Panel';
import { P115Overview } from './P115Overview';
import { P115ExtractTab } from './P115ExtractTab';
import { P115FolderBrowser } from './P115FolderBrowser';
import { P115TasksTab } from './P115TasksTab';

export function P115Panel({ onBack }: { onBack: () => void }) {
  const p = useP115Panel();

  return (
    <AppPush title="115 转存" onBack={onBack}>
      <div className="p115-console">
        {p.authChecking ? (
          <div className="p115-loading" role="status" aria-live="polite">
            <span className="p115-loading__logo" aria-hidden>
              <img src="/brand/115.png" alt="" width={52} height={52} decoding="async" />
            </span>
            <span>正在校验 115 登录态…</span>
          </div>
        ) : null}
        {p.configured && !p.authChecking ? (
          <div className="app-seg" role="tablist" aria-label="115 转存工作台">
            {TABS.map((t) => (
              <button
                key={t.key}
                type="button"
                role="tab"
                aria-selected={p.tab === t.key}
                className={cn('app-seg__btn', p.tab === t.key && 'app-seg__btn--active')}
                onClick={() => p.setTab(t.key)}
              >
                {t.label}
              </button>
            ))}
          </div>
        ) : null}

        {p.tab === 'overview' && !p.authChecking ? <P115Overview p={p} /> : null}
        {p.tab === 'extract' && p.configured ? <P115ExtractTab p={p} /> : null}
        {p.tab === 'tasks' && p.configured ? <P115TasksTab p={p} /> : null}

        <P115FolderBrowser p={p} />

        <AppMsg allowSelect onDismiss={() => p.setMsg('')}>
          {p.msg}
        </AppMsg>
      </div>
    </AppPush>
  );
}
