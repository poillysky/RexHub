'use client';

import type { ReactNode } from 'react';
import type { PluginEntry } from '@/lib/api';
import { PluginIcon } from './PluginIcon';
import { statusTone } from './types';

export function PluginCard({
  entry,
  hint,
  onClick,
  action,
  tone,
}: {
  entry: PluginEntry;
  hint: string;
  onClick: () => void;
  action?: ReactNode;
  tone?: string;
}) {
  return (
    <li className={action ? 'plugin-fw-card has-action' : 'plugin-fw-card'}>
      <button type="button" className="plugin-fw-card__main" onClick={onClick}>
        <span className="plugin-fw-card__icon">
          <PluginIcon entry={entry} />
        </span>
        <span className="plugin-fw-card__body">
          <span className="plugin-fw-card__head">
            <span
              className={`plugin-fw-card__dot is-${tone || statusTone(entry)}`}
              aria-hidden
            />
            <span className="plugin-fw-card__name">{entry.name}</span>
          </span>
          <span className="plugin-fw-card__desc">{hint}</span>
        </span>
      </button>
      {action ? <span className="plugin-fw-card__action">{action}</span> : null}
    </li>
  );
}
