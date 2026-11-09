'use client';

import { AppPush } from '@/components/ui/AppPush';
import { AppMsg } from '@/components/ui/AppMsg';
import { cn } from '@/lib/utils';
import { TABS } from './helpers';
import { useAiModelsPanel } from './useAiModelsPanel';
import { AiModelTab } from './AiModelTab';
import { AiAgentTab } from './AiAgentTab';

export function AiModelsPanel({ onBack }: { onBack: () => void }) {
  const p = useAiModelsPanel({ onBack });

  return (
    <AppPush title="AI 模型" onBack={onBack} bodyClassName="ai-models-panel">
      <div className="app-seg" role="tablist" aria-label="AI 模型分页">
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            role="tab"
            aria-selected={p.tab === t.key}
            className={cn('app-seg__btn', p.tab === t.key && 'app-seg__btn--active')}
            onClick={() => p.switchTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>

      {p.tab === 'model' ? <AiModelTab p={p} /> : <AiAgentTab p={p} />}

      <AppMsg allowSelect onDismiss={() => p.setMsg('')}>
        {p.msg}
      </AppMsg>
    </AppPush>
  );
}
