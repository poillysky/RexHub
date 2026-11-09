'use client';

import { useState } from 'react';
import type { MakerMovie } from '@/lib/api/makers';
import {
  useMakerBrowse,
  useMakerListDetail,
  useMakerRelatedLists,
} from '../useMakerQueries';
import { MakerMovieCard, Pager, WallSkeleton } from './shared';

/* ── 片单详情 ────────────────────────────────────── */

export function MakerListDetailBody({
  id,
  onOpenMovie,
}: {
  id: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const list = useMakerListDetail(id);
  const [page, setPage] = useState(1);
  const browse = useMakerBrowse('0', '', '', '', page, undefined, { listId: id });
  const items = browse.data?.items || [];
  const hasMore = !!browse.data?.hasMore;
  const err = list.error instanceof Error ? list.error.message : '';
  const browseErr =
    browse.error instanceof Error ? browse.error.message : browse.error ? '加载失败' : '';
  const info = list.data;

  return (
    <div className="maker-movies">
      {!info && !err ? <p className="media-empty">加载中…</p> : null}
      {err ? <p className="media-empty allow-select">{err}</p> : null}
      {info ? (
        <div className="maker-entity">
          <p className="maker-entity__kind">片单</p>
          <h2 className="maker-entity__name allow-select">{info.name}</h2>
          <p className="maker-entity__meta">
            {[
              info.moviesCount ? `${info.moviesCount} 部影片` : '',
              info.viewsCount ? `${info.viewsCount} 次浏览` : '',
              info.collectionsCount ? `${info.collectionsCount} 次收藏` : '',
            ]
              .filter(Boolean)
              .join(' · ')}
          </p>
          {info.description ? (
            <p className="maker-desc allow-select">{info.description}</p>
          ) : null}
          {info.shareUrl ? (
            <a
              className="maker-link"
              href={info.shareUrl}
              target="_blank"
              rel="noreferrer"
            >
              在 AVDB 查看原始条目
            </a>
          ) : null}
        </div>
      ) : null}
      {browse.isPending ? <WallSkeleton /> : null}
      {!browse.isPending && browseErr ? (
        <p className="media-empty allow-select">{browseErr}</p>
      ) : null}
      {!browse.isPending && !browseErr && items.length === 0 ? (
        <p className="media-empty">暂无影片</p>
      ) : null}
      {items.length > 0 ? (
        <div className="media-wall">
          {items.map((movie) => (
            <MakerMovieCard
              key={movie.id || movie.number}
              movie={movie}
              onClick={() => onOpenMovie(movie)}
            />
          ))}
        </div>
      ) : null}
      {items.length > 0 ? (
        <Pager
          page={page}
          hasMore={hasMore}
          isFetching={browse.isFetching}
          onChange={setPage}
        />
      ) : null}
    </div>
  );
}

/* ── 相关片单（影片详情内） ───────────────────────── */

export function MakerRelatedLists({
  movieId,
  onOpenList,
}: {
  movieId: string;
  onOpenList: (list: { id: string; name: string }) => void;
}) {
  const { data, isPending } = useMakerRelatedLists(movieId);
  const items = data || [];
  if (isPending) return null;
  if (!items.length) return null;
  return (
    <section className="media-detail__section">
      <h3 className="media-detail__h">相关片单</h3>
      <div className="maker-lists">
        {items.map((l) => (
          <button
            key={l.id}
            type="button"
            className="maker-list"
            onClick={() => onOpenList({ id: l.id, name: l.name })}
          >
            <span className="maker-list__name allow-select">{l.name}</span>
            <span className="maker-list__meta">
              {l.moviesCount ? `${l.moviesCount} 部` : ''}
              {l.collectionsCount ? ` · ${l.collectionsCount} 收藏` : ''}
            </span>
          </button>
        ))}
      </div>
    </section>
  );
}
