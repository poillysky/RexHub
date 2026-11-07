'use client';

import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { ChevronRight, Play, Search, Star, X } from 'lucide-react';
import { SoftImg } from '@/components/SoftImg';
import { P115SaveButton } from '@/features/home/P115SaveButton';
import { linkKindOf } from '@/lib/resourceView';
import { useOverlay } from '@/components/overlay/OverlayContext';
import type {
  MakerActor,
  MakerCategoryId,
  MakerEntityKind,
  MakerHit,
  MakerHotReview,
  MakerLatestFilter,
  MakerLatestSort,
  MakerMagnet,
  MakerMovie,
  MakerMovieDetail,
  MakerMovieSearchFilter,
  MakerPeriod,
  MakerPlaybackFilter,
  MakerResource,
  MakerReview,
  MakerSearchItem,
  MakerSearchType,
  MakerTag,
  MakerTorrent,
} from '@/lib/api/makers';
import {
  useMakerActors,
  useMakerActorDetail,
  useMakerActorRecommend,
  useMakerBrowse,
  useMakerEntity,
  useMakerHotReviews,
  useMakerLatest,
  useMakerListDetail,
  useMakerMovie,
  useMakerMovies,
  useMakerMovieSearch,
  useMakerPlayback,
  useMakerRank,
  useMakerRecentViewed,
  useMakerRecommend,
  useMakerRelatedLists,
  useMakerReviews,
  useMakerSearch,
  useMakerTags,
  useMakerTop,
  useMakerTorrents,
} from './useMakerQueries';

/* AVDB 封面 CDN 是加扰字节流，须经后端转发 AVDB img-proxy 解码 */
function makerImageUrl(url: string | null | undefined, w?: number): string {
  if (!url) return '';
  const params = new URLSearchParams({ url });
  if (w) params.set('w', String(w));
  return `/api/makers/image?${params.toString()}`;
}

/** 只有磁力 / ed2k / 115 分享链接能走 115 离线转存 */
function canSave115(url?: string | null): boolean {
  const kind = linkKindOf(url);
  return kind === 'magnet' || kind === 'ed2k' || kind === '115share';
}

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
      aria-label={`${movie.number} ${movie.title}`}
    >
      <span className="media-poster__frame media-poster__frame--wide">
        <span className="media-poster__ph" aria-hidden>
          {movie.number.slice(0, 1) || '影'}
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

