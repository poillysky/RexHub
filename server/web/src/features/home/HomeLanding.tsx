'use client';

import { ClipboardPaste, LayoutGrid } from 'lucide-react';
import { AppMsg } from '@/components/ui/AppMsg';
import { HomeSearchField } from './HomeSearchField';
import type { HomeScreenState } from './useHomeScreen';

type Props = {
  h: HomeScreenState;
};

export function HomeLanding({ h }: Props) {
  return (
    <div className="home-landing">
      <div className="home-landing__top">
        <div className="home-landing__top-row">
          <div className="home-landing__brand" aria-label="RexHub">
            <img
              className="home-landing__brand-mark"
              src="/brand/logo.png"
              alt=""
              width={30}
              height={30}
              decoding="async"
            />
            <span className="home-landing__brand-name">RexHub</span>
          </div>
          <div className="home-landing__toolbar" role="toolbar" aria-label="快捷操作">
            <button
              type="button"
              className="home-landing__chip"
              onClick={() => h.openBoards()}
            >
              <span className="home-landing__chip-ico" aria-hidden>
                <LayoutGrid size={13} strokeWidth={2.4} />
              </span>
              <span className="home-landing__chip-txt">板块</span>
            </button>
            <button
              type="button"
              className="home-landing__chip"
              onClick={() => h.setPasteOpen(true)}
            >
              <span className="home-landing__chip-ico" aria-hidden>
                <ClipboardPaste size={13} strokeWidth={2.4} />
              </span>
              <span className="home-landing__chip-txt">转存</span>
            </button>
          </div>
        </div>
      </div>
      <div className="home-landing__main">
        <div className="home-landing__hero">
          <img
            className="home-landing__rose"
            src="/brand/logo.png"
            alt=""
            width={156}
            height={156}
            decoding="async"
          />
          <h1 className="home-landing__title">RexHub</h1>
          <p className="home-landing__sub">片名 · 番号 · 关键词 · 多源同搜</p>
          <HomeSearchField
            draft={h.draft}
            size="hero"
            busy={h.activeLoading && !h.activeLoadingMore}
            showSource
            source={h.searchScope}
            onSourceChange={h.onSearchScopeChange}
            onDraftChange={h.setDraft}
            onSubmit={() => h.submitSearch()}
            onClear={() => h.setDraft('')}
          />
        </div>
        <button
          type="button"
          className="home-landing__bot"
          aria-label="AI 对话搜索"
          onClick={() => h.setChatOpen(true)}
        >
          <img
            className="home-landing__bot-img"
            src="/brand/chat-bot.png"
            alt=""
            width={58}
            height={58}
            decoding="async"
          />
          <span className="home-landing__bot-pulse" aria-hidden />
        </button>
        {h.msg ? (
          <div className="home-landing__msg">
            <AppMsg onDismiss={() => h.setMsg('')}>{h.msg}</AppMsg>
          </div>
        ) : null}
      </div>
    </div>
  );
}
