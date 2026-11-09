'use client';

import { Play } from 'lucide-react';
import { SoftImg } from '@/components/SoftImg';
import { dramaStreamUrl, type DramaCard } from '@/lib/api';
import { DramaVideo } from './DramaVideo';
import { useDramaDetail } from './useDramaScreen';

export function DramaDetailBody({ site, card }: { site: string; card: DramaCard }) {
  const { detail, current, loading, error, play } = useDramaDetail(site, card);

  const episodes = detail?.episodes ?? [];
  const playable = episodes.filter((item) => !item.disabled);
  const currentIndex = current
    ? playable.findIndex((item) => item.id === current.id)
    : -1;
  const nextEpisode =
    currentIndex >= 0 ? playable[currentIndex + 1] : undefined;
  const title = detail?.title || card.title;
  const cover = detail?.cover || card.cover;
  const description = detail?.description || card.description;

  return (
    <div className="drama-detail">
      <div className="drama-player">
        {current ? (
          <DramaVideo
            key={current.id}
            src={dramaStreamUrl(site, current.id)}
            poster={cover}
          />
        ) : (
          <button
            type="button"
            className="drama-player__poster"
            onClick={() => {
              const first = playable[0];
              if (first) play(first);
            }}
            disabled={loading || playable.length === 0}
          >
            {cover ? <SoftImg src={cover} alt="" /> : null}
            <span className="drama-player__mask" aria-hidden />
            <span className="drama-player__play">
              <Play size={24} strokeWidth={2} aria-hidden />
            </span>
            <span className="drama-player__label">
              {loading ? '加载中…' : playable.length ? '点击播放' : '暂无可播放剧集'}
            </span>
          </button>
        )}
      </div>

      {current && nextEpisode ? (
        <button
          type="button"
          className="drama-next"
          onClick={() => play(nextEpisode)}
        >
          下一集 · 第 {nextEpisode.episode} 集
        </button>
      ) : null}

      <div className="drama-detail__head">
        <h2 className="drama-detail__title">{title}</h2>
        <p className="drama-detail__meta">
          {detail?.siteName || card.siteName}
          {episodes.length ? ` · 共 ${episodes.length} 集` : ''}
          {current ? ` · 第 ${current.episode} 集` : ''}
        </p>
        {description ? (
          <p className="drama-detail__desc allow-select">{description}</p>
        ) : null}
      </div>

      {!loading && error ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}

      {episodes.length > 0 ? (
        <section className="drama-episodes">
          <div className="drama-episodes__head">
            <span>选集</span>
            <span className="drama-episodes__count">{episodes.length}</span>
          </div>
          <div className="drama-episodes__grid">
            {episodes.map((episode) => (
              <button
                key={episode.id}
                type="button"
                className={
                  current?.id === episode.id
                    ? 'drama-episode is-active'
                    : 'drama-episode'
                }
                disabled={episode.disabled}
                onClick={() => play(episode)}
              >
                {episode.episode || episode.title}
              </button>
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}
