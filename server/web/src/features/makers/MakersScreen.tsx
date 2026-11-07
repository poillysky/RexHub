'use client';

import { startTransition, useEffect, useState } from 'react';
import { SlidersHorizontal, Clock, Search, Users, ChevronDown } from 'lucide-react';
import type {
  MakerCategoryId,
  MakerEntityKind,
  MakerHit,
  MakerLatestSort,
  MakerLatestFilter,
  MakerMovie,
  MakerPeriod,
  MakerPlaybackFilter,
} from '@/lib/api/makers';
import { AppPush } from '@/components/ui/AppPush';
import { SoftImg } from '@/components/SoftImg';
import { writeSaveSource } from '@/lib/p115Source';
import { useTabNavigation } from '@/shell';
import { useStackCover } from '@/hooks/useStackCover';
import {
  MakerActorDetailBody,
  MakerActorsHubBody,
  MakerBrowseBody,
  MakerEntityBody,
  MakerHotReviewsBody,
  MakerListBody,
  MakerListDetailBody,
  MakerMovieBody,
  MakerMovieCard,
  MakerMovieReviewsBody,
  MakerMoviesBody,
  MakerRecentViewedBody,
  MakerSearchBody,
  MakerTagsBody,
  type MakerListKind,
} from './MakerBodies';
import {
  useMakerLatest,
  useMakerPlayback,
  useMakerRank,
  useMakerYears,
  useMakerTop,
} from './useMakerQueries';

type Stack =
  | { kind: 'hub' }
  | { kind: 'search'; q?: string }
  | { kind: 'maker'; name: string }
  | {
      kind: 'list';
      list: MakerListKind;
      category: MakerCategoryId;
      period?: MakerPeriod;
      /** kind=latest：排序口径（update 磁链更新 / release 发布日期=官方「新片」） */
      sortBy?: MakerLatestSort;
      /** kind=latest：内容筛选（all / 含磁链 / 含字幕） */
      latestFilter?: MakerLatestFilter;
      /** kind=playback：热播 / high_score 热门 */
      filterBy?: MakerPlaybackFilter;
      /** kind=top：年份榜（留空为按类别榜） */
      year?: string;
    }
  | { kind: 'tags'; category: MakerCategoryId }
  | {
      kind: 'browse';
      category: MakerCategoryId;
      group: string;
      tagId: string;
      tagIds?: string[];
      actorId?: string;
      tagName: string;
      back?: Stack;
    }
  | { kind: 'actors'; category: MakerCategoryId; recommend?: boolean }
  | { kind: 'reviews' }
  | { kind: 'entity'; entityKind: MakerEntityKind; entityId: string; name: string }
  | { kind: 'actor-detail'; actorId: string; name: string }
  | { kind: 'list-detail'; listId: string; name: string }
  | { kind: 'movie'; movie: MakerMovie; back: Stack }
  | { kind: 'movie-reviews'; movieId: string; title: string; back: Stack };

const CATEGORIES: Array<{ id: MakerCategoryId; label: string }> = [
  { id: '0', label: '有码' },
  { id: '1', label: '无码' },
  { id: '2', label: '欧美' },
  { id: '3', label: 'FC2' },
  { id: '4', label: '动漫' },
];

const PERIODS: Array<{ id: MakerPeriod; label: string }> = [
  { id: 'daily', label: '日榜' },
  { id: 'weekly', label: '周榜' },
  { id: 'monthly', label: '月榜' },
];

/** 热播页按「今日 / 本周 / 本月」分块 */
const PLAYBACK_PERIODS: Array<{ id: MakerPeriod; label: string }> = [
  { id: 'daily', label: '今日' },
  { id: 'weekly', label: '本周' },
  { id: 'monthly', label: '本月' },
];

/** AVDB 榜单接口只对 0-3 有独立数据（动漫无榜单） */
const RANK_CATEGORIES = new Set(['0', '1', '2', '3']);

function ShelfHead({
  title,
  onOpenAll,
}: {
  title: string;
  onOpenAll: () => void;
}) {
  return (
    <div className="media-shelf__head">
      <span className="media-shelf__title">{title}</span>
      <button type="button" className="media-shelf__more" onClick={onOpenAll}>
        全部
      </button>
    </div>
  );
}

