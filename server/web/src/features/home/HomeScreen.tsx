'use client';

import { useRef } from 'react';
import { AppPush } from '@/components/ui/AppPush';
import { P115PastePanel } from './P115PastePanel';
import { AiSearchChatPanel } from './AiSearchChatPanel';
import { BoardsScreen } from '@/features/boards/BoardsScreen';
import { ResourceDetailBody } from './ResourceDetailBody';
import { ScopeDetailBody } from './ScopeDetailBody';
import { BitmagnetDetailBody } from '@/features/magnet/BitmagnetDetailBody';
import { useHomeScreen } from './useHomeScreen';
import { HomeLanding } from './HomeLanding';
import { HomeResults } from './HomeResults';

/**
 * 搜索页 — 按「范围」聚合搜索：
 * 影视 = Bitmagnet + CloudSaver；片商 = AVDB + Bitmagnet + 色花堂
 */
export function HomeScreen() {
  const scrollBodyRef = useRef<HTMLDivElement | null>(null);
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  const h = useHomeScreen({ scrollBodyRef, sentinelRef });

  return (
    <div className="app-stack-root">
      <div {...h.mainCover}>
        {h.mode === 'landing' ? (
          <HomeLanding h={h} />
        ) : (
          <HomeResults h={h} scrollBodyRef={scrollBodyRef} sentinelRef={sentinelRef} />
        )}
      </div>

      {h.detailHash ? (
        <AppPush
          title="详情"
          scrollKey={`home-detail-${h.detailSource}-${h.detailHash}`}
          scrollMode="top"
          onBack={h.closeDetail}
        >
          {h.detailSource === 'bitmagnet' ? (
            <BitmagnetDetailBody hash={h.detailHash} />
          ) : (
            <ResourceDetailBody hash={h.detailHash} />
          )}
        </AppPush>
      ) : null}

      {h.scopeItem ? (
        <AppPush
          title="详情"
          scrollKey={`home-scope-detail-${h.scopeItem.id}`}
          scrollMode="top"
          onBack={h.closeScopeDetail}
        >
          <ScopeDetailBody
            item={h.scopeItem}
            source={h.searchScope === 'maker' ? 'maker' : 'media'}
          />
        </AppPush>
      ) : null}

      {h.pasteOpen ? <P115PastePanel onBack={() => h.setPasteOpen(false)} /> : null}
      {h.chatOpen ? <AiSearchChatPanel onBack={() => h.setChatOpen(false)} /> : null}
      {h.boardsOpen ? (
        <BoardsScreen onClose={() => h.setBoardsOpen(false)} />
      ) : null}
    </div>
  );
}
