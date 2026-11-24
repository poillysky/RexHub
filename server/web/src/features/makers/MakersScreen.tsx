'use client';

import { startTransition, useEffect, useRef, useState } from 'react';
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
import { openHomeSearch } from '@/features/media/mediaUi';
import { useTabNavigation, type TabRoute } from '@/shell';
import { useStackCover } from '@/hooks/useStackCover';
import { makeHref, type HashRoute } from '@/shell/nav/urlNav';
import {
  usePageHistory,
  useTabLocation,
  useTabUrlSync,
} from '@/shell/nav/useTabHistory';
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
  type MakerSearchState,
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
  | { kind: 'search' }
  | { kind: 'maker'; name: string; back?: Stack; page?: number }
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
      page?: number;
    }
  | { kind: 'tags'; category: MakerCategoryId; page?: number }
  | {
      kind: 'browse';
      category: MakerCategoryId;
      group: string;
      tagId: string;
      tagIds?: string[];
      actorId?: string;
      tagName: string;
      back?: Stack;
      page?: number;
    }
  | { kind: 'actors'; category: MakerCategoryId; recommend?: boolean; page?: number }
  | { kind: 'reviews' }
  | {
      kind: 'entity';
      entityKind: MakerEntityKind;
      entityId: string;
      name: string;
      back?: Stack;
      page?: number;
    }
  | { kind: 'actor-detail'; actorId: string; name: string; back?: Stack; page?: number }
  | { kind: 'list-detail'; listId: string; name: string; back?: Stack; page?: number }
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

type HubMode = 'category' | 'playback' | 'recent' | 'tags';

const MAKER_TAB: TabRoute = '/makers';
const MAKER_ROOT_HREF = makeHref(MAKER_TAB);

const CATEGORY_IDS = new Set<string>(CATEGORIES.map((c) => c.id));
const SEARCH_MODES = new Set([
  'movie',
  'maker',
  'actor',
  'list',
  'series',
  'director',
  'code',
  'resource',
]);
const LIST_KINDS = new Set(['rank', 'latest', 'top', 'playback', 'recommend']);
const PERIOD_IDS = new Set(['daily', 'weekly', 'monthly']);
const ENTITY_KINDS = new Set(['maker', 'director', 'series']);

const DEFAULT_SEARCH: MakerSearchState = {
  mode: 'movie',
  q: '',
  movieFilter: 'all',
  moviePage: 1,
  resourcePage: 1,
  exact: false,
};

function positiveInt(value: string | null, fallback = 1): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

function pickCategory(value: string | null): MakerCategoryId {
  return CATEGORY_IDS.has(value || '') ? (value as MakerCategoryId) : '0';
}

function pickHubMode(value: string | null): HubMode {
  return value === 'playback' || value === 'recent' || value === 'tags'
    ? value
    : 'category';
}