function RankShelf({
  category,
  period,
  label,
  onOpenAll,
  onOpenMovie,
}: {
  category: MakerCategoryId;
  period: MakerPeriod;
  label: string;
  onOpenAll: () => void;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const { data, isPending, isPlaceholderData, error } = useMakerRank(category, period);
  const items = (data?.items || []).slice(0, 12);
  const err = error instanceof Error ? error.message : '';
  const unsupported = data?.supported === false;

  return (
    <section className="media-shelf">
      <ShelfHead title={label} onOpenAll={onOpenAll} />
      <div className="media-shelf__rail">
        {isPending || isPlaceholderData
          ? Array.from({ length: 4 }).map((_, i) => (
              <span key={i} className="media-poster-skel" />
            ))
          : null}
        {!isPending && err ? (
          <p className="media-empty allow-select">{err}</p>
        ) : null}
        {!isPending && !err && unsupported ? (
          <p className="media-empty">该类别暂无榜单</p>
        ) : null}
        {!isPending && !err && !unsupported && items.length === 0 ? (
          <p className="media-empty">暂无内容</p>
        ) : null}
        {items.map((movie) => (
          <MakerMovieCard
            key={movie.id || movie.number}
            movie={movie}
            onClick={() => onOpenMovie(movie)}
          />
        ))}
      </div>
    </section>
  );
}

function ListShelf({
  category,
  kind,
  label,
  onOpenAll,
  onOpenMovie,
}: {
  category: MakerCategoryId;
  kind: 'latest' | 'top';
  label: string;
  onOpenAll: () => void;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const latest = useMakerLatest(category, 1);
  const top = useMakerTop(category, 1);
  const active = kind === 'latest' ? latest : top;
  const items = (active.data?.items || []).slice(0, 12);
  const err = active.error instanceof Error ? active.error.message : '';
  const unsupported = active.data?.supported === false;

  return (
    <section className="media-shelf">
      <ShelfHead title={label} onOpenAll={onOpenAll} />
      <div className="media-shelf__rail">
        {active.isPending || active.isPlaceholderData
          ? Array.from({ length: 4 }).map((_, i) => (
              <span key={i} className="media-poster-skel" />
            ))
          : null}
        {!active.isPending && err ? (
          <p className="media-empty allow-select">{err}</p>
        ) : null}
        {!active.isPending && !err && unsupported ? (
          <p className="media-empty">该类别暂无榜单</p>
        ) : null}
        {!active.isPending && !err && !unsupported && items.length === 0 ? (
          <p className="media-empty">暂无内容</p>
        ) : null}
        {items.map((movie) => (
          <MakerMovieCard
            key={movie.id || movie.number}
            movie={movie}
            onClick={() => onOpenMovie(movie)}
          />
        ))}
      </div>
    </section>
  );
}

/** 可播放榜（不随类别变化） */
function PlaybackShelf({
  label,
  period,
  filterBy,
  onOpenAll,
  onOpenMovie,
}: {
  label: string;
  period: MakerPeriod;
  filterBy: MakerPlaybackFilter;
  onOpenAll: () => void;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const { data, isPending, isPlaceholderData, error } = useMakerPlayback(
    period,
    filterBy,
  );
  const items = (data?.items || []).slice(0, 12);
  const err = error instanceof Error ? error.message : '';

  return (
    <section className="media-shelf">
      <ShelfHead title={label} onOpenAll={onOpenAll} />
      <div className="media-shelf__rail">
        {isPending || isPlaceholderData
          ? Array.from({ length: 4 }).map((_, i) => (
              <span key={i} className="media-poster-skel" />
            ))
          : null}
        {!isPending && err ? (
          <p className="media-empty allow-select">{err}</p>
        ) : null}
        {!isPending && !err && items.length === 0 ? (
          <p className="media-empty">暂无内容</p>
        ) : null}
        {items.map((movie) => (
          <MakerMovieCard
            key={movie.id || movie.number}
            movie={movie}
            onClick={() => onOpenMovie(movie)}
          />
        ))}
      </div>
    </section>
  );
}

export function MakersScreen() {
  const tabCtx = useTabNavigation();
  const [stack, setStack] = useState<Stack>({ kind: 'hub' });
  const [category, setCategory] = useState<MakerCategoryId>('0');
  /** 顶部 tab：热播 / 类别 / 最近浏览，同层切换内容，不推入新页面 */
  const [hubMode, setHubMode] = useState<'category' | 'playback' | 'recent' | 'tags'>(
    'category',
  );
  const hubCover = useStackCover(
    stack.kind !== 'hub',
    'maker-hub',
    'app-hub media-hub-root',
  );

  useEffect(() => {
    if (!tabCtx || tabCtx.activeTab !== '/makers') return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (tabCtx.tabReselect > 0) setStack({ kind: 'hub' });
  }, [tabCtx?.tabReselect, tabCtx?.activeTab]);

  const openMaker = (hit: MakerHit) =>
    startTransition(() => setStack({ kind: 'maker', name: hit.name }));

  const openMovie = (movie: MakerMovie, back: Stack) =>
    startTransition(() => setStack({ kind: 'movie', movie, back }));

  const openActor = (actor: { id: string; name: string }, back?: Stack) =>
    startTransition(() =>
      setStack({
        kind: 'browse',
        category,
        group: '',
        tagId: '',
        actorId: actor.id,
        tagName: `演员 · ${actor.name}`,
        back,
      }),
    );

  /** 演员详情页（资料 + 全部作品） */
  const openActorDetail = (actor: { id: string; name: string }) =>
    startTransition(() =>
      setStack({ kind: 'actor-detail', actorId: actor.id, name: actor.name }),
    );

  /** 片商 / 导演 / 系列 详情页 */
  const openEntity = (entityKind: MakerEntityKind, id: string, name: string) =>
    startTransition(() =>
      setStack({ kind: 'entity', entityKind, entityId: id, name }),
    );

  /** 片单详情页 */
  const openList = (list: { id: string; name: string }) =>
    startTransition(() =>
      setStack({ kind: 'list-detail', listId: list.id, name: list.name }),
    );

  const catLabel = CATEGORIES.find((c) => c.id === category)?.label || '';
  const rankSupported = RANK_CATEGORIES.has(category);

  const hubView = (
    <div {...hubCover}>
      <div className="media-hub__top">
        <div className="media-hub__top-row">
          <h1 className="app-hub__title">片商</h1>
          <div className="media-hub__top-actions">
            <button
              type="button"
              className="media-hub__search-btn"
              aria-label="演员"
              onClick={() =>
                startTransition(() =>
                  setStack({ kind: 'actors', category, recommend: true }),
                )
              }
            >
              <Users size={17} strokeWidth={2.4} aria-hidden />
            </button>
            <button
              type="button"
              className="media-hub__search-btn"
              aria-label="最近浏览"
              onClick={() => setHubMode('recent')}
            >
              <Clock size={17} strokeWidth={2.4} aria-hidden />
            </button>
            <button
              type="button"
              className="media-hub__search-btn"
              aria-label="搜索片商"
              onClick={() => startTransition(() => setStack({ kind: 'search' }))}
            >
              <Search size={17} strokeWidth={2.4} aria-hidden />
            </button>
          </div>
        </div>
        <div className="media-source-switch" role="tablist" aria-label="类别">
          <button
            type="button"
            role="tab"
            aria-selected={hubMode === 'playback'}
            className={
              hubMode === 'playback'
                ? 'media-source-switch__btn is-active'
                : 'media-source-switch__btn'
            }
            onClick={() => setHubMode('playback')}
          >
            热播
          </button>
          {CATEGORIES.map((c) => (
            <button
              key={c.id}
              type="button"
              role="tab"
              aria-selected={hubMode === 'category' && category === c.id}
              className={
                hubMode === 'category' && category === c.id
                  ? 'media-source-switch__btn is-active'
                  : 'media-source-switch__btn'
              }
              onClick={() => {
                setHubMode('category');
                setCategory(c.id);
              }}
            >
              {c.label}
            </button>
          ))}
          <button
            type="button"
            role="tab"
            aria-selected={hubMode === 'tags'}
            className={
              hubMode === 'tags'
                ? 'media-source-switch__btn is-active'
                : 'media-source-switch__btn'
            }
            onClick={() => setHubMode('tags')}
          >
            分类
          </button>
        </div>
      </div>

      <div className="app-hub__scroll media-hub">
        <div className="media-hub__shelves">
          {hubMode === 'playback' ? (
            PLAYBACK_PERIODS.map((p) => (
              <PlaybackShelf
                key={p.id}
                label={`热播·${p.label}`}
                period={p.id}
                filterBy="all"
                onOpenAll={() =>
                  startTransition(() =>
                    setStack({
                      kind: 'list',
                      list: 'playback',
                      category,
                      period: p.id,
                      filterBy: 'all',
                    }),
                  )
                }
                onOpenMovie={(movie) => openMovie(movie, { kind: 'hub' })}
              />
            ))
          ) : hubMode === 'recent' ? (
            <MakerRecentViewedBody
              onOpenMovie={(movie) => openMovie(movie, { kind: 'hub' })}
            />
          ) : hubMode === 'tags' ? (
            <MakerTagsBody
              category={category}
              onSelectCategory={(next) => startTransition(() => setCategory(next))}
              onOpenMovie={(movie) => openMovie(movie, { kind: 'hub' })}
            />
          ) : (
            <>
          {rankSupported
            ? PERIODS.map((p) => (
                <RankShelf
                  key={p.id}
                  category={category}
                  period={p.id}
                  label={`${p.label}·${catLabel}`}
                  onOpenAll={() =>
                    startTransition(() =>
                      setStack({
                        kind: 'list',
                        list: 'rank',
                        category,
                        period: p.id,
                      }),
                    )
                  }
                  onOpenMovie={(movie) => openMovie(movie, { kind: 'hub' })}
                />
              ))
            : null}
          <ListShelf
            category={category}
            kind="latest"
            label={`最新·${catLabel}`}
            onOpenAll={() =>
              startTransition(() =>
                setStack({ kind: 'list', list: 'latest', category }),
              )
            }
            onOpenMovie={(movie) => openMovie(movie, { kind: 'hub' })}
          />
          {rankSupported ? (
            <ListShelf
              category={category}
              kind="top"
              label={`TOP250·${catLabel}`}
              onOpenAll={() =>
                startTransition(() =>
                  setStack({ kind: 'list', list: 'top', category }),
                )
              }
              onOpenMovie={(movie) => openMovie(movie, { kind: 'hub' })}
            />
          ) : null}
            </>
          )}
        </div>
      </div>
    </div>
  );

  let push = null;

  if (stack.kind === 'search') {
    push = (
      <AppPush
        title="搜索"
        scrollKey={stack.q ? `maker-search-${stack.q}` : 'maker-search'}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerSearchBody
          initialQuery={stack.q}
          onOpenMaker={openMaker}
          onOpenMovie={(movie) => openMovie(movie, stack)}
          onOpenActor={openActorDetail}
          onOpenEntity={openEntity}
          onOpenList={openList}
        />
      </AppPush>
    );
  } else if (stack.kind === 'maker') {
    push = (
      <AppPush
        title={stack.name}
        scrollKey={`maker-${stack.name}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerMoviesBody
          key={stack.name}
          name={stack.name}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'list') {
    const title =
      stack.list === 'rank'
        ? `${PERIODS.find((p) => p.id === stack.period)?.label || ''}·${catLabel}`
        : stack.list === 'latest'
          ? `最新·${catLabel}`
          : stack.list === 'playback'
            ? `${stack.filterBy === 'high_score' ? '热门' : '热播'}·${PLAYBACK_PERIODS.find((p) => p.id === stack.period)?.label || '今日'}`
            : stack.list === 'recommend'
              ? '编辑推荐'
              : stack.year
                ? `TOP250·${stack.year}`
                : `TOP250·${catLabel}`;
    push = (
      <AppPush
        title={title}
        scrollKey={`maker-list-${stack.list}-${stack.category}-${stack.period || ''}-${stack.sortBy || ''}-${stack.latestFilter || ''}-${stack.filterBy || ''}-${stack.year || ''}`}
        onBack={() => setStack({ kind: 'hub' })}
        right={
          stack.list === 'playback' ? (
            <div
              className="maker-playback-switch"
              role="tablist"
              aria-label="热播筛选"
            >
              {(
                [
                  ['all', '热播'],
                  ['high_score', '热门'],
                ] as const
              ).map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  role="tab"
                  aria-selected={(stack.filterBy || 'all') === value}
                  className={
                    (stack.filterBy || 'all') === value
                      ? 'maker-playback-switch__btn is-active'
                      : 'maker-playback-switch__btn'
                  }
                  onClick={() =>
                    startTransition(() =>
                      setStack((prev) =>
                        prev.kind === 'list' ? { ...prev, filterBy: value } : prev,
                      ),
                    )
                  }
                >
                  {label}
                </button>
              ))}
            </div>
          ) : stack.list === 'top' ? (
            <MakerYearSelect
              value={stack.year || ''}
              onChange={(value) =>
                startTransition(() =>
                  setStack((prev) =>
                    prev.kind === 'list'
                      ? { ...prev, year: value || undefined }
                      : prev,
                  ),
                )
              }
            />
          ) : stack.list === 'latest' ? (
            <MakerLatestControls
              filter={stack.latestFilter || 'all'}
              sortBy={stack.sortBy || 'update'}
              onFilter={(value) =>
                startTransition(() =>
                  setStack((prev) =>
                    prev.kind === 'list'
                      ? { ...prev, latestFilter: value }
                      : prev,
                  ),
                )
              }
              onSort={(value) =>
                startTransition(() =>
                  setStack((prev) =>
                    prev.kind === 'list' ? { ...prev, sortBy: value } : prev,
                  ),
                )
              }
            />
          ) : undefined
        }
      >
        <MakerListBody
          kind={stack.list}
          category={stack.category}
          period={stack.period}
          sortBy={stack.sortBy}
          onSortByChange={(value) =>
            startTransition(() =>
              setStack((prev) =>
                prev.kind === 'list' ? { ...prev, sortBy: value } : prev,
              ),
            )
          }
          latestFilter={stack.latestFilter}
          playbackFilter={stack.filterBy}
          year={stack.year}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'tags') {
    push = (
      <AppPush
        title={`分类·${catLabel}`}
        scrollKey={`maker-tags-${stack.category}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerTagsBody
          category={stack.category}
          onSelectCategory={(next) =>
            startTransition(() =>
              setStack((prev) =>
                prev.kind === 'tags' ? { ...prev, category: next } : prev,
              ),
            )
          }
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'actors') {
    const recommend = !!stack.recommend;
    const label =
      CATEGORIES.find((c) => c.id === stack.category)?.label || '演员';
    push = (
      <AppPush
        title={recommend ? '演员·推荐' : `演员·${label}`}
        scrollKey={`maker-actors-${recommend ? 'recommend' : stack.category}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerActorsHubBody
          category={stack.category}
          recommend={recommend}
          onSelectTab={(next) =>
            startTransition(() =>
              setStack({ kind: 'actors', ...next }),
            )
          }
          onOpenActor={openActorDetail}
        />
      </AppPush>
    );
  } else if (stack.kind === 'reviews') {
    push = (
      <AppPush
        title="热评"
        scrollKey="maker-hot-reviews"
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerHotReviewsBody
          period="weekly"
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'browse') {
    push = (
      <AppPush
        title={stack.tagName}
        scrollKey={`maker-browse-${stack.category}-${stack.group}-${stack.tagId}-${stack.actorId || ''}-${(stack.tagIds || []).join(',')}`}
        onBack={() =>
          setStack(
            stack.back ?? { kind: 'tags', category: stack.category },
          )
        }
      >
        <MakerBrowseBody
          category={stack.category}
          group={stack.group}
          tagId={stack.tagId}
          tagIds={stack.tagIds}
          actorId={stack.actorId}
          tagName={stack.tagName}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'entity') {
    push = (
      <AppPush
        title={stack.name}
        scrollKey={`maker-entity-${stack.entityKind}-${stack.entityId}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerEntityBody
          kind={stack.entityKind}
          id={stack.entityId}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'actor-detail') {
    push = (
      <AppPush
        title={stack.name}
        scrollKey={`maker-actor-${stack.actorId}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerActorDetailBody
          id={stack.actorId}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'list-detail') {
    push = (
      <AppPush
        title={stack.name}
        scrollKey={`maker-list-${stack.listId}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <MakerListDetailBody
          id={stack.listId}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'movie') {
    const { movie, back } = stack;
    push = (
      <AppPush
        title={movie.number || movie.title}
        scrollKey={`maker-movie-${movie.id || movie.number}`}
        scrollMode="top"
        onBack={() => setStack(back)}
      >
        <MakerMovieBody
          id={movie.id}
          seed={movie}
          onOpenActor={(actor) => openActor(actor, stack)}
          onOpenEntity={openEntity}
          onOpenList={openList}
          onOpenMovie={(m) => openMovie(m, stack)}
          onOpenReviews={() =>
            startTransition(() =>
              setStack({
                kind: 'movie-reviews',
                movieId: movie.id,
                title: movie.number || movie.title || '',
                back: stack,
              }),
            )
          }
          onOpenSearch={(q) => {
            // 从片商详情进搜索：搜索结果里的转存落点仍记为「片商」
            writeSaveSource('maker');
            startTransition(() => setStack({ kind: 'search', q }));
          }}
        />
      </AppPush>
    );
  } else if (stack.kind === 'movie-reviews') {
    push = (
      <AppPush
        title={`评论 · ${stack.title}`}
        scrollKey={`maker-movie-reviews-${stack.movieId}`}
        scrollMode="top"
        onBack={() => setStack(stack.back)}
      >
        <MakerMovieReviewsBody id={stack.movieId} />
      </AppPush>
    );
  }

  return (
    <>
      {hubView}
      {push}
    </>
  );
}

function MakerYearSelect({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  const years = useMakerYears(true);

  return (
    <label className="maker-year-pill">
      <span className="maker-year-pill__text">{value || '年份不限'}</span>
      <ChevronDown size={13} strokeWidth={2.4} aria-hidden="true" />
      <select
        className="maker-year-pill__select"
        aria-label="年份"
        value={value}
        onChange={(event) => onChange(event.target.value)}
      >
        <option value="">年份不限</option>
        {(years.data || []).map((year) => (
          <option key={year} value={year}>
            {year}
          </option>
        ))}
      </select>
    </label>
  );
}

const LATEST_FILTERS: Array<[MakerLatestFilter, string]> = [
  ['all', '全部'],
  ['magnets', '含磁链'],
  ['subtitle', '含字幕'],
];

const LATEST_SORTS: Array<[MakerLatestSort, string]> = [
  ['update', '磁链更新'],
  ['release', '发布日期'],
];

function MakerLatestControls({
  filter,
  sortBy,
  onFilter,
  onSort,
}: {
  filter: MakerLatestFilter;
  sortBy: MakerLatestSort;
  onFilter: (value: MakerLatestFilter) => void;
  onSort: (value: MakerLatestSort) => void;
}) {
  const [open, setOpen] = useState(false);
  const filterLabel = LATEST_FILTERS.find(([v]) => v === filter)?.[1] || '全部';
  const sortLabel = LATEST_SORTS.find(([v]) => v === sortBy)?.[1] || '磁链更新';

  return (
    <div className="maker-latest-ctl">
      <button
        type="button"
        className={
          open ? 'maker-latest-ctl__btn is-open' : 'maker-latest-ctl__btn'
        }
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        <SlidersHorizontal size={15} strokeWidth={2.2} />
        <span>{filter === 'all' ? sortLabel : filterLabel}</span>
      </button>
      {open ? (
        <>
          <div
            className="maker-latest-ctl__mask"
            onClick={() => setOpen(false)}
          />
          <div
            className="maker-latest-ctl__panel"
            role="dialog"
            aria-label="筛选与排序"
          >
            <p className="maker-latest-ctl__cap">内容</p>
            <div className="maker-latest-ctl__row">
              {LATEST_FILTERS.map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  className={
                    filter === value ? 'maker-chip is-active' : 'maker-chip'
                  }
                  onClick={() => {
                    onFilter(value);
                    setOpen(false);
                  }}
                >
                  {label}
                </button>
              ))}
            </div>
            <p className="maker-latest-ctl__cap">排序</p>
            <div className="maker-latest-ctl__row">
              {LATEST_SORTS.map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  className={
                    sortBy === value ? 'maker-chip is-active' : 'maker-chip'
                  }
                  onClick={() => {
                    onSort(value);
                    setOpen(false);
                  }}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>
        </>
      ) : null}
    </div>
  );
}
