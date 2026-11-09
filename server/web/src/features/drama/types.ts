import type { DramaCard } from '@/lib/api';

export type Stack =
  | { kind: 'hub' }
  | { kind: 'catalog'; site: string; name: string }
  | { kind: 'search'; site: string; name: string; q: string }
  | {
      kind: 'rank';
      site: string;
      siteName: string;
      group: string;
      rank: string;
      title: string;
    }
  | {
      kind: 'detail';
      site: string;
      siteName: string;
      card: DramaCard;
      back: Stack;
    };
