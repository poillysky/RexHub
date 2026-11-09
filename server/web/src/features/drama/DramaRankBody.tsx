'use client';

import { LazyImg } from '@/components/SoftImg';
import type { DramaCard } from '@/lib/api';
import { useDramaRank } from './useDramaScreen';

export function DramaRankBody({
  site,
  group,
  rank,
  onOpen,
}: {
  site: string;
  group: string;
  rank: string;
  onOpen: (card: DramaCard) => void;
}) {
  const { items, loading, loadingMore, error, sentinelRef } = useDramaRank(
    site,
    group,
    rank,
  );

  return (
    <div className="drama-catalog">
      {loading ? (
        <div className="drama-grid">
          {Array.from({ length: 9 }).map((_, i) => (
            <span key={i} className="drama-card-skel" />
          ))}
        </div>
      ) : null}

      {!loading && error && items.length === 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}

      {!loading && !error && items.length === 0 ? (
        <p className="drama-empty">暂无内容</p>
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

      {!loading && error && items.length > 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}

      {loadingMore ? <p className="drama-rank-more">加载中…</p> : null}
      <div ref={sentinelRef} className="drama-rank-sentinel" aria-hidden />
    </div>
  );
}
