'use client';

import { useState } from 'react';
import { Star } from 'lucide-react';
import { SoftImg } from '@/components/SoftImg';
import type {
  MakerCategoryId,
  MakerHotReview,
  MakerLatestFilter,
  MakerLatestSort,
  MakerMovie,
  MakerPeriod,
  MakerPlaybackFilter,
} from '@/lib/api/makers';
import {
  useMakerBrowse,
  useMakerHotReviews,
  useMakerLatest,
  useMakerMovies,
  useMakerPlayback,
  useMakerRank,
  useMakerRecentViewed,
  useMakerRecommend,
  useMakerTop,
} from '../useMakerQueries';
import { MakerMovieCard, Pager, WallSkeleton, makerImageUrl } from './shared';

/* ── 片商影片 ───────────────────────────────────── */

export function MakerMoviesBody({
  name,
  onOpenMovie,
}: {
  name: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const [page, setPage] = useState(1);
  const { data, isLoading, isFetching, error } = useMakerMovies(name, page);
  const items = data?.items || [];
  const hasMore = !!data?.hasMore;
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const loading = isLoading || (isFetching && items.length === 0);

  return (
    <div className="maker-movies">
      {loading ? <WallSkeleton /> : null}
      {!loading && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!loading && !err && items.length === 0 ? (
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
          isFetching={isFetching}
          onChange={setPage}
        />
      ) : null}
    </div>
  );
}

/* ── 榜单/最新/热门 全集页 ─────────────────────────── */

export type MakerListKind = 'rank' | 'latest' | 'top' | 'playback' | 'recommend';

export function MakerListBody({
  kind,
  category,
  period,
  sortBy = 'update',
  latestFilter: latestFilterProp,
  playbackFilter = 'all',
  year = '',
  onOpenMovie,
}: {
  kind: MakerListKind;
  category: MakerCategoryId;
  /** kind=rank 时必填 */
  period?: MakerPeriod;
  /** kind=latest 排序口径（update 磁链更新 / release 发布日期=官方「新片」） */
  sortBy?: MakerLatestSort;
  /** kind=latest 内容筛选（all 全部 / magnets 含磁链 / subtitle 含字幕） */
  latestFilter?: MakerLatestFilter;
  /** kind=playback 筛选（all 热播 / high_score 热门） */
  playbackFilter?: MakerPlaybackFilter;
  /** kind=top 年份筛选（留空为按类别榜） */
  year?: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const latestFilter = latestFilterProp ?? 'all';
  // 筛选条件变化时自动回到第 1 页：状态带上条件指纹，旧分页自然失效
  const filterKey = `${latestFilter}|${sortBy ?? ''}|${playbackFilter}|${year}`;
  const [pager, setPager] = useState({ key: filterKey, page: 1 });
  const page = pager.key === filterKey ? pager.page : 1;
  const setPage = (next: number) => setPager({ key: filterKey, page: next });
  // 只请求当前 tab 对应的数据源，避免同时打满 5 个上游接口
  const rank = useMakerRank(category, period || 'daily', kind === 'rank');
  const latest = useMakerLatest(category, page, sortBy, latestFilter, kind === 'latest');
  const top = useMakerTop(category, page, year, kind === 'top');
  const playback = useMakerPlayback(period || 'daily', playbackFilter, kind === 'playback');
  const recommend = useMakerRecommend(kind === 'recommend');

  // 各来源返回结构不同（recommend 为数组，rank 无 hasMore），逐个归一
  const source =
    kind === 'rank'
      ? {
          data: rank.data
            ? { items: rank.data.items, supported: rank.data.supported, hasMore: false }
            : undefined,
          error: rank.error,
          isPending: rank.isPending,
          isPlaceholderData: rank.isPlaceholderData,
          isFetching: rank.isFetching,
        }
      : kind === 'latest'
        ? {
            data: latest.data,
            error: latest.error,
            isPending: latest.isPending,
            isPlaceholderData: latest.isPlaceholderData,
            isFetching: latest.isFetching,
          }
        : kind === 'top'
          ? {
              data: top.data,
              error: top.error,
              isPending: top.isPending,
              isPlaceholderData: top.isPlaceholderData,
              isFetching: top.isFetching,
            }
          : kind === 'playback'
            ? {
                data: playback.data,
                error: playback.error,
                isPending: playback.isPending,
                isPlaceholderData: playback.isPlaceholderData,
                isFetching: playback.isFetching,
              }
            : {
                data: recommend.data
                  ? { items: recommend.data, supported: true, hasMore: false }
                  : undefined,
                error: recommend.error,
                isPending: recommend.isPending,
                isPlaceholderData: recommend.isPlaceholderData,
                isFetching: recommend.isFetching,
              };

  const items = source.data?.items || [];
  const hasMore = source.data?.hasMore ?? false;
  const err =
    source.error instanceof Error
      ? source.error.message
      : source.error
        ? '加载失败'
        : '';
  const loading = source.isPending || (source.isPlaceholderData && items.length === 0);
  const unsupported = source.data?.supported === false;

  return (
    <div className="maker-movies">
      {loading ? <WallSkeleton /> : null}
      {!loading && unsupported ? (
        <p className="media-empty">该类别暂无榜单数据</p>
      ) : null}
      {!loading && !unsupported && err ? (
        <p className="media-empty allow-select">{err}</p>
      ) : null}
      {!loading && !unsupported && !err && items.length === 0 ? (
        <p className="media-empty">暂无内容</p>
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

      {kind === 'latest' || kind === 'top' ? (
        <Pager
          page={page}
          hasMore={hasMore}
          isFetching={source.isFetching}
          onChange={setPage}
          meta={
            kind === 'top'
              ? `第 ${((page - 1) * 50 + 1).toString()}-${page * 50} 名`
              : `第 ${page} 页`
          }
        />
      ) : null}
    </div>
  );
}

/* ── 热评 ───────────────────────────────────────── */

export function MakerHotReviewsBody({
  period,
  onOpenMovie,
}: {
  period: MakerPeriod;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const { data, isLoading, error } = useMakerHotReviews(period);
  const items = data || [];
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';

  return (
    <div className="maker-movies">
      {isLoading ? (
        <div className="maker-reviews" aria-hidden>
          {Array.from({ length: 5 }).map((_, i) => (
            <span key={i} className="maker-review maker-review--skel" />
          ))}
        </div>
      ) : null}
      {!isLoading && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!isLoading && !err && items.length === 0 ? (
        <p className="media-empty">暂无热评</p>
      ) : null}
      {items.map((review) => (
        <HotReviewRow
          key={review.id}
          review={review}
          onOpenMovie={onOpenMovie}
        />
      ))}
    </div>
  );
}

function HotReviewRow({
  review,
  onOpenMovie,
}: {
  review: MakerHotReview;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const poster = makerImageUrl(review.movie.thumbUrl, 320);
  const [gone, setGone] = useState(false);
  return (
    <div className="maker-review">
      <button
        type="button"
        className="maker-review__movie"
        onClick={() =>
          onOpenMovie({
            id: review.movie.id,
            number: review.movie.number,
            title: review.movie.title,
            coverUrl: review.movie.thumbUrl,
            thumbUrl: review.movie.thumbUrl,
            previewUrl: null,
            releaseDate: review.movie.releaseDate,
            duration: 0,
            magnetsCount: 0,
            hasCnsub: false,
          })
        }
      >
        <span className="maker-review__thumb">
          {poster && !gone ? (
            <SoftImg
              src={poster}
              alt=""
              loading="lazy"
              referrerPolicy="no-referrer"
              onError={() => setGone(true)}
            />
          ) : null}
        </span>
        <span className="maker-review__moviemeta">
          <span className="maker-review__number">{review.movie.number}</span>
          <span className="maker-review__title">{review.movie.title}</span>
        </span>
      </button>
      <div className="maker-review__body">
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
    </div>
  );
}

/* ── 最近浏览 ───────────────────────────────────── */

export function MakerRecentViewedBody({
  onOpenMovie,
}: {
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const { data, isPending, error } = useMakerRecentViewed();
  const items = data || [];
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';

  if (isPending) return <WallSkeleton />;
  if (err) return <p className="media-empty allow-select">{err}</p>;
  if (!items.length) return <p className="media-empty">暂无浏览记录</p>;

  return (
    <div className="media-wall">
      {items.map((movie) => (
        <MakerMovieCard
          key={movie.id || movie.number}
          movie={movie}
          onClick={() => onOpenMovie(movie)}
        />
      ))}
    </div>
  );
}

/* ── 分类浏览结果 ───────────────────────────────── */

export function MakerBrowseBody({
  category,
  group,
  tagId,
  tagIds,
  actorId,
  tagName,
  dims,
  onOpenMovie,
}: {
  category: MakerCategoryId;
  group: string;
  tagId: string;
  tagIds?: string[];
  actorId?: string;
  tagName?: string;
  /** 片商 / 导演 / 片单 / 系列 等维度筛选 */
  dims?: {
    makerId?: string;
    directorId?: string;
    listId?: string;
    publisherId?: string;
    seriesId?: string;
    seriesType?: string;
    sortBy?: 'release';
    orderBy?: 'asc' | 'desc';
  };
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  // 筛选条件（标签 / 演员 / 维度）变化时回到第 1 页，避免停在上一个入口的页码
  const filterKey = [
    category,
    group,
    tagId,
    actorId || '',
    (tagIds || []).join(','),
    JSON.stringify(dims || {}),
  ].join('|');
  const [pager, setPager] = useState({ key: filterKey, page: 1 });
  const page = pager.key === filterKey ? pager.page : 1;
  const setPage = (next: number) => setPager({ key: filterKey, page: next });
  const { data, isPending, isPlaceholderData, isFetching, error } = useMakerBrowse(
    category,
    group,
    tagId,
    actorId || '',
    page,
    tagIds,
    dims,
  );
  const items = data?.items || [];
  const hasMore = !!data?.hasMore;
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const loading = isPending || (isPlaceholderData && items.length === 0);

  return (
    <div className="maker-movies">
      {tagName ? <p className="maker-desc allow-select">{tagName}</p> : null}
      {loading ? <WallSkeleton /> : null}
      {!loading && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!loading && !err && items.length === 0 ? (
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
          isFetching={isFetching}
          onChange={setPage}
        />
      ) : null}
    </div>
  );
}
