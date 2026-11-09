'use client';

import { useState } from 'react';
import { Star } from 'lucide-react';
import { SoftImg } from '@/components/SoftImg';
import { linkKindOf } from '@/lib/resourceView';
import type { MakerActor, MakerMovie, MakerReview } from '@/lib/api/makers';

/* AVDB 封面 CDN 是加扰字节流，须经后端转发 AVDB img-proxy 解码 */
export function makerImageUrl(url: string | null | undefined, w?: number): string {
  if (!url) return '';
  const params = new URLSearchParams({ url });
  if (w) params.set('w', String(w));
  return `/api/makers/image?${params.toString()}`;
}

/** 只有磁力 / ed2k / 115 分享链接能走 115 离线转存 */
export function canSave115(url?: string | null): boolean {
  const kind = linkKindOf(url);
  return kind === 'magnet' || kind === 'ed2k' || kind === '115share';
}

/** 打开演员详情 */
export type OpenActorHandler = (actor: {
  id: string;
  name: string;
  videosCount: number;
}) => void;

/* ── 卡图 ───────────────────────────────────────── */

export function MakerMovieCard({
  movie,
  onClick,
}: {
  movie: MakerMovie;
  onClick: () => void;
}) {
  // 横版卡用封面图（裁切为横幅），无封面才退回预览图
  const poster =
    makerImageUrl(movie.coverUrl || movie.thumbUrl, 480) ||
    makerImageUrl(movie.previewUrl, 480);
  const [gone, setGone] = useState(false);
  return (
    <button
      type="button"
      className="media-poster media-poster--wide"
      onClick={onClick}
      aria-label={`${movie.number || ''} ${movie.title || ''}`.trim()}
    >
      <span className="media-poster__frame media-poster__frame--wide">
        <span className="media-poster__ph" aria-hidden>
          {(movie.number || movie.title || '影').slice(0, 1)}
        </span>
        {poster && !gone ? (
          <SoftImg
            src={poster}
            alt=""
            loading="lazy"
            referrerPolicy="no-referrer"
            onError={() => setGone(true)}
          />
        ) : null}
        {movie.hasCnsub ? (
          <span className="media-poster__type" aria-hidden>
            中
          </span>
        ) : null}
        {movie.magnetsCount > 0 ? (
          <span className="media-poster__score" aria-hidden>
            {movie.magnetsCount}
          </span>
        ) : null}
      </span>
      <span className="media-poster__caption">
        <span className="media-poster__title">{movie.number || movie.title}</span>
      </span>
    </button>
  );
}

/* ── 分页器 ─────────────────────────────────────── */

export function Pager({
  page,
  hasMore,
  isFetching,
  onChange,
  meta,
  count,
}: {
  page: number;
  hasMore: boolean;
  isFetching: boolean;
  onChange: (page: number) => void;
  meta?: string;
  /** 当前页条目数：显示为「第 N 页 · M 部」 */
  count?: number;
}) {
  const label =
    meta ||
    (count === undefined
      ? `第 ${page} 页`
      : `第 ${page} 页 · ${count}${hasMore ? '+' : ''} 部`);
  return (
    <div className="media-chart__pager">
      <button
        type="button"
        className="media-chart__page-btn"
        disabled={page <= 1 || isFetching}
        onClick={() => onChange(Math.max(1, page - 1))}
      >
        上一页
      </button>
      <span className="media-chart__page-meta">{label}</span>
      <button
        type="button"
        className="media-chart__page-btn"
        disabled={!hasMore || isFetching}
        onClick={() => onChange(page + 1)}
      >
        下一页
      </button>
    </div>
  );
}

export function WallSkeleton({ count = 12 }: { count?: number }) {
  return (
    <div className="media-wall media-wall--skel" aria-hidden>
      {Array.from({ length: count }).map((_, i) => (
        <span key={i} className="media-poster-skel media-poster-skel--wall" />
      ))}
    </div>
  );
}

/* ── 演员 ───────────────────────────────────────── */

export function ActorGrid({
  actors,
  onOpenActor,
}: {
  actors: MakerActor[];
  onOpenActor: OpenActorHandler;
}) {
  return (
    <div className="maker-actors">
      {actors.map((actor) => {
        const avatar = makerImageUrl(actor.avatarUrl, 240);
        return (
          <button
            key={actor.id}
            type="button"
            className="maker-actor"
            onClick={() => onOpenActor(actor)}
          >
            <span className="maker-actor__avatar">
              {avatar ? (
                <SoftImg
                  src={avatar}
                  alt=""
                  loading="lazy"
                  referrerPolicy="no-referrer"
                />
              ) : (
                <span className="maker-actor__ph" aria-hidden>
                  {(actor.name || '演').slice(0, 1)}
                </span>
              )}
            </span>
            <span className="maker-actor__name allow-select">{actor.name}</span>
            <span className="maker-actor__count">{actor.videosCount} 部</span>
          </button>
        );
      })}
    </div>
  );
}

/* ── 评论行 ─────────────────────────────────────── */

export function ReviewRow({ review }: { review: MakerReview }) {
  return (
    <div className="maker-review__body maker-review__body--flat">
      <div className="maker-review__head">
        <span className="maker-review__user allow-select">{review.username}</span>
        <span className="maker-review__score">
          <Star size={11} strokeWidth={2.6} aria-hidden />
          {review.score}
        </span>
        {review.likesCount > 0 ? (
          <span className="maker-review__likes">{review.likesCount} 赞</span>
        ) : null}
      </div>
      <p className="maker-review__content allow-select">{review.content}</p>
    </div>
  );
}
