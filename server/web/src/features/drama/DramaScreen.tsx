'use client';

import { startTransition, useEffect, useState } from 'react';
import { AppPush } from '@/components/ui/AppPush';
import { useTabNavigation, type TabRoute } from '@/shell';
import { useStackCover } from '@/hooks/useStackCover';
import { makeHref, type HashRoute } from '@/shell/nav/urlNav';
import {
  usePageHistory,
  useTabLocation,
  useTabUrlSync,
} from '@/shell/nav/useTabHistory';
import { DramaCatalogBody } from './DramaCatalogBody';
import { DramaDetailBody } from './DramaDetailBody';
import { DramaHub } from './DramaHub';
import { DramaRankBody } from './DramaRankBody';
import { DramaSearchBody } from './DramaSearchBody';
import type { Stack } from './types';

const DRAMA_TAB: TabRoute = '/drama';
const DRAMA_ROOT_HREF = makeHref(DRAMA_TAB);

/** 当前页面 → 地址栏 */
function dramaHref(stack: Stack): string {
  switch (stack.kind) {
    case 'hub':
      return DRAMA_ROOT_HREF;
    case 'catalog':
      return makeHref(DRAMA_TAB, ['catalog'], {
        site: stack.site,
        name: stack.name,
      });
    case 'search':
      return makeHref(DRAMA_TAB, ['search'], {
        site: stack.site,
        name: stack.name,
        q: stack.q,
      });
    case 'rank':
      return makeHref(DRAMA_TAB, ['rank'], {
        site: stack.site,
        siteName: stack.siteName,
        group: stack.group,
        rank: stack.rank,
        title: stack.title,
      });
    case 'detail':
      return makeHref(DRAMA_TAB, ['detail'], {
        site: stack.site,
        siteName: stack.siteName,
        id: stack.card.id,
        title: stack.card.title,
        cover: stack.card.cover,
        desc: stack.card.description,
        season: stack.card.season,
        ec: stack.card.episodeCount,
      });
  }
}

/** 地址栏 → 当前页面（深链 / 刷新 / 前进后退） */
function parseDramaLocation(route: HashRoute): Stack | null {
  const q = route.query;
  const head = route.segments[0];

  switch (head) {
    case undefined:
      return { kind: 'hub' };
    case 'catalog': {
      const site = q.get('site');
      if (!site) return null;
      return { kind: 'catalog', site, name: q.get('name') || site };
    }
    case 'search': {
      const site = q.get('site');
      if (!site) return null;
      return {
        kind: 'search',
        site,
        name: q.get('name') || site,
        q: q.get('q') || '',
      };
    }
    case 'rank': {
      const site = q.get('site');
      const group = q.get('group');
      const rank = q.get('rank');
      if (!site || !group || !rank) return null;
      return {
        kind: 'rank',
        site,
        siteName: q.get('siteName') || site,
        group,
        rank,
        title: q.get('title') || rank,
      };
    }
    case 'detail': {
      const site = q.get('site');
      const id = q.get('id');
      if (!site || !id) return null;
      return {
        kind: 'detail',
        site,
        siteName: q.get('siteName') || site,
        card: {
          site,
          siteName: q.get('siteName') || site,
          id,
          title: q.get('title') || '',
          cover: q.get('cover') || '',
          description: q.get('desc') || '',
          season: Number(q.get('season')) || 0,
          episodeCount: Number(q.get('ec')) || 0,
        },
        back: { kind: 'hub' },
      };
    }
    default:
      return null;
  }
}

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

  const nav = usePageHistory(DRAMA_TAB, DRAMA_ROOT_HREF, () => {
    setStack({ kind: 'hub' });
  });

  useTabLocation(DRAMA_TAB, (route) => {
    const next = parseDramaLocation(route);
    if (next) setStack(next);
  });
  useTabUrlSync(DRAMA_TAB, dramaHref(stack));

  const pushPage = (next: Stack) => {
    nav.push(dramaHref(next));
    startTransition(() => setStack(next));
  };

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
            pushPage({ kind: 'catalog', site: site.id, name: site.name })
          }
        />
      </div>
    </div>
  );

  let push = null;
  if (stack.kind === 'catalog') {
    push = (
      <AppPush
        key={`drama-catalog-${stack.site}`}
        title={stack.name}
        scrollKey={`drama-catalog-${stack.site}`}
        onBack={() => nav.back()}
      >
        <DramaCatalogBody
          site={stack.site}
          onSearch={(q) =>
            pushPage({
              kind: 'search',
              site: stack.site,
              name: stack.name,
              q,
            })
          }
          onOpenRank={(groupId, rankId, rankTitle) =>
            pushPage({
              kind: 'rank',
              site: stack.site,
              siteName: stack.name,
              group: groupId,
              rank: rankId,
              title: rankTitle,
            })
          }
          onOpen={(card) =>
            pushPage({
              kind: 'detail',
              site: stack.site,
              siteName: stack.name,
              card,
              back: stack,
            })
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'search') {
    push = (
      <AppPush
        key={`drama-search-${stack.site}`}
        title="搜索"
        scrollKey={`drama-search-${stack.site}-${stack.q}`}
        onBack={() => nav.back()}
      >
        <DramaSearchBody
          site={stack.site}
          initialQuery={stack.q}
          onOpen={(card) =>
            pushPage({
              kind: 'detail',
              site: stack.site,
              siteName: stack.name,
              card,
              back: stack,
            })
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'rank') {
    push = (
      <AppPush
        key={`drama-rank-${stack.site}-${stack.group}-${stack.rank}`}
        title={stack.title}
        scrollKey={`drama-rank-${stack.site}-${stack.group}-${stack.rank}`}
        onBack={() => nav.back()}
      >
        <DramaRankBody
          key={`${stack.site}-${stack.group}-${stack.rank}`}
          site={stack.site}
          group={stack.group}
          rank={stack.rank}
          onOpen={(card) =>
            pushPage({
              kind: 'detail',
              site: stack.site,
              siteName: stack.siteName,
              card,
              back: stack,
            })
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'detail') {
    push = (
      <AppPush
        key={`drama-detail-${stack.site}-${stack.card.id}`}
        title={stack.card.title || stack.siteName}
        scrollKey={`drama-detail-${stack.site}-${stack.card.id}`}
        scrollMode="top"
        onBack={() => nav.back()}
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
