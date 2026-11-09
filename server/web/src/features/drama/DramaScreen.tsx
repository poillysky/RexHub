'use client';

import { startTransition, useEffect, useState } from 'react';
import { AppPush } from '@/components/ui/AppPush';
import { useTabNavigation } from '@/shell';
import { useStackCover } from '@/hooks/useStackCover';
import { DramaCatalogBody } from './DramaCatalogBody';
import { DramaDetailBody } from './DramaDetailBody';
import { DramaHub } from './DramaHub';
import { DramaRankBody } from './DramaRankBody';
import { DramaSearchBody } from './DramaSearchBody';
import type { Stack } from './types';

export function DramaScreen() {
  const tabCtx = useTabNavigation();
  const activeTab = tabCtx?.activeTab;
  const tabReselect = tabCtx?.tabReselect ?? 0;
  const [stack, setStack] = useState<Stack>({ kind: 'hub' });
  const hubCover = useStackCover(
    stack.kind !== 'hub',
    'drama-hub',
    'app-hub drama-hub',
  );

  // 再点当前 Tab：回到 Hub
  useEffect(() => {
    if (activeTab !== '/drama' || tabReselect === 0) return;
    startTransition(() => setStack({ kind: 'hub' }));
  }, [activeTab, tabReselect]);

  const hub = (
    <div {...hubCover}>
      <div className="media-hub__top">
        <div className="media-hub__top-row">
          <h1 className="app-hub__title">短剧</h1>
        </div>
      </div>
      <div className="app-hub__scroll">
        <DramaHub
          onOpen={(site) =>
            startTransition(() =>
              setStack({ kind: 'catalog', site: site.id, name: site.name }),
            )
          }
        />
      </div>
    </div>
  );

  let push = null;
  if (stack.kind === 'catalog') {
    push = (
      <AppPush
        title={stack.name}
        scrollKey={`drama-catalog-${stack.site}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <DramaCatalogBody
          site={stack.site}
          onSearch={(q) =>
            startTransition(() =>
              setStack({ kind: 'search', site: stack.site, name: stack.name, q }),
            )
          }
          onOpenRank={(groupId, rankId, rankTitle) =>
            startTransition(() =>
              setStack({
                kind: 'rank',
                site: stack.site,
                siteName: stack.name,
                group: groupId,
                rank: rankId,
                title: rankTitle,
              }),
            )
          }
          onOpen={(card) =>
            startTransition(() =>
              setStack({
                kind: 'detail',
                site: stack.site,
                siteName: stack.name,
                card,
                back: stack,
              }),
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'search') {
    push = (
      <AppPush
        title="搜索"
        scrollKey={`drama-search-${stack.site}-${stack.q}`}
        onBack={() =>
          setStack({ kind: 'catalog', site: stack.site, name: stack.name })
        }
      >
        <DramaSearchBody
          site={stack.site}
          initialQuery={stack.q}
          onOpen={(card) =>
            startTransition(() =>
              setStack({
                kind: 'detail',
                site: stack.site,
                siteName: stack.name,
                card,
                back: stack,
              }),
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'rank') {
    push = (
      <AppPush
        title={stack.title}
        scrollKey={`drama-rank-${stack.site}-${stack.group}-${stack.rank}`}
        onBack={() =>
          setStack({ kind: 'catalog', site: stack.site, name: stack.siteName })
        }
      >
        <DramaRankBody
          key={`${stack.site}-${stack.group}-${stack.rank}`}
          site={stack.site}
          group={stack.group}
          rank={stack.rank}
          onOpen={(card) =>
            startTransition(() =>
              setStack({
                kind: 'detail',
                site: stack.site,
                siteName: stack.siteName,
                card,
                back: stack,
              }),
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'detail') {
    push = (
      <AppPush
        title={stack.card.title || stack.siteName}
        scrollKey={`drama-detail-${stack.site}-${stack.card.id}`}
        scrollMode="top"
        onBack={() => startTransition(() => setStack(stack.back))}
      >
        <DramaDetailBody site={stack.site} card={stack.card} />
      </AppPush>
    );
  }

  return (
    <div className="app-stack-root drama-stack">
      {hub}
      {push}
    </div>
  );
}