/** 当前页面 → 地址栏 */
function makerHref(state: {
  stack: Stack;
  hubMode: HubMode;
  category: MakerCategoryId;
  searchState?: MakerSearchState;
}): string {
  const { stack, hubMode, category, searchState } = state;
  switch (stack.kind) {
    case 'hub':
      return makeHref(MAKER_TAB, [], {
        mode: hubMode === 'category' ? undefined : hubMode,
        cat: category === '0' ? undefined : category,
      });
    case 'search': {
      const st = searchState ?? DEFAULT_SEARCH;
      return makeHref(MAKER_TAB, ['search'], {
        mode: st.mode === 'movie' ? undefined : st.mode,
        q: st.q,
        mf: st.movieFilter === 'all' ? undefined : st.movieFilter,
        mp: st.moviePage > 1 ? st.moviePage : undefined,
        rp: st.resourcePage > 1 ? st.resourcePage : undefined,
        ex: st.exact ? 1 : undefined,
      });
    }
    case 'maker':
      return makeHref(MAKER_TAB, ['maker', stack.name], {
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'list':
      return makeHref(MAKER_TAB, ['list'], {
        list: stack.list,
        cat: stack.category,
        period: stack.period,
        sort: stack.sortBy,
        lf: stack.latestFilter && stack.latestFilter !== 'all' ? stack.latestFilter : undefined,
        fb: stack.filterBy && stack.filterBy !== 'all' ? stack.filterBy : undefined,
        year: stack.year,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'tags':
      return makeHref(MAKER_TAB, ['tags'], {
        cat: stack.category,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'browse':
      return makeHref(MAKER_TAB, ['browse'], {
        cat: stack.category,
        group: stack.group,
        tag: stack.tagId,
        tags: stack.tagIds?.join(','),
        actor: stack.actorId,
        name: stack.tagName,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'actors':
      return makeHref(MAKER_TAB, ['actors'], {
        cat: stack.category,
        rec: stack.recommend ? 1 : undefined,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'reviews':
      return makeHref(MAKER_TAB, ['reviews']);
    case 'entity':
      return makeHref(MAKER_TAB, ['entity'], {
        kind: stack.entityKind,
        id: stack.entityId,
        name: stack.name,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'actor-detail':
      return makeHref(MAKER_TAB, ['actor'], {
        id: stack.actorId,
        name: stack.name,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'list-detail':
      return makeHref(MAKER_TAB, ['list-detail'], {
        id: stack.listId,
        name: stack.name,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'movie':
      return makeHref(MAKER_TAB, ['movie', stack.movie.id], {
        n: stack.movie.number,
        t: stack.movie.title,
        c: stack.movie.coverUrl,
        th: stack.movie.thumbUrl,
        cat: category,
      });
    case 'movie-reviews':
      return makeHref(MAKER_TAB, ['movie-reviews', stack.movieId], {
        title: stack.title,
      });
  }
}

/** 地址栏 → 当前页面（深链 / 刷新 / 前进后退） */
function parseMakerLocation(route: HashRoute): {
  stack: Stack;
  hubMode: HubMode;
  category: MakerCategoryId;
  searchState?: MakerSearchState;
} | null {
  const q = route.query;
  const page = positiveInt(q.get('page'));
  const category = pickCategory(q.get('cat'));
  const head = route.segments[0];
  const rootBack: Stack = { kind: 'hub' };

  switch (head) {
    case undefined:
      return {
        stack: { kind: 'hub' },
        hubMode: pickHubMode(q.get('mode')),
        category,
      };
    case 'search': {
      const mode = q.get('mode') || '';
      const filter = q.get('mf') || '';
      return {
        stack: { kind: 'search' },
        hubMode: 'category',
        category,
        searchState: {
          mode: (SEARCH_MODES.has(mode) ? mode : 'movie') as MakerSearchState['mode'],
          q: q.get('q') || '',
          movieFilter: (
            filter === 'subtitle' || filter === 'magnets' || filter === 'playable'
              ? filter
              : 'all'
          ) as MakerSearchState['movieFilter'],
          moviePage: positiveInt(q.get('mp')),
          resourcePage: positiveInt(q.get('rp')),
          exact: q.get('ex') === '1',
        },
      };
    }
    case 'maker': {
      const name = route.segments[1];
      if (!name) return null;
      return {
        stack: { kind: 'maker', name, page },
        hubMode: 'category',
        category,
      };
    }
    case 'list': {
      const kind = q.get('list') || '';
      if (!LIST_KINDS.has(kind)) return null;
      const period = q.get('period') || '';
      const sort = q.get('sort') || '';
      const latest = q.get('lf') || '';
      const filterBy = q.get('fb') || '';
      return {
        stack: {
          kind: 'list',
          list: kind as MakerListKind,
          category,
          period: PERIOD_IDS.has(period) ? (period as MakerPeriod) : undefined,
          sortBy: sort === 'release' ? 'release' : sort === 'update' ? 'update' : undefined,
          latestFilter:
            latest === 'magnets' || latest === 'subtitle'
              ? (latest as MakerLatestFilter)
              : undefined,
          filterBy:
            filterBy === 'high_score' || filterBy === 'all'
              ? (filterBy as MakerPlaybackFilter)
              : undefined,
          year: q.get('year') || undefined,
          page,
        },
        hubMode: 'category',
        category,
      };
    }
    case 'tags':
      return {
        stack: { kind: 'tags', category, page },
        hubMode: 'tags',
        category,
      };
    case 'browse':
      return {
        stack: {
          kind: 'browse',
          category,
          group: q.get('group') || '',
          tagId: q.get('tag') || '',
          tagIds: q.get('tags')?.split(',').filter(Boolean),
          actorId: q.get('actor') || undefined,
          tagName: q.get('name') || '分类',
          page,
        },
        hubMode: 'category',
        category,
      };
    case 'actors':
      return {
        stack: {
          kind: 'actors',
          category,
          recommend: q.get('rec') === '1',
          page,
        },
        hubMode: 'category',
        category,
      };
    case 'reviews':
      return { stack: { kind: 'reviews' }, hubMode: 'category', category };
    case 'entity': {
      const kind = q.get('kind') || '';
      const id = q.get('id');
      if (!id || !ENTITY_KINDS.has(kind)) return null;
      return {
        stack: {
          kind: 'entity',
          entityKind: kind as MakerEntityKind,
          entityId: id,
          name: q.get('name') || id,
          page,
        },
        hubMode: 'category',
        category,
      };
    }
    case 'actor': {
      const id = q.get('id');
      if (!id) return null;
      return {
        stack: {
          kind: 'actor-detail',
          actorId: id,
          name: q.get('name') || id,
          page,
        },
        hubMode: 'category',
        category,
      };
    }
    case 'list-detail': {
      const id = q.get('id');
      if (!id) return null;
      return {
        stack: {
          kind: 'list-detail',
          listId: id,
          name: q.get('name') || id,
          page,
        },
        hubMode: 'category',
        category,
      };
    }
    case 'movie': {
      const id = route.segments[1];
      if (!id) return null;
      return {
        stack: {
          kind: 'movie',
          movie: {
            id,
            number: q.get('n') || '',
            title: q.get('t') || '',
            coverUrl: q.get('c') || null,
            thumbUrl: q.get('th') || null,
            previewUrl: null,
            releaseDate: null,
            duration: 0,
            magnetsCount: 0,
            hasCnsub: false,
          },
          back: rootBack,
        },
        hubMode: 'category',
        category,
      };
    }
    case 'movie-reviews': {
      const id = route.segments[1];
      if (!id) return null;
      return {
        stack: {
          kind: 'movie-reviews',
          movieId: id,
          title: q.get('title') || '',
          back: rootBack,
        },
        hubMode: 'category',
        category,
      };
    }
    default:
      return null;
  }
}

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
  const latest = useMakerLatest(category, 1, 'update', 'all', kind === 'latest');
  const top = useMakerTop(category, 1, '', kind === 'top');
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
  const activeTab = tabCtx?.activeTab;
  const tabReselect = tabCtx?.tabReselect ?? 0;
  const [stack, setStack] = useState<Stack>({ kind: 'hub' });
  /** 搜索页条件（关键词 / tab / 筛选 / 页码），返回时原样恢复 */
  const [searchState, setSearchState] = useState<MakerSearchState | undefined>();
  const [category, setCategory] = useState<MakerCategoryId>('0');
  /** 顶部 tab：热播 / 类别 / 最近浏览，同层切换内容，不推入新页面 */
  const [hubMode, setHubMode] = useState<HubMode>('category');
  const hubCover = useStackCover(
    stack.kind !== 'hub',
    'maker-hub',
    'app-hub media-hub-root',
  );
  const hubScrollRef = useRef<HTMLDivElement | null>(null);

  /** 系统返回 / 页内返回都回到浏览器历史里的上一页 */
  const nav = usePageHistory(MAKER_TAB, MAKER_ROOT_HREF, () => {
    setSearchState(undefined);
    setStack({ kind: 'hub' });
  });

  // 地址栏是唯一真相：深链、刷新、前进后退都从这里还原
  useTabLocation(MAKER_TAB, (route) => {
    const next = parseMakerLocation(route);
    if (!next) return;
    setStack(next.stack);
    setHubMode(next.hubMode);
    setCategory(next.category);
    setSearchState(next.searchState);
  });
  useTabUrlSync(
    MAKER_TAB,
    makerHref({ stack, hubMode, category, searchState }),
  );

  /** 进下一页：先压历史，再切页面 */
  const pushPage = (next: Stack) => {
    nav.push(makerHref({ stack: next, hubMode, category, searchState }));
    startTransition(() => setStack(next));
  };

  // 同层切换 tab / 类别后回到顶部，避免沿用上一个列表的滚动位置
  useEffect(() => {
    hubScrollRef.current?.scrollTo({ top: 0 });
  }, [hubMode, category]);

  useEffect(() => {
    if (activeTab !== '/makers' || tabReselect === 0) return;
    startTransition(() => {
      setSearchState(undefined);
      setStack({ kind: 'hub' });
    });
  }, [activeTab, tabReselect]);

  const openMaker = (hit: MakerHit, back?: Stack) =>
    pushPage({ kind: 'maker', name: hit.name, back });

  const openMovie = (movie: MakerMovie, back: Stack) =>
    pushPage({ kind: 'movie', movie, back });

  const openActor = (actor: { id: string; name: string }, back?: Stack) =>
    pushPage({
      kind: 'browse',
      category,
      group: '',
      tagId: '',
      actorId: actor.id,
      tagName: `演员 · ${actor.name}`,
      back,
    });

  /** 演员详情页（资料 + 全部作品） */
  const openActorDetail = (actor: { id: string; name: string }, back?: Stack) =>
    pushPage({ kind: 'actor-detail', actorId: actor.id, name: actor.name, back });

  /** 片商 / 导演 / 系列 详情页 */
  const openEntity = (
    entityKind: MakerEntityKind,
    id: string,
    name: string,
    back?: Stack,
  ) => pushPage({ kind: 'entity', entityKind, entityId: id, name, back });

  /** 片单详情页 */
  const openList = (list: { id: string; name: string }, back?: Stack) =>
    pushPage({ kind: 'list-detail', listId: list.id, name: list.name, back });

  /** 列表页翻页：记进当前页面栈，从影片详情返回时按原页码恢复 */
  const setCurrentPage = (page: number) =>
    setStack((prev) => {
      switch (prev.kind) {
        case 'maker':
        case 'list':
        case 'tags':
        case 'browse':
        case 'actors':
        case 'entity':
        case 'actor-detail':
        case 'list-detail':
          return { ...prev, page };
        default:
          return prev;
      }
    });

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
                pushPage({ kind: 'actors', category, recommend: true })
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
              onClick={() => pushPage({ kind: 'search' })}
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

      <div className="app-hub__scroll media-hub" ref={hubScrollRef}>
        <div className="media-hub__shelves">
          {hubMode === 'playback' ? (
            PLAYBACK_PERIODS.map((p) => (
              <PlaybackShelf
                key={p.id}
                label={`热播·${p.label}`}
                period={p.id}
                filterBy="all"
                onOpenAll={() =>
                  pushPage({
                    kind: 'list',
                    list: 'playback',
                    category,
                    period: p.id,
                    filterBy: 'all',
                  })
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
                    pushPage({
                      kind: 'list',
                      list: 'rank',
                      category,
                      period: p.id,
                    })
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
              pushPage({ kind: 'list', list: 'latest', category })
            }
            onOpenMovie={(movie) => openMovie(movie, { kind: 'hub' })}
          />
          {rankSupported ? (
            <ListShelf
              category={category}
              kind="top"
              label={`TOP250·${catLabel}`}
              onOpenAll={() =>
                pushPage({ kind: 'list', list: 'top', category })
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
        key="maker-search"
        title="搜索"
        scrollKey="maker-search"
        onBack={() => nav.back()}
      >
        <MakerSearchBody
          initialState={searchState}
          onStateChange={setSearchState}
          onOpenMaker={(hit) => openMaker(hit, { kind: 'search' })}
          onOpenMovie={(movie) => openMovie(movie, stack)}
          onOpenActor={(actor) => openActorDetail(actor, stack)}
          onOpenEntity={(kind, id, name) => openEntity(kind, id, name, stack)}
          onOpenList={(list) => openList(list, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'maker') {
    push = (
      <AppPush
        key={`maker-${stack.name}`}
        title={stack.name}
        scrollKey={`maker-${stack.name}`}
        onBack={() => nav.back()}
      >
        <MakerMoviesBody
          key={stack.name}
          name={stack.name}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'list') {
    const listCatLabel =
      CATEGORIES.find((c) => c.id === stack.category)?.label || '';
    const title =
      stack.list === 'rank'
        ? `${PERIODS.find((p) => p.id === stack.period)?.label || ''}·${listCatLabel}`
        : stack.list === 'latest'
          ? `最新·${listCatLabel}`
          : stack.list === 'playback'
            ? `${stack.filterBy === 'high_score' ? '热门' : '热播'}·${PLAYBACK_PERIODS.find((p) => p.id === stack.period)?.label || '今日'}`
            : stack.list === 'recommend'
              ? '编辑推荐'
              : stack.year
                ? `TOP250·${stack.year}`
                : `TOP250·${listCatLabel}`;
    push = (
      <AppPush
        key={`maker-list-${stack.list}-${stack.category}-${stack.period || ''}-${stack.sortBy || ''}-${stack.latestFilter || ''}-${stack.filterBy || ''}-${stack.year || ''}`}
        title={title}
        scrollKey={`maker-list-${stack.list}-${stack.category}-${stack.period || ''}-${stack.sortBy || ''}-${stack.latestFilter || ''}-${stack.filterBy || ''}-${stack.year || ''}`}
        onBack={() => nav.back()}
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
                        prev.kind === 'list'
                          ? { ...prev, filterBy: value, page: 1 }
                          : prev,
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
                      ? { ...prev, year: value || undefined, page: 1 }
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
                      ? { ...prev, latestFilter: value, page: 1 }
                      : prev,
                  ),
                )
              }
              onSort={(value) =>
                startTransition(() =>
                  setStack((prev) =>
                    prev.kind === 'list' ? { ...prev, sortBy: value, page: 1 } : prev,
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
          latestFilter={stack.latestFilter}
          playbackFilter={stack.filterBy}
          year={stack.year}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'tags') {
    push = (
      <AppPush
        key={`maker-tags-${stack.category}`}
        title={`分类·${catLabel}`}
        scrollKey={`maker-tags-${stack.category}`}
        onBack={() => nav.back()}
      >
        <MakerTagsBody
          category={stack.category}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onSelectCategory={(next) =>
            startTransition(() =>
              setStack((prev) =>
                prev.kind === 'tags'
                  ? { ...prev, category: next, page: undefined }
                  : prev,
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
        key={`maker-actors-${recommend ? 'recommend' : stack.category}`}
        title={recommend ? '演员·推荐' : `演员·${label}`}
        scrollKey={`maker-actors-${recommend ? 'recommend' : stack.category}`}
        onBack={() => nav.back()}
      >
        <MakerActorsHubBody
          category={stack.category}
          recommend={recommend}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onSelectTab={(next) =>
            startTransition(() =>
              setStack({ kind: 'actors', ...next }),
            )
          }
          onOpenActor={(actor) => openActorDetail(actor, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'reviews') {
    push = (
      <AppPush
        key="maker-hot-reviews"
        title="热评"
        scrollKey="maker-hot-reviews"
        onBack={() => nav.back()}
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
        key={`maker-browse-${stack.category}-${stack.group}-${stack.tagId}-${stack.actorId || ''}-${(stack.tagIds || []).join(',')}`}
        title={stack.tagName}
        scrollKey={`maker-browse-${stack.category}-${stack.group}-${stack.tagId}-${stack.actorId || ''}-${(stack.tagIds || []).join(',')}`}
        onBack={() => nav.back()}
      >
        <MakerBrowseBody
          category={stack.category}
          group={stack.group}
          tagId={stack.tagId}
          tagIds={stack.tagIds}
          actorId={stack.actorId}
          tagName={stack.tagName}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'entity') {
    push = (
      <AppPush
        key={`maker-entity-${stack.entityKind}-${stack.entityId}`}
        title={stack.name}
        scrollKey={`maker-entity-${stack.entityKind}-${stack.entityId}`}
        onBack={() => nav.back()}
      >
        <MakerEntityBody
          kind={stack.entityKind}
          id={stack.entityId}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'actor-detail') {
    push = (
      <AppPush
        key={`maker-actor-${stack.actorId}`}
        title={stack.name}
        scrollKey={`maker-actor-${stack.actorId}`}
        onBack={() => nav.back()}
      >
        <MakerActorDetailBody
          id={stack.actorId}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'list-detail') {
    push = (
      <AppPush
        key={`maker-list-${stack.listId}`}
        title={stack.name}
        scrollKey={`maker-list-${stack.listId}`}
        onBack={() => nav.back()}
      >
        <MakerListDetailBody
          id={stack.listId}
          initialPage={stack.page}
          onPageChange={setCurrentPage}
          onOpenMovie={(movie) => openMovie(movie, stack)}
        />
      </AppPush>
    );
  } else if (stack.kind === 'movie') {
    const { movie } = stack;
    push = (
      <AppPush
        key={`maker-movie-${movie.id || movie.number}`}
        title={movie.number || movie.title}
        scrollKey={`maker-movie-${movie.id || movie.number}`}
        scrollMode="top"
        onBack={() => nav.back()}
      >
        <MakerMovieBody
          id={movie.id}
          seed={movie}
          onOpenActor={(actor) => openActor(actor, stack)}
          onOpenEntity={(kind, id, name) => openEntity(kind, id, name, stack)}
          onOpenList={(list) => openList(list, stack)}
          onOpenMovie={(m) => openMovie(m, stack)}
          onOpenReviews={() =>
            pushPage({
              kind: 'movie-reviews',
              movieId: movie.id,
              title: movie.number || movie.title || '',
              back: stack,
            })
          }
          onOpenSearch={(q) => {
            // 详情页「搜索」走底栏「搜索」的片商通道；片商模块内的 AVDB 搜索只保留顶栏放大镜
            openHomeSearch(q, (tab) => tabCtx?.scrollToTab(tab), {
              source: 'sehua',
              p115Source: 'maker',
            });
          }}
        />
      </AppPush>
    );
  } else if (stack.kind === 'movie-reviews') {
    push = (
      <AppPush
        key={`maker-movie-reviews-${stack.movieId}`}
        title={`评论 · ${stack.title}`}
        scrollKey={`maker-movie-reviews-${stack.movieId}`}
        scrollMode="top"
        onBack={() => nav.back()}
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
