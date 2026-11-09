'use client';

import { startTransition, useCallback, useEffect, useRef, useState } from 'react';
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
import { useTabNavigation } from '@/shell';
import { useOverlay } from '@/components/overlay/OverlayContext';
import { useStackCover } from '@/hooks/useStackCover';
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
  const detailReqId = useRef(0);
  const hubCover = useStackCover(
    stack.kind !== 'hub',
    'media-hub',
    'app-hub media-hub-root',
  );

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

  const openDetail = useCallback(
    async (
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
      const reqId = ++detailReqId.current;
      setLoadingDetail(true);
      setMsg('');
      const base = {
        kind: 'detail' as const,
        category,
        item,
        from,
        chart: opts?.chart,
        chartTab: opts?.chartTab,
        chartPage: opts?.chartPage,
        searchQ: opts?.searchQ,
        searchPage: opts?.searchPage,
        person: opts?.person,
        personSource: opts?.personSource,
        detailBack: opts?.detailBack,
      };
      startTransition(() => {
        if (reqId !== detailReqId.current) return;
        setStack({ ...base, detail: null });
      });
      const cover = proxiedCoverUrl(item.posterUrl);
      if (cover && typeof window !== 'undefined') {
        const warm = new window.Image();
        warm.decoding = 'async';
        warm.src = cover;
      }
      try {
        const detail = await queryClient.fetchQuery({
          queryKey: mediaKeys.detail(item.source, item.id, item.mediaType),
          queryFn: ({ signal }) =>
            fetchMpDetail({
              source: item.source,
              id: item.id,
              mediaType: item.mediaType,
              signal,
            }),
          staleTime: 5 * 60 * 1000,
        });
        if (reqId !== detailReqId.current) return;
        setStack({ ...base, detail });
      } catch (e) {
        if (reqId !== detailReqId.current) return;
        const text = e instanceof Error ? e.message : '详情加载失败';
        setMsg(text);
        toast(text, 'error');
        setStack({ ...base, detail: item });
      } finally {
        if (reqId === detailReqId.current) setLoadingDetail(false);
      }
    },
    [toast, queryClient],
  );

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
            onClick={() => startTransition(() => setStack({ kind: 'search' }))}
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
                  startTransition(() =>
                    setStack({
                      kind: 'chart',
                      tab: hubCategory,
                      chart: s.key,
                    }),
                  )
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
        title="搜索影视"
        scrollKey={`media-search-${source}`}
        onBack={() => setStack({ kind: 'hub' })}
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
        title={chartTitle}
        scrollKey={`media-chart-${stack.tab}-${stack.chart || ''}`}
        onBack={() => setStack({ kind: 'hub' })}
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
        title={stack.person.name}
        scrollKey={`media-person-${stack.source}-${stack.person.id}`}
        onBack={() =>
          setStack({
            kind: 'detail',
            ...stack.detailBack,
          })
        }
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
    const onBack = () => {
      if (stack.from === 'person' && stack.person && stack.detailBack) {
        setStack({
          kind: 'person',
          person: stack.person,
          source: stack.personSource || 'tmdb',
          detailBack: stack.detailBack,
        });
        return;
      }
      if (stack.from === 'search') {
        setStack({ kind: 'search', q: stack.searchQ, page: stack.searchPage });
      } else if (stack.from === 'chart') {
        setStack({
          kind: 'chart',
          tab: stack.chartTab || 'movie',
          chart: stack.chart,
          page: stack.chartPage,
        });
      } else setStack({ kind: 'hub' });
    };
    push = stack.ptOpen ? (
      <AppPush
        title={`PT搜索 · ${stack.ptMode === 'imdbid' ? 'IMDb' : '标题'}`}
        scrollKey={`media-pt-${show.source}-${show.id}`}
        onBack={() => setStack({ ...stack, ptOpen: false })}
      >
        <MediaPtSearchBody item={show} mode={stack.ptMode || 'title'} />
      </AppPush>
    ) : (
      <AppPush
        title={show.title}
        scrollKey={`media-detail-${show.source}-${show.id}`}
        scrollMode="top"
        onBack={onBack}
      >
        <MediaDetailBody
          key={`${show.source}-${show.id}`}
          item={show}
          enriching={loadingDetail && !stack.detail}
          onPtSearch={(mode) =>
            setStack({ ...stack, ptOpen: true, ptMode: mode })
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
              startTransition(() =>
                setStack({
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
                }),
              );
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
