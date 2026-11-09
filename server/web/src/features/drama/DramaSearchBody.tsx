'use client';

import { Search } from 'lucide-react';
import { LazyImg } from '@/components/SoftImg';
import type { DramaCard } from '@/lib/api';
import { useDramaSearch } from './useDramaScreen';

export function DramaSearchBody({
  site,
  initialQuery,
  onOpen,
}: {
  site: string;
  initialQuery: string;
  onOpen: (card: DramaCard) => void;
}) {
  const {
    input,
    setInput,
    query,
    items,
    loading,
    loadingMore,
    hasMore,
    error,
    submit,
    loadMore,
  } = useDramaSearch(site, initialQuery);

  return (
    <div className="drama-catalog">
      <form className="drama-search drama-search--page" onSubmit={submit} role="search">
        <Search size={16} className="drama-search__icon" aria-hidden />
        <input
          className="drama-search__input"
          value={input}
          onChange={(event) => setInput(event.target.value)}
          placeholder="搜索短剧"
          type="search"
          enterKeyHint="search"
          aria-label="搜索短剧"
        />
        <button
          type="submit"
          className="drama-search__submit"
          disabled={!input.trim()}
        >
          搜索
        </button>
      </form>

      {!query ? <p className="drama-empty">输入关键词，搜索短剧</p> : null}

      {loading ? (
        <div className="drama-grid">
          {Array.from({ length: 6 }).map((_, i) => (
            <span key={i} className="drama-card-skel" />
          ))}
        </div>
      ) : null}
      {!loading && error && items.length === 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}
      {!loading && query && !error && items.length === 0 ? (
        <p className="drama-empty">没有找到相关短剧</p>
      ) : null}
      {!loading && items.length > 0 ? (
        <div className="drama-grid">
          {items.map((card) => (
            <button
              key={card.id}
              type="button"
              className="drama-card"
              onClick={() => onOpen(card)}
            >
              <span className="drama-card__cover">
                <LazyImg src={card.cover} alt="" loading="lazy" />
                {card.episodeCount > 0 ? (
                  <span className="drama-card__badge">{card.episodeCount}集</span>
                ) : null}
              </span>
              <span className="drama-card__title">{card.title}</span>
            </button>
          ))}
        </div>
      ) : null}
      {!loading && items.length > 0 && hasMore ? (
        <button
          type="button"
          className="drama-more"
          onClick={loadMore}
          disabled={loadingMore}
        >
          {loadingMore ? '加载中…' : '加载更多'}
        </button>
      ) : null}
      {error && items.length > 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}
    </div>
  );
}