function Pager({
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

function WallSkeleton({ count = 12 }: { count?: number }) {
  return (
    <div className="media-wall media-wall--skel" aria-hidden>
      {Array.from({ length: count }).map((_, i) => (
        <span key={i} className="media-poster-skel media-poster-skel--wall" />
      ))}
    </div>
  );
}

/* ── 搜索（影片 / 番号 / 片商 / 演员 / 片单 / 系列 / 导演 / 资源） ── */

type SearchMode = MakerSearchType | 'movie' | 'resource';

const SEARCH_TABS: Array<{ id: SearchMode; label: string }> = [
  { id: 'movie', label: '影片' },
  { id: 'maker', label: '片商' },
  { id: 'actor', label: '演员' },
  { id: 'list', label: '片单' },
  { id: 'series', label: '系列' },
  { id: 'director', label: '导演' },
  { id: 'code', label: '番号' },
  { id: 'resource', label: '资源' },
];

const SEARCH_PLACEHOLDER: Record<SearchMode, string> = {
  movie: '番号或标题，如 IPZZ-991',
  maker: '片商名，如 S1 / MOODYZ / Brazzers',
  actor: '演员名，如 三上悠亜',
  list: '片单名，如 SSIS',
  series: '系列名，如 Kissing Sis',
  director: '导演名',
  code: '番号前缀，如 SSIS / IPZZ',
  resource: '资源关键词，如 IPZZ-991 / MOODYZ',
};

const SEARCH_EMPTY: Record<SearchMode, string> = {
  movie: '输入番号或标题搜索',
  maker: '输入片商名搜索',
  actor: '输入演员名搜索',
  list: '输入片单名搜索',
  series: '输入系列名搜索',
  director: '输入导演名搜索',
  code: '输入番号前缀搜索',
  resource: '输入番号或片商名检索资源',
};

const SEARCH_NO_HIT: Record<SearchMode, string> = {
  movie: '没有匹配的影片',
  maker: '没有匹配的片商',
  actor: '没有匹配的演员',
  list: '没有匹配的片单',
  series: '没有匹配的系列',
  director: '没有匹配的导演',
  code: '没有匹配的番号',
  resource: '没有匹配的资源',
};

/** 搜索结果里可直接进详情页的实体类型 */
const SEARCH_ENTITY_KIND: Partial<Record<SearchMode, MakerEntityKind>> = {
  maker: 'maker',
  series: 'series',
  director: 'director',
};

/** 影片搜索筛选 chip（单选，再次点击取消） */
const MOVIE_FILTER_CHIPS: Array<{
  id: MakerMovieSearchFilter;
  label: string;
}> = [
  { id: 'subtitle', label: '有中文字幕' },
  { id: 'magnets', label: '有磁力' },
  { id: 'playable', label: '可播放' },
];

export function MakerSearchBody({
  initialQuery,
  onOpenMaker,
  onOpenMovie,
  onOpenActor,
  onOpenEntity,
  onOpenList,
}: {
  /** 预填搜索词（从详情页「片商搜索」入口进来时带番号） */
  initialQuery?: string;
  onOpenMaker: (hit: MakerHit) => void;
  onOpenMovie: (movie: MakerMovie) => void;
  onOpenActor: (actor: { id: string; name: string; videosCount: number }) => void;
  onOpenEntity: (kind: MakerEntityKind, id: string, name: string) => void;
  onOpenList: (list: { id: string; name: string }) => void;
}) {
  const [mode, setMode] = useState<SearchMode>('movie');
  const [draft, setDraft] = useState(initialQuery ?? '');
  const [q, setQ] = useState(initialQuery ?? '');
  const [movieFilter, setMovieFilter] = useState<MakerMovieSearchFilter>('all');
  const [moviePage, setMoviePage] = useState(1);
  const [resourcePage, setResourcePage] = useState(1);
  const [exact, setExact] = useState(false);

  const entityMode: MakerSearchType | null =
    mode === 'movie' || mode === 'resource' ? null : mode;
  const isEntity = entityMode !== null;
  const entities = useMakerSearch(entityMode ? q : '', entityMode ?? 'maker');
  const movies = useMakerMovieSearch(
    mode === 'movie' ? q : '',
    moviePage,
    movieFilter,
  );
  const resources = useMakerTorrents(
    mode === 'resource' ? q : '',
    resourcePage,
    exact,
  );

  const entityItems = entities.data || [];
  const movieItems = movies.data?.items || [];
  const resourceItems = resources.data?.items || [];
  const isFetching =
    mode === 'movie'
      ? movies.isFetching
      : mode === 'resource'
        ? resources.isFetching
        : entities.isFetching;
  const error =
    mode === 'movie'
      ? movies.error
      : mode === 'resource'
        ? resources.error
        : entities.error;
  const err = error instanceof Error ? error.message : error ? '搜索失败' : '';

  const submit = () => {
    setQ(draft.trim());
    setMoviePage(1);
    setResourcePage(1);
  };

  /** 站内搜索结果：按 kind 决定点进去看什么 */
  const openItem = (item: MakerSearchItem) => {
    if (item.kind === 'maker') {
      onOpenMaker({ id: item.id, name: item.name, videosCount: item.count });
      return;
    }
    if (item.kind === 'list') {
      onOpenList({ id: item.id, name: item.name });
      return;
    }
    // 番号前缀：直接切到影片搜索
    if (item.kind === 'code') {
      setMode('movie');
      setDraft(item.name);
      setQ(item.name);
      setMoviePage(1);
      return;
    }
    const kind = SEARCH_ENTITY_KIND[item.kind];
    if (kind) onOpenEntity(kind, item.id, item.name);
  };

  return (
    <div className="media-search">
      <div className="media-source-switch" role="tablist" aria-label="搜索范围">
        {SEARCH_TABS.map((tab) => (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={mode === tab.id}
            className={
              mode === tab.id
                ? 'media-source-switch__btn is-active'
                : 'media-source-switch__btn'
            }
            onClick={() => {
              setMode(tab.id);
              setMoviePage(1);
              setResourcePage(1);
            }}
          >
            {tab.label}
          </button>
        ))}
      </div>

      <form
        className="media-search__bar"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label className="media-search__field">
          <Search
            className="media-search__field-icon"
            size={16}
            strokeWidth={2.25}
            aria-hidden
          />
          <input
            className="media-search__input allow-select"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            placeholder={SEARCH_PLACEHOLDER[mode]}
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="search"
          />
        </label>
        <button type="submit" className="media-search__go">
          搜索
        </button>
      </form>

      {mode === 'movie' ? (
        <div className="maker-chip-row">
          {MOVIE_FILTER_CHIPS.map((chip) => (
            <button
              key={chip.id}
              type="button"
              className={
                movieFilter === chip.id ? 'maker-chip is-active' : 'maker-chip'
              }
              onClick={() => {
                setMovieFilter((cur) => (cur === chip.id ? 'all' : chip.id));
                setMoviePage(1);
              }}
            >
              {chip.label}
            </button>
          ))}
        </div>
      ) : null}

      {mode === 'resource' ? (
        <div className="maker-chip-row">
          <button
            type="button"
            className={exact ? 'maker-chip is-active' : 'maker-chip'}
            onClick={() => {
              setExact((v) => !v);
              setResourcePage(1);
            }}
          >
            仅番号完全匹配
          </button>
        </div>
      ) : null}

      {!q.trim() ? (
        <div className="media-empty">
          {SEARCH_EMPTY[mode]}
          <p className="media-empty__hint">
            {isEntity ? 'AVDB 站内搜索，支持中英日文' : '数据来自 AVDB，支持中英日文'}
          </p>
        </div>
      ) : null}

      {q.trim() && isFetching && (isEntity ? entityItems : movieItems).length === 0 &&
      mode !== 'resource' ? (
        mode === 'actor' ? (
          <div className="maker-actors" aria-hidden>
            {Array.from({ length: 8 }).map((_, i) => (
              <span key={i} className="maker-actor maker-actor--skel" />
            ))}
          </div>
        ) : mode === 'movie' ? (
          <WallSkeleton count={8} />
        ) : (
          <div className="maker-hits" aria-hidden>
            {Array.from({ length: 6 }).map((_, i) => (
              <span key={i} className="maker-hit maker-hit--skel" />
            ))}
          </div>
        )
      ) : null}

      {mode === 'resource' && q.trim() && isFetching && resourceItems.length === 0 ? (
        <WallSkeleton count={8} />
      ) : null}

      {!isFetching && err ? <p className="media-empty allow-select">{err}</p> : null}

      {!isFetching && !err && q.trim() && (isEntity ? entityItems : movieItems).length === 0 &&
      mode !== 'resource' ? (
        <p className="media-empty">{SEARCH_NO_HIT[mode]}</p>
      ) : null}

      {mode === 'resource' && !isFetching && !err && q.trim() && resourceItems.length === 0 ? (
        <p className="media-empty">{SEARCH_NO_HIT.resource}</p>
      ) : null}

      {isEntity && entityItems.length > 0 ? (
        mode === 'actor' ? (
          <ActorGrid
            actors={entityItems.map((item) => ({
              id: item.id,
              name: item.name,
              avatarUrl: item.avatarUrl || null,
              videosCount: item.count,
            }))}
            onOpenActor={onOpenActor}
          />
        ) : (
          <div className="maker-hits">
            {entityItems.map((item) => (
              <button
                key={item.id}
                type="button"
                className="maker-hit"
                onClick={() => openItem(item)}
              >
                <span className="maker-hit__name allow-select">{item.name}</span>
                {item.count > 0 ? (
                  <span className="maker-hit__count">{item.count} 部</span>
                ) : null}
                <ChevronRight size={15} strokeWidth={2.25} aria-hidden />
              </button>
            ))}
          </div>
        )
      ) : null}

      {mode === 'movie' && movieItems.length > 0 ? (
        <>
          <div className="media-wall">
            {movieItems.map((movie) => (
              <MakerMovieCard
                key={movie.id || movie.number}
                movie={movie}
                onClick={() => onOpenMovie(movie)}
              />
            ))}
          </div>
          <Pager
            page={moviePage}
            hasMore={!!movies.data?.hasMore}
            isFetching={movies.isFetching}
            onChange={setMoviePage}
            count={movieItems.length}
          />
        </>
      ) : null}

      {mode === 'resource' && resourceItems.length > 0 ? (
        <>
          <p className="media-empty__hint">
            共 {resources.data?.total ?? resourceItems.length} 条资源
          </p>
          <div className="maker-magnets">
            {resourceItems.map((t) => (
              <TorrentRow key={t.id} torrent={t} />
            ))}
          </div>
          <Pager
            page={resourcePage}
            hasMore={!!resources.data?.hasMore}
            isFetching={resources.isFetching}
            onChange={setResourcePage}
            count={resourceItems.length}
          />
        </>
      ) : null}
    </div>
  );
}

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
  onSortByChange,
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
  onSortByChange?: (value: MakerLatestSort) => void;
  /** kind=latest 内容筛选（all 全部 / magnets 含磁链 / subtitle 含字幕） */
  latestFilter?: MakerLatestFilter;
  /** kind=playback 筛选（all 热播 / high_score 热门） */
  playbackFilter?: MakerPlaybackFilter;
  /** kind=top 年份筛选（留空为按类别榜） */
  year?: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const [page, setPage] = useState(1);
  const latestFilter = latestFilterProp ?? 'all';
  useEffect(() => {
    setPage(1);
  }, [latestFilter, sortBy, playbackFilter, year]);
  const rank = useMakerRank(category, period || 'daily');
  const latest = useMakerLatest(category, page, sortBy, latestFilter);
  const top = useMakerTop(category, page, year);
  const playback = useMakerPlayback(period || 'daily', playbackFilter);
  const recommend = useMakerRecommend();

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
  const loading = source.isPending || source.isPlaceholderData;
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

/* ── 演员 ───────────────────────────────────────── */

export function ActorGrid({
  actors,
  onOpenActor,
}: {
  actors: MakerActor[];
  onOpenActor: (actor: { id: string; name: string; videosCount: number }) => void;
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
                  {actor.name.slice(0, 1)}
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

type ActorRecommendGroup = 'new' | 'monthly' | 'fanza';

const ACTOR_RECOMMEND_TABS: Array<{ id: ActorRecommendGroup; label: string }> = [
  { id: 'new', label: '新人' },
  { id: 'monthly', label: '月榜' },
  { id: 'fanza', label: 'FANZA(DMM)推荐' },
];

export function MakerActorsRecommendBody({
  onOpenActor,
}: {
  onOpenActor: (actor: { id: string; name: string; videosCount: number }) => void;
}) {
  const { data, isPending, error } = useMakerActorRecommend();
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const groups = ACTOR_RECOMMEND_TABS.map((tab) => ({
    ...tab,
    actors: data
      ? tab.id === 'new'
        ? data.newActors
        : tab.id === 'monthly'
          ? data.monthlyActors
          : data.recommendActors
      : [],
  }));
  const empty = groups.every((g) => g.actors.length === 0);

  return (
    <>
      {isPending ? (
        <div className="maker-actors" aria-hidden>
          {Array.from({ length: 8 }).map((_, i) => (
            <span key={i} className="maker-actor maker-actor--skel" />
          ))}
        </div>
      ) : null}
      {!isPending && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!isPending && !err && empty ? (
        <p className="media-empty">暂无演员</p>
      ) : null}
      {!isPending && !err
        ? groups.map((group) =>
            group.actors.length > 0 ? (
              <section key={group.id} className="media-detail__section">
                <h3 className="media-detail__h">
                  {group.label}
                  <span className="maker-actors__badge">{group.actors.length}</span>
                </h3>
                <ActorGrid actors={group.actors} onOpenActor={onOpenActor} />
              </section>
            ) : null,
          )
        : null}
    </>
  );
}

/** 演员总入口：推荐（新人 / 月榜 / FANZA 推荐）+ 有码 / 无码 / 欧美 */
export function MakerActorsHubBody({
  category,
  recommend,
  onSelectTab,
  onOpenActor,
}: {
  category: MakerCategoryId;
  recommend: boolean;
  onSelectTab: (next: { category: MakerCategoryId; recommend: boolean }) => void;
  onOpenActor: (actor: { id: string; name: string; videosCount: number }) => void;
}) {
  const tabs: Array<{ id: string; label: string }> = [
    { id: 'recommend', label: '推荐' },
    { id: '0', label: '有码' },
    { id: '1', label: '无码' },
    { id: '2', label: '欧美' },
  ];

  return (
    <div className="maker-actors-page">
      <div className="media-source-switch" role="tablist" aria-label="演员分类">
        {tabs.map((tab) => {
          const active =
            tab.id === 'recommend' ? recommend : !recommend && tab.id === category;
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={active}
              className={
                active
                  ? 'media-source-switch__btn is-active'
                  : 'media-source-switch__btn'
              }
              onClick={() =>
                onSelectTab(
                  tab.id === 'recommend'
                    ? { category, recommend: true }
                    : { category: tab.id as MakerCategoryId, recommend: false },
                )
              }
            >
              {tab.label}
            </button>
          );
        })}
      </div>
      {recommend ? (
        <MakerActorsRecommendBody onOpenActor={onOpenActor} />
      ) : (
        <MakerActorsBody category={category} onOpenActor={onOpenActor} />
      )}
    </div>
  );
}

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

export function MakerActorsBody({
  category,
  onOpenActor,
}: {
  category: MakerCategoryId;
  onOpenActor: (actor: { id: string; name: string; videosCount: number }) => void;
}) {
  const [page, setPage] = useState(1);
  const { data, isLoading, isFetching, error } = useMakerActors(category, page);
  const items = data || [];
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const loading = isLoading || (isFetching && items.length === 0);

  return (
    <div className="maker-movies">
      {loading ? (
        <div className="maker-actors" aria-hidden>
          {Array.from({ length: 8 }).map((_, i) => (
            <span key={i} className="maker-actor maker-actor--skel" />
          ))}
        </div>
      ) : null}
      {!loading && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!loading && !err && items.length === 0 ? (
        <p className="media-empty">暂无演员</p>
      ) : null}
      {items.length > 0 ? (
        <ActorGrid actors={items} onOpenActor={onOpenActor} />
      ) : null}
      {items.length > 0 ? (
        <Pager
          page={page}
          hasMore={items.length >= 24}
          isFetching={isFetching}
          onChange={setPage}
          count={items.length}
        />
      ) : null}
    </div>
  );
}

/* ── 分类浏览（标签） ─────────────────────────────── */

/** 单选组：基本 / 年份 / 月份 / 时长 */
const SINGLE_GROUPS = new Set(['main', 'year', 'month', 'duration']);

/** 分类浏览的分组顺序（对齐 AVDB / JavDB 标准筛选面板） */
const TAG_GROUP_ORDER = [
  'main',
  'year',
  'subject',
  'role',
  'cloth',
  'body',
  'behavior',
  'play_method',
  'category',
  'duration',
];

/** 未列出的分组（其他 / 场景 / 标签）排在「时长」之前 */
function tagGroupRank(id: string): number {
  const i = TAG_GROUP_ORDER.indexOf(id);
  return i < 0 ? TAG_GROUP_ORDER.length - 1 : i;
}

/** 「资源」组：main 组里的资源类标签，浏览时走 main_filter */
const RESOURCE_TAGS: MakerTag[] = [
  { id: 'p', name: '可播放' },
  { id: 'm', name: '可下载' },
  { id: 'c', name: '有字幕' },
];

/** 「类型」组：切换内容类别 */
const TYPE_TAGS: MakerTag[] = [
  { id: '0', name: '有码' },
  { id: '1', name: '无码' },
  { id: '2', name: '欧美' },
  { id: '3', name: 'FC2' },
  { id: '4', name: '动漫' },
];

type TagRow = {
  key: string;
  name: string;
  tags: MakerTag[];
  kind: 'resource' | 'type' | 'tag';
  /** 浏览页使用的 group 参数（type 组不跳浏览页） */
  browseGroup?: string;
  single: boolean;
};

type TagFilter = { group: string; tagId: string; tagIds?: string[] };

const ALL_FILTER: TagFilter = { group: '', tagId: '' };

/** 单行分组：按可用宽度自动缩减 chip 数量，超出部分「更多」展开 */
function TagRowView({
  row,
  category,
  active,
  expanded,
  onOpenAll,
  onToggleExpanded,
  onSelectCategory,
  onPickSingle,
  onToggleMulti,
}: {
  row: TagRow;
  category: MakerCategoryId;
  active: TagFilter;
  expanded: boolean;
  onOpenAll: () => void;
  onToggleExpanded: () => void;
  onSelectCategory: (category: MakerCategoryId) => void;
  onPickSingle: (group: string, tag: MakerTag) => void;
  onToggleMulti: (group: string, tag: MakerTag) => void;
}) {
  const rowRef = useRef<HTMLDivElement | null>(null);
  const [visible, setVisible] = useState<number | null>(null);
  const [overflow, setOverflow] = useState(false);

  const group = row.browseGroup || 'main';
  const allActive =
    row.kind === 'type' ? category === '0' : !(active.group === group);

  const chips: Array<{
    key: string;
    name: string;
    active: boolean;
    onClick: () => void;
  }> = [
    { key: '__all', name: '全部', active: allActive, onClick: onOpenAll },
    ...row.tags.map((tag) => {
      if (row.kind === 'type') {
        return {
          key: tag.id,
          name: tag.name,
          active: tag.id === category,
          onClick: () => onSelectCategory(tag.id as MakerCategoryId),
        };
      }
      if (row.single) {
        return {
          key: tag.id,
          name: tag.name,
          active: active.group === group && active.tagId === tag.id,
          onClick: () => onPickSingle(group, tag),
        };
      }
      return {
        key: tag.id,
        name: tag.name,
        active: active.group === row.key && (active.tagIds || []).includes(tag.id),
        onClick: () => onToggleMulti(row.key, tag),
      };
    }),
  ];

  useEffect(() => {
    const el = rowRef.current;
    if (!el) return;
    if (expanded) {
      setVisible(null);
      return;
    }
    const measure = () => {
      const box = el.getBoundingClientRect();
      const items = Array.from(el.children) as HTMLElement[];
      let n = 0;
      for (const item of items) {
        if (item.getBoundingClientRect().right <= box.right + 1) n += 1;
        else break;
      }
      setVisible(n);
      setOverflow(n < items.length);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [expanded, chips.length]);

  const hiddenFrom = !expanded && visible != null ? visible : Infinity;

  return (
    <section className="maker-tags__cat">
      <h3 className="maker-tags__label">{row.name}</h3>
      <div className="maker-tags__row" data-expanded={expanded ? '' : undefined}>
        <div className="maker-chip-row" ref={rowRef}>
          {chips.map((chip, i) => {
            const hidden = i >= hiddenFrom;
            return (
              <button
                key={chip.key}
                type="button"
                className={chip.active ? 'maker-chip is-active' : 'maker-chip'}
                style={hidden ? { visibility: 'hidden' } : undefined}
                aria-hidden={hidden || undefined}
                tabIndex={hidden ? -1 : undefined}
                onClick={chip.onClick}
              >
                {chip.name}
              </button>
            );
          })}
        </div>
        {overflow || expanded ? (
          <button
            type="button"
            className="maker-tags__more"
            onClick={onToggleExpanded}
          >
            {expanded ? '收起' : '更多'}
          </button>
        ) : null}
      </div>
    </section>
  );
}

export function MakerTagsBody({
  category,
  onSelectCategory,
  onOpenMovie,
}: {
  category: MakerCategoryId;
  /** 「类型」组：切换类别 */
  onSelectCategory: (category: MakerCategoryId) => void;
  /** 点击影片封面打开详情 */
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const { data, isLoading, error } = useMakerTags(category);
  const [filter, setFilter] = useState<TagFilter>(ALL_FILTER);
  const [page, setPage] = useState(1);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const active = filter;

  const browse = useMakerBrowse(
    category,
    active.group,
    active.tagId,
    '',
    page,
    active.tagIds,
  );
  const items = browse.data?.items || [];
  const hasMore = !!browse.data?.hasMore;
  const listLoading = browse.isPending || browse.isPlaceholderData;
  const browseErr =
    browse.error instanceof Error
      ? browse.error.message
      : browse.error
        ? '加载失败'
        : '';

  const apply = (next: TagFilter) => {
    setFilter(next);
    setPage(1);
  };
  const reset = () => apply(ALL_FILTER);

  useEffect(() => {
    setFilter(ALL_FILTER);
    setPage(1);
  }, [category]);

  const toggleExpanded = (key: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const pickSingle = (group: string, tag: MakerTag) => {
    if (active.group === group && active.tagId === tag.id) reset();
    else apply({ group, tagId: tag.id });
  };

  const toggleMulti = (group: string, tag: MakerTag) => {
    const prevIds = active.group === group ? active.tagIds || [] : [];
    const ids = prevIds.includes(tag.id)
      ? prevIds.filter((id) => id !== tag.id)
      : [...prevIds, tag.id];
    if (ids.length === 0) reset();
    else apply({ group, tagId: '', tagIds: ids });
  };

  const rows: TagRow[] = [
    {
      key: 'resource',
      name: '资源',
      tags: RESOURCE_TAGS,
      kind: 'resource',
      browseGroup: 'main',
      single: true,
    },
    { key: 'type', name: '类型', tags: TYPE_TAGS, kind: 'type', single: true },
    ...(data?.categories || [])
      .filter((c) => c.id !== 'month')
      .slice()
      .sort((a, b) => tagGroupRank(a.id) - tagGroupRank(b.id))
      .map<TagRow>((c) => ({
        key: c.id,
        name: c.name,
        tags: c.tags,
        kind: 'tag',
        browseGroup: c.id,
        single: SINGLE_GROUPS.has(c.id),
      })),
  ];

  const selectCategory = (next: MakerCategoryId) => {
    setFilter(ALL_FILTER);
    setPage(1);
    onSelectCategory(next);
  };

  const openAll = (row: TagRow) => {
    if (row.kind === 'type') {
      selectCategory('0');
      return;
    }
    reset();
  };

  return (
    <div className="maker-movies">
      {isLoading ? (
        <div className="maker-chip-row" aria-hidden>
          {Array.from({ length: 10 }).map((_, i) => (
            <span key={i} className="maker-chip maker-chip--skel" />
          ))}
        </div>
      ) : null}
      {!isLoading && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!isLoading && !err && (data?.categories || []).length === 0 ? (
        <p className="media-empty">暂无分类</p>
      ) : null}
      {!isLoading && !err
        ? rows.map((row) => (
            <TagRowView
              key={row.key}
              row={row}
              category={category}
              active={active}
              expanded={expanded.has(row.key)}
              onOpenAll={() => openAll(row)}
              onToggleExpanded={() => toggleExpanded(row.key)}
              onSelectCategory={selectCategory}
              onPickSingle={pickSingle}
              onToggleMulti={toggleMulti}
            />
          ))
        : null}

      {!isLoading && !err ? (
        <div className="maker-tags__results">
          {listLoading ? <WallSkeleton /> : null}
          {!listLoading && browseErr ? (
            <p className="media-empty allow-select">{browseErr}</p>
          ) : null}
          {!listLoading && !browseErr && items.length === 0 ? (
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
              count={items.length}
            />
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

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
  const [page, setPage] = useState(1);
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
  const loading = isPending || isPlaceholderData;

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

/* ── 影片详情 ───────────────────────────────────── */

function magnetMeta(m: MakerMagnet): string {
  return [m.size, m.createdAt, m.filesCount > 1 ? `${m.filesCount} 个文件` : '']
    .filter(Boolean)
    .join(' · ');
}

function MagnetRow({ magnet }: { magnet: MakerMagnet }) {
  const { toast } = useOverlay();
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(magnet.url);
      toast('磁力链接已复制', 'success');
    } catch {
      toast('复制失败，请长按选择', 'error');
    }
  };
  return (
    <div className="maker-magnet">
      <div className="maker-magnet__head">
        <span className="maker-magnet__name allow-select">
          {magnet.name || '磁力链接'}
        </span>
        <div className="maker-magnet__actions">
          <button type="button" className="maker-magnet__btn" onClick={copy}>
            复制
          </button>
          <P115SaveButton
            item={{
              hash: '',
              name: magnet.name || '磁力链接',
              ed2k_link: magnet.url,
              ed2k_links: [magnet.url],
              link_kind: 'magnet',
            }}
            urls={[magnet.url]}
            source="maker"
            className="maker-magnet__btn maker-magnet__btn--p115"
            onToast={(msg) => toast(msg, 'info')}
          />
        </div>
      </div>
      {magnetMeta(magnet) ? (
        <span className="maker-magnet__meta">{magnetMeta(magnet)}</span>
      ) : null}
    </div>
  );
}

function ResourceRow({ resource }: { resource: MakerResource }) {
  const { toast } = useOverlay();
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(resource.url);
      toast(`${resource.type.toUpperCase()} 链接已复制`, 'success');
    } catch {
      toast('复制失败，请长按选择', 'error');
    }
  };
  const size = resource.sizeBytes
    ? `${(resource.sizeBytes / 1024 / 1024 / 1024).toFixed(2)} GB`
    : '';
  return (
    <div className="maker-magnet">
      <div className="maker-magnet__head">
        <span className="maker-magnet__name allow-select">
          {resource.type.toUpperCase()}
          {resource.hd ? ' · HD' : ''} · {resource.name || '资源'}
        </span>
        <div className="maker-magnet__actions">
          <button type="button" className="maker-magnet__btn" onClick={copy}>
            复制
          </button>
          {canSave115(resource.url) ? (
            <P115SaveButton
              item={{
                hash: resource.hash || '',
                name: resource.name || '资源',
                ed2k_link: resource.url,
                ed2k_links: [resource.url],
                link_kind: linkKindOf(resource.url),
              }}
              urls={[resource.url]}
              source="maker"
              className="maker-magnet__btn maker-magnet__btn--p115"
              onToast={(msg) => toast(msg, 'info')}
            />
          ) : null}
        </div>
      </div>
      <span className="maker-magnet__meta">
        {[size, resource.sourceLabel, resource.hash].filter(Boolean).join(' · ')}
      </span>
    </div>
  );
}

/** 影片评论详情页：展示全部评论 */
export function MakerMovieReviewsBody({ id }: { id: string }) {
  const [page, setPage] = useState(1);
  const { data, isLoading, isFetching, error } = useMakerReviews(id, page);
  const items = data || [];
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';

  if (isLoading) {
    return (
      <div className="maker-movies">
        <div className="maker-reviews" aria-hidden>
          {Array.from({ length: 6 }).map((_, i) => (
            <span key={i} className="maker-review maker-review--skel" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="maker-movies">
      {err ? <p className="media-empty allow-select">{err}</p> : null}
      {!err && items.length === 0 ? <p className="media-empty">暂无评论</p> : null}
      <div className="maker-reviews">
        {items.map((r) => (
          <ReviewRow key={r.id || `${r.username}-${r.createdAt}`} review={r} />
        ))}
      </div>
      {items.length >= 20 || page > 1 ? (
        <Pager page={page} hasMore={true} isFetching={isFetching} onChange={setPage} />
      ) : null}
    </div>
  );
}

function ReviewRow({ review }: { review: MakerReview }) {
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

/* ── AVDB 自有种子库资源 ────────────────────────── */

function torrentSize(t: MakerTorrent): string {
  if (t.sizeBytes) return `${(t.sizeBytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  if (t.sizeMb) return `${(t.sizeMb / 1024).toFixed(2)} GB`;
  return '';
}

function torrentFlags(t: MakerTorrent): string[] {
  const flags: string[] = [];
  if (t.chinese) flags.push('中文');
  if (t.uncensored) flags.push('无码');
  if (t.uc) flags.push('破解');
  if (t.uhd) flags.push('4K');
  else if (t.hd) flags.push('HD');
  if (t.mosaic) flags.push('有码');
  if (t.free) flags.push('免费');
  return flags;
}

function TorrentRow({ torrent }: { torrent: MakerTorrent }) {
  const { toast } = useOverlay();
  const [gone, setGone] = useState(false);
  const isMagnet = torrent.downloadUrl.startsWith('magnet:');
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(torrent.downloadUrl);
      toast(isMagnet ? '磁力链接已复制' : '下载链接已复制', 'success');
    } catch {
      toast('复制失败，请长按选择', 'error');
    }
  };
  const cover = makerImageUrl(torrent.previewImage, 320);
  const flags = torrentFlags(torrent);

  return (
    <div className="maker-magnet maker-torrent">
      {cover && !gone ? (
        <span className="maker-torrent__cover">
          <SoftImg
            src={cover}
            alt=""
            loading="lazy"
            referrerPolicy="no-referrer"
            onError={() => setGone(true)}
          />
        </span>
      ) : null}
      <div className="maker-torrent__body">
        <div className="maker-magnet__head">
          <span className="maker-magnet__name allow-select">
            {torrent.website || torrent.site || torrent.section || '资源'}
          </span>
          <div className="maker-torrent__actions">
            <button type="button" className="maker-magnet__btn" onClick={copy}>
              {isMagnet ? '复制磁力' : '复制链接'}
            </button>
            {canSave115(torrent.downloadUrl) ? (
              <P115SaveButton
                item={{
                  hash: '',
                  name: torrent.title || torrent.number || '资源',
                  title: torrent.title,
                  ed2k_link: torrent.downloadUrl,
                  ed2k_links: [torrent.downloadUrl],
                  link_kind: linkKindOf(torrent.downloadUrl),
                }}
                urls={[torrent.downloadUrl]}
                source="maker"
                className="maker-magnet__btn maker-magnet__btn--p115"
                onToast={(msg) => toast(msg, 'info')}
              />
            ) : null}
          </div>
          {flags.length > 0 ? (
            <span className="maker-chip-row maker-torrent__flags">
              {flags.map((f) => (
                <span key={f} className="maker-chip">
                  {f}
                </span>
              ))}
            </span>
          ) : null}
        </div>
        {torrent.title ? (
          <span className="maker-torrent__title allow-select">{torrent.title}</span>
        ) : null}
        <span className="maker-magnet__meta">
          {[
            torrent.number,
            torrentSize(torrent),
            torrent.seeders ? `${torrent.seeders} 做种` : '',
            torrent.postTime || '',
            torrent.tags.join(' '),
          ]
            .filter(Boolean)
            .join(' · ')}
        </span>
      </div>
    </div>
  );
}

export function MakerMovieBody({
  id,
  seed,
  onOpenActor,
  onOpenEntity,
  onOpenList,
  onOpenMovie,
  onOpenReviews,
  onOpenSearch,
}: {
  id: string;
  seed?: MakerMovie | null;
  onOpenActor?: (actor: { id: string; name: string; videosCount: number }) => void;
  onOpenEntity?: (kind: MakerEntityKind, id: string, name: string) => void;
  onOpenList?: (list: { id: string; name: string }) => void;
  onOpenMovie?: (movie: MakerMovie) => void;
  onOpenReviews?: () => void;
  onOpenSearch?: (query: string) => void;
}) {
  const { data, isLoading, error } = useMakerMovie(id);
  const detail: MakerMovieDetail | undefined = data;
  /** 顶栏配图沿用入口卡片那张图（列表卡用的是 cover / thumb），不再用预览截图 */
  const poster =
    makerImageUrl(seed?.coverUrl, 720) ||
    makerImageUrl(seed?.thumbUrl, 720) ||
    makerImageUrl(detail?.coverUrl, 720) ||
    makerImageUrl(detail?.thumbUrl, 720);
  const [imgGone, setImgGone] = useState(false);
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';

  const reviews = useMakerReviews(id, 1);
  const reviewItems = reviews.data || [];
  const reviewTotal = detail?.reviewsCount || reviewItems.length;
  const hasMoreReviews = reviewTotal > 10;

  const title = detail?.number || seed?.number || detail?.title || seed?.title || id;
  const subtitle = detail?.title || seed?.title || '';
  const metaLine = [
    detail?.releaseDate || seed?.releaseDate || '',
    detail?.duration || seed?.duration
      ? `${detail?.duration || seed?.duration} 分钟`
      : '',
    (detail?.magnetsCount ?? seed?.magnetsCount)
      ? `${detail?.magnetsCount ?? seed?.magnetsCount} 个磁力`
      : '',
    detail?.hasCnsub || seed?.hasCnsub ? '中文字幕' : '',
    detail?.score != null && detail.score !== '' ? `评分 ${detail.score}` : '',
    detail?.watchedCount ? `${detail.watchedCount} 次观看` : '',
  ]
    .filter(Boolean)
    .join(' · ');
  const plainTags = detail?.tags || [];
  const magnets = detail?.magnets || [];
  const resources = detail?.resources || [];
  const torrents = detail?.avdbTorrents || [];
  const relative = detail?.relativeMovies || [];
  const previewUrl = detail?.previewVideoUrl || null;

  return (
    <div className="media-detail media-detail--hero-right">
      {poster && !imgGone ? (
        <div className="media-detail__wash" aria-hidden>
          <SoftImg
            src={poster}
            loading="eager"
            fetchPriority="high"
            onError={() => setImgGone(true)}
          />
        </div>
      ) : null}

      <div className="media-detail__hero">
        <div className="media-detail__poster" aria-hidden>
          <span className="media-detail__poster-ph">{title.slice(0, 1)}</span>
          {poster && !imgGone ? (
            <SoftImg
              src={poster}
              loading="eager"
              fetchPriority="high"
              onError={() => setImgGone(true)}
            />
          ) : null}
          {detail?.score != null && detail.score !== '' ? (
            <span className="media-detail__score">
              <Star size={11} strokeWidth={2.6} aria-hidden />
              <span className="media-detail__score-n">{detail.score}</span>
            </span>
          ) : null}
        </div>
        <div className="media-detail__meta">
          <h2 className="media-detail__title allow-select">{title}</h2>
          {subtitle ? (
            <p className="media-detail__aka allow-select">{subtitle}</p>
          ) : null}

          <div className="media-detail__stats">
            <div className="media-detail__stats-main">
              {metaLine ? (
                <p className="media-detail__meta-line allow-select">{metaLine}</p>
              ) : null}
            </div>
          </div>
        </div>
      </div>

      {isLoading && !detail ? (
        <p className="media-empty">加载中…</p>
      ) : null}
      {!isLoading && err ? <p className="media-empty allow-select">{err}</p> : null}

      {detail?.summary ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">简介</h3>
          <p className="media-detail__overview allow-select">{detail.summary}</p>
        </section>
      ) : null}

      {detail?.actors?.length ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">演员</h3>
          <div className="media-detail__tags">
            {detail.actors.slice(0, 12).map((a) => {
              const avatar = makerImageUrl(a.avatarUrl, 96);
              return (
                <button
                  key={a.id || a.name}
                  type="button"
                  className="media-detail__tag media-detail__tag--btn media-detail__tag--actor"
                  onClick={() =>
                    onOpenActor?.({
                      id: a.id,
                      name: a.name,
                      videosCount: 0,
                    })
                  }
                >
                  {avatar ? (
                    <img
                      className="media-detail__tag-avatar"
                      src={avatar}
                      alt=""
                      loading="lazy"
                      referrerPolicy="no-referrer"
                    />
                  ) : null}
                  {a.name}
                </button>
              );
            })}
          </div>
        </section>
      ) : null}

      {(detail?.makers?.length || plainTags.length || detail?.publisher) ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">标签</h3>
          <div className="media-detail__tags">
            {(detail?.makers || []).slice(0, 4).map((m) => (
              <button
                key={`m-${m.id || m.name}`}
                type="button"
                className="media-detail__tag media-detail__tag--btn"
                onClick={() => onOpenEntity?.('maker', m.id, m.name)}
              >
                {m.name}
              </button>
            ))}
            {detail?.director && detail.directorId ? (
              <button
                type="button"
                className="media-detail__tag media-detail__tag--btn"
                onClick={() =>
                  onOpenEntity?.('director', detail.directorId!, detail.director!)
                }
              >
                导演 {detail.director}
              </button>
            ) : null}
            {detail?.series && detail.seriesId ? (
              <button
                type="button"
                className="media-detail__tag media-detail__tag--btn"
                onClick={() =>
                  onOpenEntity?.('series', detail.seriesId!, detail.series!)
                }
              >
                系列 {detail.series}
              </button>
            ) : null}
            {detail?.publisher ? (
              <span className="media-detail__tag">{detail.publisher}</span>
            ) : null}
            {plainTags.slice(0, 6).map((t) => (
              <span key={`t-${t}`} className="media-detail__tag">
                {t}
              </span>
            ))}
          </div>
        </section>
      ) : null}

      {previewUrl || detail?.previews?.length || onOpenSearch ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">预览和搜索</h3>
          <div className="maker-preview-row">
            {previewUrl ? <MakerPreviewPlayer src={previewUrl} /> : null}
            {onOpenSearch ? (
              <button
                type="button"
                className="media-detail__cta media-detail__cta--bt"
                onClick={() =>
                  onOpenSearch(detail?.number || seed?.number || title)
                }
              >
                <Search size={17} strokeWidth={2.25} aria-hidden />
                搜索
              </button>
            ) : null}
          </div>
          {detail?.previews?.length ? (
            <>
              <h4 className="media-detail__h media-detail__subh">图片</h4>
              <div className="maker-previews">
                {detail.previews.slice(0, 12).map((p, i) => (
                  <SoftImg
                    key={`pv-${i}`}
                    className="maker-preview allow-select"
                    src={makerImageUrl(p.large || p.thumb, 480)}
                    alt=""
                    loading="lazy"
                    referrerPolicy="no-referrer"
                  />
                ))}
              </div>
            </>
          ) : null}
        </section>
      ) : null}

      {magnets.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">磁力链接</h3>
          <div className="maker-magnets">
            {magnets.map((m, i) => (
              <MagnetRow key={`${m.url}-${i}`} magnet={m} />
            ))}
          </div>
        </section>
      ) : null}

      {resources.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">共享资源</h3>
          <div className="maker-magnets">
            {resources.map((r) => (
              <ResourceRow key={`${r.id}-${r.url}`} resource={r} />
            ))}
          </div>
        </section>
      ) : null}

      {torrents.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">AVDB 资源（{torrents.length}）</h3>
          <div className="maker-magnets">
            {torrents.map((t) => (
              <TorrentRow key={t.id} torrent={t} />
            ))}
          </div>
        </section>
      ) : null}

      {reviewItems.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">
            评论{detail?.reviewsCount ? `（${detail.reviewsCount}）` : ''}
          </h3>
          <div className="maker-reviews">
            {reviewItems.slice(0, 10).map((r) => (
              <ReviewRow key={r.id || `${r.username}-${r.createdAt}`} review={r} />
            ))}
          </div>
          {hasMoreReviews ? (
            <button
              type="button"
              className="maker-reviews__more"
              onClick={() => onOpenReviews?.()}
            >
              查看全部 {reviewTotal} 条评论
            </button>
          ) : null}
        </section>
      ) : null}

      {relative.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">相关影片</h3>
          <div className="media-shelf__rail">
            {relative.slice(0, 12).map((m) => (
              <MakerMovieCard
                key={`rel-${m.id || m.number}`}
                movie={m}
                onClick={() => onOpenMovie?.(m)}
              />
            ))}
          </div>
        </section>
      ) : null}

      {detail?.actorMovies?.length ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">同演员作品</h3>
          <div className="media-shelf__rail">
            {detail.actorMovies.slice(0, 12).map((m) => (
              <MakerMovieCard
                key={`am-${m.id || m.number}`}
                movie={{
                  id: m.id,
                  number: m.number,
                  title: m.title,
                  coverUrl: m.coverUrl,
                  thumbUrl: m.thumbUrl,
                  previewUrl: null,
                  releaseDate: null,
                  duration: 0,
                  magnetsCount: 0,
                  hasCnsub: false,
                }}
                onClick={() =>
                  onOpenMovie?.({
                    id: m.id,
                    number: m.number,
                    title: m.title,
                    coverUrl: m.coverUrl,
                    thumbUrl: m.thumbUrl,
                    previewUrl: null,
                    releaseDate: null,
                    duration: 0,
                    magnetsCount: 0,
                    hasCnsub: false,
                  })
                }
              />
            ))}
          </div>
        </section>
      ) : null}

      {detail?.topRankings?.length ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">榜单排名</h3>
          <div className="maker-chip-row">
            {detail.topRankings.map((t, i) => (
              <span key={`tr-${t.type}-${t.period}-${i}`} className="maker-chip">
                {t.type} {t.period} 第 {t.rank} 名
              </span>
            ))}
          </div>
        </section>
      ) : null}

      {onOpenList ? (
        <MakerRelatedLists movieId={id} onOpenList={onOpenList} />
      ) : null}

      {detail?.shareUrl ? (
        <section className="media-detail__section">
          <a
            className="maker-link"
            href={detail.shareUrl}
            target="_blank"
            rel="noreferrer"
          >
            在 AVDB 查看原始条目
          </a>
        </section>
      ) : null}
    </div>
  );
}

/* ── 预览视频（AVDB preview_video_url 直连 HLS，CORS 已开放） ───── */

const NATIVE_HLS =
  typeof window !== 'undefined' &&
  (window as unknown as { canPlayType?: (t: string) => string }).canPlayType?.(
    'application/vnd.apple.mpegurl',
  );

function MakerPreviewPlayer({ src }: { src: string }) {
  const [open, setOpen] = useState(false);
  const [mounted, setMounted] = useState(false);

  useEffect(() => setMounted(true), []);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open]);

  return (
    <div className="maker-video">
      <button
        type="button"
        className="maker-video__trigger"
        onClick={() => setOpen(true)}
      >
        <span className="maker-video__play" aria-hidden>
          <Play size={22} strokeWidth={2} fill="currentColor" />
        </span>
        预览
      </button>
      {open && mounted
        ? createPortal(
            <div
              className="maker-video-modal"
              role="dialog"
              aria-modal="true"
              aria-label="预览视频"
              onClick={() => setOpen(false)}
            >
              <div
                className="maker-video-modal__panel"
                onClick={(e) => e.stopPropagation()}
              >
                <button
                  type="button"
                  className="maker-video-modal__close"
                  aria-label="关闭"
                  onClick={() => setOpen(false)}
                >
                  <X size={20} strokeWidth={2.4} />
                </button>
                <PreviewVideo src={src} />
              </div>
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}

/** 弹窗内实际播放器：仅在打开时才初始化 HLS */
function PreviewVideo({ src }: { src: string }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    let hls: { destroy: () => void } | null = null;
    let cancelled = false;

    if (NATIVE_HLS) {
      video.src = src;
    } else {
      void (async () => {
        try {
          const mod = await import('hls.js');
          if (cancelled || !videoRef.current) return;
          const Hls = mod.default;
          if (!Hls.isSupported()) {
            video.src = src;
            return;
          }
          const inst = new Hls({ enableWorker: true });
          inst.loadSource(src);
          inst.attachMedia(videoRef.current);
          inst.on(Hls.Events.ERROR, (_e: unknown, data: { fatal?: boolean }) => {
            if (data?.fatal) setFailed(true);
          });
          hls = inst;
        } catch {
          setFailed(true);
        }
      })();
    }

    return () => {
      cancelled = true;
      hls?.destroy();
    };
  }, [src]);

  if (failed) {
    return <p className="media-empty allow-select">预览视频加载失败</p>;
  }

  return (
    <video
      ref={videoRef}
      className="maker-video__el"
      controls
      playsInline
      autoPlay
      preload="metadata"
    />
  );
}

/* ── 实体详情（片商 / 导演 / 系列） ─────────────────── */

const ENTITY_LABEL: Record<MakerEntityKind, string> = {
  maker: '片商',
  director: '导演',
  series: '系列',
};

export function MakerEntityBody({
  kind,
  id,
  onOpenMovie,
}: {
  kind: MakerEntityKind;
  id: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const entity = useMakerEntity(kind, id);
  const dims =
    kind === 'maker'
      ? { makerId: id }
      : kind === 'director'
        ? { directorId: id }
        : { seriesId: id, seriesType: '0' };
  const browse = useMakerBrowse('0', '', '', '', 1, undefined, dims);
  const items = browse.data?.items || [];
  const err = entity.error instanceof Error ? entity.error.message : '';
  const info = entity.data;

  return (
    <div className="maker-movies">
      {!info && !err ? <p className="media-empty">加载中…</p> : null}
      {err ? <p className="media-empty allow-select">{err}</p> : null}
      {info ? (
        <div className="maker-entity">
          <p className="maker-entity__kind">{ENTITY_LABEL[kind]}</p>
          <h2 className="maker-entity__name allow-select">{info.name}</h2>
          <p className="maker-entity__meta">
            {info.videosCount ? `${info.videosCount} 部作品` : '暂无作品统计'}
          </p>
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
      {!browse.isPending && items.length === 0 ? (
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
    </div>
  );
}

/* ── 演员详情 ────────────────────────────────────── */

export function MakerActorDetailBody({
  id,
  onOpenMovie,
}: {
  id: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const actor = useMakerActorDetail(id);
  const browse = useMakerBrowse('0', '', '', id, 1);
  const items = browse.data?.items || [];
  const err = actor.error instanceof Error ? actor.error.message : '';
  const info = actor.data;

  const facts: Array<[string, string]> = info
    ? ([
        ['生日', info.birthday || ''],
        ['年龄', info.age ? `${info.age} 岁` : ''],
        ['星座', info.constellation || ''],
        ['血型', info.bloodType || ''],
        ['身高', info.height ? `${info.height} cm` : ''],
        ['胸围', info.bust ? `${info.bust} cm` : ''],
        ['腰围', info.waist ? `${info.waist} cm` : ''],
        ['臀围', info.hips ? `${info.hips} cm` : ''],
        ['罩杯', info.cup || ''],
        ['出生地', info.birthplace || ''],
      ] as Array<[string, string]>).filter(([, v]) => !!v)
    : [];

  return (
    <div className="maker-movies">
      {!info && !err ? <p className="media-empty">加载中…</p> : null}
      {err ? <p className="media-empty allow-select">{err}</p> : null}
      {info ? (
        <div className="maker-entity">
          {info.avatarUrl ? (
            <SoftImg
              className="maker-entity__avatar"
              src={info.avatarUrl}
              alt=""
              loading="lazy"
              referrerPolicy="no-referrer"
            />
          ) : null}
          <h2 className="maker-entity__name allow-select">{info.name}</h2>
          {info.nameZht ? (
            <p className="maker-entity__meta">{info.nameZht}</p>
          ) : null}
          {info.otherName ? (
            <p className="maker-entity__meta">曾用名：{info.otherName}</p>
          ) : null}
          <p className="maker-entity__meta">
            {info.videosCount ? `${info.videosCount} 部作品` : '暂无作品统计'}
          </p>
          {facts.length > 0 ? (
            <dl className="maker-facts">
              {facts.map(([k, v]) => (
                <div key={k} className="maker-facts__row">
                  <dt className="maker-facts__k">{k}</dt>
                  <dd className="maker-facts__v allow-select">{v}</dd>
                </div>
              ))}
            </dl>
          ) : null}
          {info.filterTags.length > 0 ? (
            <div className="maker-tags__cat">
              <span className="maker-tags__label">特色标签</span>
              <div className="maker-chip-row">
                {info.filterTags.map((t) => (
                  <span key={t.id} className="maker-chip">
                    {t.name}
                  </span>
                ))}
              </div>
            </div>
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
      {!browse.isPending && items.length === 0 ? (
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
    </div>
  );
}

/* ── 片单详情 ────────────────────────────────────── */

export function MakerListDetailBody({
  id,
  onOpenMovie,
}: {
  id: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const list = useMakerListDetail(id);
  const browse = useMakerBrowse('0', '', '', '', 1, undefined, { listId: id });
  const items = browse.data?.items || [];
  const err = list.error instanceof Error ? list.error.message : '';
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
      {!browse.isPending && items.length === 0 ? (
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
