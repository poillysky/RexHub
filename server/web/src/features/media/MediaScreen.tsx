'use client';

import { startTransition, useEffect, useState } from 'react';
import { Search } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import {
  fetchMpDetail,
  proxiedCoverUrl,
  type MediaCastPerson,
  type MediaCategoryId,
  type MediaItem,
  type MediaSourceId,
} from '@/lib/api';
import { AppPush } from '@/components/ui/AppPush';
import { AppMsg } from '@/components/ui/AppMsg';
import { useTabNavigation, type TabRoute } from '@/shell';
import { useOverlay } from '@/components/overlay/OverlayContext';
import { useStackCover } from '@/hooks/useStackCover';
import { makeHref, type HashRoute } from '@/shell/nav/urlNav';
import {
  usePageHistory,
  useTabLocation,
  useTabUrlSync,
} from '@/shell/nav/useTabHistory';
import { MediaChartBody } from './MediaChartBody';
import { MediaDetailBody } from './MediaDetailBody';
import { MediaExploreBody } from './MediaExploreBody';
import { MediaPersonBody } from './MediaPersonBody';
import { MediaPtSearchBody } from './MediaPtSearchBody';
import { MediaSearchBody } from './MediaSearchBody';
import { MediaShelf } from './MediaShelf';
import {
  chartItemCategory,
  hubShelvesFor,
  hubTabLabel,
  type MediaHubTab,
} from './mediaUi';
import { mediaKeys } from './useMediaQueries';

/** 内容维度对齐 MoviePilot 推荐页分类，另加探索入口 */
type HubTab = MediaHubTab | 'explore';

type DetailFrom = 'hub' | 'chart' | 'search' | 'person' | 'explore';

type DetailBack = {
  category: MediaCategoryId;
  item: MediaItem;
  detail: MediaItem | null;
  from: Exclude<DetailFrom, 'person'>;
  chart?: string;
  chartTab?: MediaHubTab;
  /** 来源榜单页码 */
  chartPage?: number;
  /** 来源搜索关键词与页码 */
  searchQ?: string;
  searchPage?: number;
};

type Stack =
  | { kind: 'hub' }
  | { kind: 'search'; q?: string; page?: number }
  | { kind: 'chart'; tab: MediaHubTab; chart?: string; page?: number }
  | {
      kind: 'detail';
      category: MediaCategoryId;
      item: MediaItem;
      detail: MediaItem | null;
      from: DetailFrom;
      chart?: string;
      chartTab?: MediaHubTab;
      chartPage?: number;
      searchQ?: string;
      searchPage?: number;
      /** 从影人作品页点进详情时，返回用 */
      person?: MediaCastPerson;
      /** 影人所属数据源（作品可能跨源，返回影人页要还原） */
      personSource?: MediaSourceId;
      detailBack?: DetailBack;
      /** 详情页内打开 PT 站点搜索 */
      ptOpen?: boolean;
      /** 进入 PT 搜索前弹窗选定的搜索方式 */
      ptMode?: 'title' | 'imdbid';
    }
  | {
      kind: 'person';
      person: MediaCastPerson;
      /** 影人接口随详情源走：TMDB / 豆瓣 各自前缀不同 */
      source: MediaSourceId;
      detailBack: DetailBack;
    };

const MEDIA_TAB: TabRoute = '/media';
const MEDIA_ROOT_HREF = makeHref(MEDIA_TAB);
const MEDIA_SOURCES = new Set(['tmdb', 'douban', 'bangumi', 'anilist']);
const DETAIL_FROM = new Set(['hub', 'chart', 'search', 'person', 'explore']);
const HUB_TABS = new Set(['movie', 'tv', 'anime', 'rank', 'explore']);

function pickSource(value: string | null): MediaSourceId {
  return MEDIA_SOURCES.has(value || '')
    ? (value as MediaSourceId)
    : 'tmdb';
}

function positiveInt(value: string | null, fallback = 1): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

/** 当前页面 → 地址栏 */
function mediaHref(state: { stack: Stack; hubTab: HubTab }): string {
  const { stack, hubTab } = state;
  switch (stack.kind) {
    case 'hub':
      return makeHref(MEDIA_TAB, [], {
        tab: hubTab === 'movie' ? undefined : hubTab,
      });
    case 'search':
      return makeHref(MEDIA_TAB, ['search'], {
        q: stack.q,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'chart':
      return makeHref(MEDIA_TAB, ['chart'], {
        tab: stack.tab,
        chart: stack.chart,
        page: stack.page && stack.page > 1 ? stack.page : undefined,
      });
    case 'detail':
      return makeHref(MEDIA_TAB, ['detail'], {
        src: stack.item.source,
        id: stack.item.id,
        mt: stack.item.mediaType,
        cat: stack.category,
        from: stack.from,
        t: stack.item.title,
        p: stack.item.posterUrl,
        chart: stack.chart,
        ctab: stack.chartTab,
        cpage: stack.chartPage && stack.chartPage > 1 ? stack.chartPage : undefined,
        q: stack.searchQ,
        spage: stack.searchPage && stack.searchPage > 1 ? stack.searchPage : undefined,
        psrc: stack.personSource,
        ppid: stack.person?.id,
        pname: stack.person?.name,
        pav: stack.person?.avatarUrl,
        pt: stack.ptOpen ? 1 : undefined,
        ptm: stack.ptOpen ? stack.ptMode : undefined,
      });
    case 'person':
      return makeHref(MEDIA_TAB, ['person'], {
        src: stack.source,
        id: stack.person.id,
        name: stack.person.name,
        avatar: stack.person.avatarUrl,
      });
  }
}

/** 地址栏 → 当前页面（深链 / 刷新 / 前进后退） */
function parseMediaLocation(route: HashRoute): {
  stack: Stack;
  hubTab: HubTab;
} | null {
  const q = route.query;
  const head = route.segments[0];
  const tab = q.get('tab') || '';
  const hubTab = (HUB_TABS.has(tab) ? tab : 'movie') as HubTab;

  switch (head) {
    case undefined:
      return { stack: { kind: 'hub' }, hubTab };
    case 'search':
      return {
        stack: {
          kind: 'search',
          q: q.get('q') || undefined,
          page: positiveInt(q.get('page')),
        },
        hubTab: 'movie',
      };
    case 'chart': {
      const chartTab = (HUB_TABS.has(tab) ? tab : 'movie') as HubTab;
      return {
        stack: {
          kind: 'chart',
          tab: chartTab === 'explore' ? 'movie' : chartTab,
          chart: q.get('chart') || undefined,
          page: positiveInt(q.get('page')),
        },
        hubTab: 'movie',
      };
    }
    case 'detail': {
      const id = q.get('id');
      if (!id) return null;
      const source = pickSource(q.get('src'));
      const mediaType = q.get('mt') === 'tv' ? 'tv' : 'movie';
      const cat = q.get('cat') || '';
      const from = q.get('from') || '';
      const pid = q.get('ppid') || undefined;
      const pname = q.get('pname') || '';
      return {
        stack: {
          kind: 'detail',
          category: (cat || mediaType) as MediaCategoryId,
          item: {
            source,
            id,
            mediaType,
            title: q.get('t') || id,
            posterUrl: q.get('p') || null,
            aka: [],
          },
          detail: null,
          from: (DETAIL_FROM.has(from) ? from : 'hub') as DetailFrom,
          chart: q.get('chart') || undefined,
          chartTab: (() => {
            const ctab = q.get('ctab') || '';
            return HUB_TABS.has(ctab) && ctab !== 'explore'
              ? (ctab as MediaHubTab)
              : undefined;
          })(),
          chartPage: q.get('cpage') ? positiveInt(q.get('cpage')) : undefined,
          searchQ: q.get('q') || undefined,
          searchPage: q.get('spage') ? positiveInt(q.get('spage')) : undefined,
          personSource: q.get('psrc') ? pickSource(q.get('psrc')) : undefined,
          person: pid || pname ? { id: pid, name: pname || '' } : undefined,
          ptOpen: q.get('pt') === '1',
          ptMode: q.get('ptm') === 'imdbid' ? 'imdbid' : 'title',
        },
        hubTab: 'movie',
      };
    }
    case 'person': {
      const id = q.get('id');
      if (!id) return null;
      const source = pickSource(q.get('src'));
      const name = q.get('name') || id;
      return {
        stack: {
          kind: 'person',
          person: { id, name, avatarUrl: q.get('avatar') || null },
          source,
          detailBack: {
            category: 'movie',
            item: {
              source,
              id,
              mediaType: 'movie',
              title: name,
              aka: [],
            },
            detail: null,
            from: 'hub',
          },
        },
        hubTab: 'movie',
      };
    }
    default:
      return null;
  }
}

export function MediaScreen() {
  const tabCtx = useTabNavigation();
  const { toast } = useOverlay();
  const activeTab = tabCtx?.activeTab;
  const tabReselect = tabCtx?.tabReselect ?? 0;
  const queryClient = useQueryClient();
  const [stack, setStack] = useState<Stack>({ kind: 'hub' });
  const [hubTab, setHubTab] = useState<HubTab>('movie');
  const [hubNotice, setHubNotice] = useState('');
  const [msg, setMsg] = useState('');
  const [loadingDetail, setLoadingDetail] = useState(false);
  const hubCover = useStackCover(
    stack.kind !== 'hub',
    'media-hub',
    'app-hub media-hub-root',
  );

  const nav = usePageHistory(MEDIA_TAB, MEDIA_ROOT_HREF, () => {
    setStack({ kind: 'hub' });
  });

  useTabLocation(MEDIA_TAB, (route) => {
    const next = parseMediaLocation(route);
    if (!next) return;
    setStack(next.stack);
    setHubTab(next.hubTab);
  });
  useTabUrlSync(MEDIA_TAB, mediaHref({ stack, hubTab }));

  /** 进下一页：压历史后切页面 */
  const pushPage = (next: Stack) => {
    nav.push(mediaHref({ stack: next, hubTab }));
    startTransition(() => setStack(next));
  };

  // 深链 / 刷新直接落在详情时，按 id 补齐详情数据
  useEffect(() => {
    if (stack.kind !== 'detail' || stack.detail) return;
    const { item } = stack;
    let cancelled = false;
    queryClient
      .fetchQuery({
        queryKey: mediaKeys.detail(item.source, item.id, item.mediaType),
        queryFn: ({ signal }) =>
          fetchMpDetail({
            source: item.source,
            id: item.id,
            mediaType: item.mediaType,
            signal,
          }),
        staleTime: 5 * 60 * 1000,
      })
      .then((detail) => {
        if (cancelled) return;
        setStack((prev) =>
          prev.kind === 'detail' && prev.item.id === item.id
            ? { ...prev, detail }
            : prev,
        );
      })
      .catch((error) => {
        if (cancelled) return;
        const text = error instanceof Error ? error.message : '详情加载失败';
        setMsg(text);
        toast(text, 'error');
        setStack((prev) =>
          prev.kind === 'detail' && prev.item.id === item.id
            ? { ...prev, detail: item }
            : prev,
        );
      })
      .finally(() => {
        if (!cancelled) setLoadingDetail(false);
      });
    return () => {
      cancelled = true;
    };
  }, [stack, queryClient, toast]);

  // 切换分类后回到内容顶部，避免停在上一个分类的滚动位置
  useEffect(() => {
    hubCover.ref.current
      ?.querySelector('.app-hub__scroll')
      ?.scrollTo({ top: 0 });
  }, [hubTab, hubCover.ref]);

  const exploring = hubTab === 'explore';
  const hubCategory: MediaHubTab = exploring ? 'movie' : hubTab;
  // 搜索页默认数据源；影人页则跟随详情源
  const source: MediaSourceId = 'tmdb';

  useEffect(() => {
    if (activeTab !== '/media' || tabReselect === 0) return;
    startTransition(() => setStack({ kind: 'hub' }));
  }, [activeTab, tabReselect]);

  const openDetail = (
    category: MediaCategoryId,
    item: MediaItem,
    from: DetailFrom,
    opts?: {
      chart?: string;
      chartTab?: MediaHubTab;
      chartPage?: number;
      searchQ?: string;
      searchPage?: number;
      person?: MediaCastPerson;
      personSource?: MediaSourceId;
      detailBack?: DetailBack;
    },
  ) => {
    const cover = proxiedCoverUrl(item.posterUrl);
    if (cover && typeof window !== 'undefined') {
      const warm = new window.Image();
      warm.decoding = 'async';
      warm.src = cover;
    }
    setLoadingDetail(true);
    setMsg('');
    pushPage({
      kind: 'detail',
      category,
      item,
      detail: null,
      from,
      chart: opts?.chart,
      chartTab: opts?.chartTab,
      chartPage: opts?.chartPage,
      searchQ: opts?.searchQ,
      searchPage: opts?.searchPage,
      person: opts?.person,
      personSource: opts?.personSource,
      detailBack: opts?.detailBack,
    });
  };

  const shelves = hubShelvesFor(hubCategory);

  const hub = (
    <div {...hubCover}>
      <div className="media-hub__top">
        <div className="media-hub__top-row">
          <h1 className="app-hub__title">影视</h1>
          <button
            type="button"
            className="media-hub__search-btn"
            aria-label="搜索影视"
            onClick={() => pushPage({ kind: 'search' })}
          >
            <Search size={17} strokeWidth={2.4} aria-hidden />
          </button>
        </div>
        <div
          className="media-source-switch"
          role="tablist"
          aria-label="影视分类"
        >
          {(
            [
              { id: 'movie', label: '电影' },
              { id: 'tv', label: '电视剧' },
              { id: 'anime', label: '动漫' },
              { id: 'rank', label: '榜单' },
              { id: 'explore', label: '探索' },
            ] as const
          ).map((s) => (
            <button
              key={s.id}
              type="button"
              role="tab"
              aria-selected={hubTab === s.id}
              className={
                hubTab === s.id
                  ? 'media-source-switch__btn is-active'
                  : 'media-source-switch__btn'
              }
              onClick={() => {
                setHubNotice('');
                setHubTab(s.id);
              }}
            >
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <div className="app-hub__scroll media-hub">
        {exploring ? (
          <MediaExploreBody
            onOpen={(category, item) =>
              void openDetail(category, item, 'explore')
            }
          />
        ) : (
          <div className="media-hub__shelves">
            {hubNotice ? (
              <p className="media-hub__notice allow-select" role="status">
                {hubNotice}
              </p>
            ) : null}
            {shelves.map((s) => (
              <MediaShelf
                key={`${hubCategory}-${s.key}`}
                category={s.category}
                path={s.path}
                params={s.params}
                title={s.title}
                onOpenAll={() =>
                  pushPage({
                    kind: 'chart',
                    tab: hubCategory,
                    chart: s.key,
                  })
                }
                onOpenItem={(item) =>
                  void openDetail(
                    s.category || (item.mediaType === 'tv' ? 'tv' : 'movie'),
                    item,
                    'hub',
                    { chart: s.key, chartTab: hubCategory },
                  )
                }
                onLoadError={(message) => {
                  if (!message) return;
                  setHubNotice((prev) => prev || message);
                }}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );

  let push = null;

  if (stack.kind === 'search') {
    push = (
      <AppPush
        key={`media-search-${source}`}
        title="搜索影视"
        scrollKey={`media-search-${source}`}
        onBack={() => nav.back()}
      >
        <MediaSearchBody
          source={source}
          initialQuery={stack.q}
          initialPage={stack.page}
          onStateChange={({ q, page }) =>
            setStack({ kind: 'search', q, page })
          }
          onOpen={(item) =>
            void openDetail(
              item.mediaType === 'tv' ? 'tv' : 'movie',
              item,
              'search',
              {
                searchQ: stack.q,
                searchPage: stack.page,
              },
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'chart') {
    // 页内不再有榜单切换，标题直接显示当前榜单名
    const chartTitle =
      hubShelvesFor(stack.tab).find((s) => s.key === stack.chart)?.title ||
      hubTabLabel(stack.tab);
    push = (
      <AppPush
        key={`media-chart-${stack.tab}-${stack.chart || ''}`}
        title={chartTitle}
        scrollKey={`media-chart-${stack.tab}-${stack.chart || ''}`}
        onBack={() => nav.back()}
      >
        <MediaChartBody
          key={`${stack.tab}-${stack.chart || ''}`}
          tab={stack.tab}
          initialChart={stack.chart}
          initialPage={stack.page}
          onPageChange={(page) =>
            setStack({
              kind: 'chart',
              tab: stack.tab,
              chart: stack.chart,
              page,
            })
          }
          onOpen={(item) =>
            void openDetail(
              chartItemCategory(stack.tab, item),
              item,
              'chart',
              {
                chart: stack.chart,
                chartTab: stack.tab,
                chartPage: stack.page,
              },
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'person') {
    push = (
      <AppPush
        key={`media-person-${stack.source}-${stack.person.id}`}
        title={stack.person.name}
        scrollKey={`media-person-${stack.source}-${stack.person.id}`}
        onBack={() => nav.back()}
      >
        <MediaPersonBody
          key={`${stack.source}-${stack.person.id}`}
          source={stack.source}
          person={stack.person}
          onOpen={(item) =>
            void openDetail(
              item.mediaType === 'tv' ? 'tv' : 'movie',
              item,
              'person',
              {
                person: stack.person,
                personSource: stack.source,
                detailBack: stack.detailBack,
              },
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'detail') {
    const show = stack.detail || stack.item;
    push = stack.ptOpen ? (
      <AppPush
        key={`media-pt-${show.source}-${show.id}`}
        title={`PT搜索 · ${stack.ptMode === 'imdbid' ? 'IMDb' : '标题'}`}
        scrollKey={`media-pt-${show.source}-${show.id}`}
        onBack={() => nav.back()}
      >
        <MediaPtSearchBody item={show} mode={stack.ptMode || 'title'} />
      </AppPush>
    ) : (
      <AppPush
        key={`media-detail-${show.source}-${show.id}`}
        title={show.title}
        scrollKey={`media-detail-${show.source}-${show.id}`}
        scrollMode="top"
        onBack={() => nav.back()}
      >
        <MediaDetailBody
          key={`${show.source}-${show.id}`}
          item={show}
          enriching={loadingDetail && !stack.detail}
          onPtSearch={(mode) =>
            pushPage({ ...stack, ptOpen: true, ptMode: mode })
          }
          onOpenRelated={(next) =>
            void openDetail(
              next.mediaType === 'tv' ? 'tv' : stack.category,
              next,
              stack.from === 'person' ? 'person' : stack.from,
              {
                chart: stack.chart,
                chartTab: stack.chartTab,
                chartPage: stack.chartPage,
                searchQ: stack.searchQ,
                searchPage: stack.searchPage,
                person: stack.person,
                personSource: stack.personSource,
                detailBack: stack.detailBack,
              },
            )
          }
          onOpenPerson={
            // 影人页跟随详情源：MP 的 TMDB / 豆瓣影人接口各自可用
            (person) => {
              if (!person.id) return;
              const from =
                stack.from === 'person'
                  ? stack.detailBack?.from || 'hub'
                  : stack.from;
              const personSource = show.source;
              pushPage({
                kind: 'person',
                person,
                source: personSource,
                detailBack: {
                  category: stack.category,
                  item: stack.item,
                  detail: stack.detail,
                  from,
                  chart: stack.chart,
                  chartTab: stack.chartTab,
                  chartPage: stack.chartPage,
                  searchQ: stack.searchQ,
                  searchPage: stack.searchPage,
                },
              });
            }
          }
        />
        <AppMsg allowSelect onDismiss={() => setMsg('')}>
          {msg}
        </AppMsg>
      </AppPush>
    );
  }

  return (
    <div className="app-stack-root media-stack">
      {hub}
      {push}
    </div>
  );
}
