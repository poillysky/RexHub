'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import {
  DEFAULT_MATCH_MODE,
  DEFAULT_SORT_TYPE,
  SEARCH_KEYWORD_LENGTH_MIN,
  BROWSE_LATEST_MAX,
  BROWSE_LATEST_PAGE_SIZE,
  SCOPE_PAGE_SIZE,
  normalizeFilterSize,
  normalizeFilterTime,
  normalizeMatchMode,
  normalizeSortType,
} from '@/config/search';
import {
  fetchBrowse,
  fetchScopeSearch,
  type ScopeSearchItem,
  type ScopeSearchSource,
} from '@/lib/api';
import type {
  FilterSize,
  FilterTime,
  MatchMode,
  ResourceItem,
  SortType,
} from '@/types/resource';
import type { FeedSource } from '@/lib/mixedSearch';
import { useTabNavigation } from '@/shell';
import { useStackCover } from '@/hooks/useStackCover';
import { clearSaveSource } from '@/lib/p115Source';
import {
  usePullToRefresh,
  finishPullToRefresh,
} from '@/hooks/usePullToRefresh';
import type { SearchScope } from './SourceSwitch';
import { syncDetailUrl, syncSearchUrl, type HomeMode } from './urlSync';

export type HomeScreenState = ReturnType<typeof useHomeScreen>;

export function useHomeScreen() {
  const tabCtx = useTabNavigation();
  const [mode, setMode] = useState<HomeMode>('landing');
  const [draft, setDraft] = useState('');
  const [keyword, setKeyword] = useState('');
  const [browsing, setBrowsing] = useState(false);
  const [sortType, setSortType] = useState<SortType>(DEFAULT_SORT_TYPE);
  const [matchMode, setMatchMode] = useState<MatchMode>(DEFAULT_MATCH_MODE);
  const [filterTime, setFilterTime] = useState<FilterTime>('all');
  const [filterSize, setFilterSize] = useState<FilterSize>('all');
  const [msg, setMsg] = useState('');
  const [pasteOpen, setPasteOpen] = useState(false);
  const [chatOpen, setChatOpen] = useState(false);
  const [boardsOpen, setBoardsOpen] = useState(false);
  const [detailHash, setDetailHash] = useState<string | null>(null);
  const [detailSource, setDetailSource] = useState<FeedSource>('sehua');
  const [scopeItem, setScopeItem] = useState<ScopeSearchItem | null>(null);
  const [reloadToken, setReloadToken] = useState(0);
  const [searchRegion, setSearchRegion] = useState<string | null>(null);
  const [searchScope, setSearchScope] = useState<SearchScope>('movie');
  const [searchSource, setSearchSource] = useState<ScopeSearchSource | 'all'>(
    'all',
  );
  const [scopePage, setScopePage] = useState(1);
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  const overlayOpen = Boolean(
    detailHash || scopeItem || pasteOpen || chatOpen || boardsOpen,
  );
  const mainCover = useStackCover(
    overlayOpen,
    'home-main',
    'home-stack-main',
  );
  const scrollBodyRef = useRef<HTMLDivElement | null>(null);
  const hydrated = useRef(false);
  const skipUrlWrite = useRef(false);

  // iOS 下拉刷新：仅列表态（results）启用，刷新时换 key 重拉第一页
  usePullToRefresh({
    scrollRef: scrollBodyRef,
    disabled: mode !== 'results' || Boolean(detailHash || scopeItem),
    onRefresh: () => {
      setScopePage(1);
      setReloadToken((n) => n + 1);
    },
  });

  const openSehualDetail = useCallback((hash: string) => {
    setDetailSource('sehua');
    setDetailHash(hash);
    syncDetailUrl(hash, 'sehua');
  }, []);

  const closeDetail = useCallback(() => {
    setDetailHash(null);
    setScopeItem(null);
    syncDetailUrl(null);
  }, []);

  const onSearchScopeChange = useCallback((next: SearchScope) => {
    setSearchScope(next);
    setSearchSource('all');
    setScopePage(1);
    scrollBodyRef.current?.scrollTo({ top: 0 });
  }, []);

  const onSearchSourceChange = useCallback(
    (next: ScopeSearchSource | 'all') => {
      setSearchSource(next);
      setScopePage(1);
      scrollBodyRef.current?.scrollTo({ top: 0 });
    },
    [],
  );

  const openScopeDetail = useCallback((item: ScopeSearchItem) => {
    if (item.hash) {
      const src: FeedSource =
        item.source === 'bitmagnet' ? 'bitmagnet' : 'sehua';
      setDetailSource(src);
      setDetailHash(item.hash);
      setScopeItem(null);
      syncDetailUrl(item.hash, src);
      return;
    }
    setScopeItem(item);
  }, []);

  const closeScopeDetail = useCallback(() => setScopeItem(null), []);

  const retrySearch = useCallback(() => {
    setScopePage(1);
    setReloadToken((n) => n + 1);
  }, []);

  function goLanding() {
    setMode('landing');
    setDraft('');
    setKeyword('');
    setBrowsing(false);
    setSearchRegion(null);
    setSearchScope('movie');
    setSearchSource('all');
    setScopePage(1);
    closeDetail();
    try {
      clearSaveSource();
    } catch {
      /* ignore */
    }
  }

  useEffect(() => {
    if (hydrated.current) return;
    hydrated.current = true;
    try {
      const sp = new URLSearchParams(window.location.search);
      const kw = (sp.get('keyword') || '').trim();
      const browse = sp.get('browse') === '1';
      const detail = sp.get('detail');
      const ds = sp.get('ds') === 'bitmagnet' ? 'bitmagnet' : 'sehua';
      // 兼容旧链接 src=sehua / src=bitmagnet
      const scope: SearchScope =
        sp.get('scope') === 'maker' || sp.get('src') === 'sehua'
          ? 'maker'
          : 'movie';
      skipUrlWrite.current = true;
      if (kw.length >= SEARCH_KEYWORD_LENGTH_MIN) {
        // 挂载时一次性从 URL 恢复状态（SSR 后只能 post-mount 同步）
        // eslint-disable-next-line react-hooks/set-state-in-effect
        setDraft(kw);
        setKeyword(kw);
        setBrowsing(false);
        setSortType(normalizeSortType(sp.get('sortType')));
        setMatchMode(normalizeMatchMode(sp.get('matchMode')));
        setFilterTime(normalizeFilterTime(sp.get('filterTime')));
        setFilterSize(normalizeFilterSize(sp.get('filterSize')));
        setSearchRegion(sp.get('region')?.trim() || null);
        setSearchScope(scope);
        setScopePage(1);
        setMode('results');
      } else if (browse) {
        setDraft('');
        setKeyword('');
        setBrowsing(true);
        setSearchScope('movie');
        setScopePage(1);
        setMode('results');
      }
      if (detail) {
        setDetailSource(ds);
        setDetailHash(decodeURIComponent(detail));
        if (kw.length < SEARCH_KEYWORD_LENGTH_MIN && !browse) {
          setMode('results');
          setBrowsing(true);
        }
      }
      queueMicrotask(() => {
        skipUrlWrite.current = false;
      });
    } catch {
      skipUrlWrite.current = false;
    }
  }, []);

  useEffect(() => {
    if (!hydrated.current || skipUrlWrite.current) return;
    if (tabCtx && tabCtx.activeTab !== '/') return;
    syncSearchUrl({
      mode,
      keyword,
      browsing,
      sortType,
      matchMode,
      filterTime,
      filterSize,
      region: searchRegion,
      searchScope,
    });
  }, [
    tabCtx?.activeTab,
    mode,
    keyword,
    browsing,
    sortType,
    matchMode,
    filterTime,
    filterSize,
    searchRegion,
    searchScope,
  ]);

  useEffect(() => {
    if (!tabCtx || tabCtx.activeTab !== '/') return;
    // 再次点中 Tab 回到落地页（产品行为）
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (tabCtx.tabReselect > 0) goLanding();
  }, [tabCtx?.tabReselect]);

  useEffect(() => {
    const onSearchEvent = () => {
      try {
        const key = sessionStorage.getItem('nextweb:home-search');
        if (!key) return;
        const region = sessionStorage.getItem('nextweb:home-prefix-region');
        const srcRaw = sessionStorage.getItem('nextweb:home-search-source');
        sessionStorage.removeItem('nextweb:home-search');
        sessionStorage.removeItem('nextweb:home-mode');
        sessionStorage.removeItem('nextweb:home-prefix-region');
        sessionStorage.removeItem('nextweb:home-search-source');
        const next = key.trim();
        if (next.length < SEARCH_KEYWORD_LENGTH_MIN) return;
        setDraft(next);
        setKeyword(next);
        setBrowsing(false);
        setMatchMode('exact');
        setSortType(DEFAULT_SORT_TYPE);
        setFilterTime('all');
        setFilterSize('all');
        setSearchRegion(region?.trim() || null);
        // 旧来源值：bitmagnet 归入「影视」，其余归入「片商」
        setSearchScope(srcRaw === 'sehua' ? 'maker' : 'movie');
        setSearchSource('all');
        setScopePage(1);
        closeDetail();
        setMode('results');
        setReloadToken((n) => n + 1);
      } catch {
        /* ignore */
      }
    };
    window.addEventListener('nextweb:home-search', onSearchEvent);
    return () => window.removeEventListener('nextweb:home-search', onSearchEvent);
  }, [closeDetail]);

  function submitSearch(raw?: string) {
    const next = (raw ?? draft).trim();
    if (!next) return;
    if (next.length < SEARCH_KEYWORD_LENGTH_MIN) {
      setMsg(`请输入至少 ${SEARCH_KEYWORD_LENGTH_MIN} 个字符`);
      return;
    }
    try {
      clearSaveSource();
    } catch {
      /* ignore */
    }
    setDraft(next);
    setKeyword(next);
    setBrowsing(false);
    setSearchRegion(null);
    setScopePage(1);
    setMode('results');
    setReloadToken((n) => n + 1);
  }

  function browseLatest() {
    try {
      clearSaveSource();
    } catch {
      /* ignore */
    }
    setDraft('');
    setKeyword('');
    setBrowsing(true);
    setSearchRegion(null);
    setScopePage(1);
    setMode('results');
    setReloadToken((n) => n + 1);
  }

  const isKeywordSearch = !browsing && keyword.length >= SEARCH_KEYWORD_LENGTH_MIN;

  // 色花堂：仅「最新」浏览使用无限流；关键词搜索统一走范围聚合接口
  const sehuaActive = mode === 'results' && browsing;

  const sehuaQuery = useInfiniteQuery({
    queryKey: ['home', 'sehua', 'browse', reloadToken],
    queryFn: ({ pageParam, signal }) =>
      fetchBrowse({
        page: pageParam,
        pageSize: BROWSE_LATEST_PAGE_SIZE,
        signal,
      }),
    enabled: sehuaActive,
    initialPageParam: 1,
    getNextPageParam: (last, all, lastPageParam) => {
      if (!last.has_more) return undefined;
      const loaded = all.reduce((n, p) => n + p.resources.length, 0);
      if (loaded >= BROWSE_LATEST_MAX) return undefined;
      return lastPageParam + 1;
    },
  });

  const sehuaPages = sehuaQuery.data?.pages;
  const items = useMemo<ResourceItem[]>(() => {
    if (!sehuaPages?.length) return [];
    const seen = new Set<string>();
    const out: ResourceItem[] = [];
    for (const p of sehuaPages) {
      for (const r of p.resources) {
        if (seen.has(r.hash)) continue;
        seen.add(r.hash);
        out.push(r);
        if (out.length >= BROWSE_LATEST_MAX) break;
      }
      if (out.length >= BROWSE_LATEST_MAX) break;
    }
    return out;
  }, [sehuaPages]);

  const sehuaFirstTotal = sehuaPages?.[0]?.total_count ?? 0;
  const sehuaTotal = Math.min(sehuaFirstTotal || items.length, BROWSE_LATEST_MAX);
  const sehuaLoading = sehuaQuery.isLoading;
  const sehuaLoadingMore = sehuaQuery.isFetchingNextPage;
  const sehuaHasMore = sehuaQuery.hasNextPage;
  const sehuaError = sehuaQuery.isError
    ? sehuaQuery.error instanceof Error
      ? sehuaQuery.error.message
      : '加载失败'
    : '';

  useEffect(() => {
    if (!sehuaError) return;
    const softTimeout =
      /statement timeout|canceling statement|搜索超时|色花堂搜索超时/i.test(
        sehuaError,
      );
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 错误文案映射，等价于旧版 fetch effect 内的 setMsg
    setMsg(
      softTimeout
        ? '色花堂搜索超时，可换关键词或稍后再试'
        : sehuaError === 'Not Found'
          ? '搜索接口未就绪，请重启 API 后再试'
          : sehuaError,
    );
  }, [sehuaError]);

  // 范围聚合搜索：影视（Bitmagnet + CloudSaver）/ 片商（AVDB + Bitmagnet + 色花堂）
  const scopeQuery = useQuery({
    queryKey: [
      'home',
      'scope',
      searchScope,
      searchSource,
      keyword,
      scopePage,
      sortType,
      filterTime,
      filterSize,
      reloadToken,
    ],
    queryFn: ({ signal }) =>
      fetchScopeSearch({
        scope: searchScope,
        source: searchSource,
        keyword,
        page: scopePage,
        pageSize: SCOPE_PAGE_SIZE,
        sortType,
        filterTime,
        filterSize,
        signal,
      }),
    enabled: mode === 'results' && isKeywordSearch,
    placeholderData: (prev) => prev,
    staleTime: 60 * 1000,
    retry: 0,
  });

  const staleScope = scopeQuery.isPlaceholderData;
  const scopeItems = staleScope ? [] : (scopeQuery.data?.items ?? []);
  const scopeSourceErrors = staleScope ? {} : (scopeQuery.data?.sourceErrors ?? {});
  // placeholderData 会把上一次查询的结果挂在当前 key 下（isLoading 为 false），
  // 换关键词/重搜时必须按加载中处理，否则会显示旧结果且没有转圈。
  const scopeLoading =
    scopeQuery.isLoading || (scopeQuery.isPlaceholderData && scopeQuery.isFetching);
  const scopeFetching = scopeQuery.isFetching;
  const scopeHasMore = !staleScope && Boolean(scopeQuery.data?.hasMore);
  const scopeError = scopeQuery.isError
    ? scopeQuery.error instanceof Error
      ? scopeQuery.error.message
      : '范围搜索失败'
    : '';

  const resultKeywords = keyword ? [keyword] : [];
  const activeLoading = browsing ? sehuaLoading : scopeLoading;
  const activeLoadingMore = browsing ? sehuaLoadingMore : scopeFetching && !scopeLoading;
  const activeHasMore = browsing ? sehuaHasMore : scopeHasMore;

  // 下拉刷新完成后收起指示器（首屏加载态结束即代表新数据已拉取）
  useEffect(() => {
    if (mode !== 'results') return;
    if (browsing ? !sehuaLoading : !scopeLoading) {
      finishPullToRefresh(scrollBodyRef);
    }
  }, [browsing, sehuaLoading, scopeLoading, mode]);

  useEffect(() => {
    if (mode !== 'results' || detailHash || !browsing) return;
    if (!sehuaHasMore || sehuaLoading || sehuaLoadingMore) return;
    const el = sentinelRef.current;
    if (!el) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting)) return;
        if (sehuaQuery.hasNextPage) void sehuaQuery.fetchNextPage();
      },
      { root: scrollBodyRef.current, rootMargin: '240px 0px', threshold: 0 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [
    mode,
    detailHash,
    browsing,
    sehuaHasMore,
    sehuaLoading,
    sehuaLoadingMore,
    sehuaQuery,
    items.length,
  ]);

  const scopeLabel = searchScope === 'movie' ? '影视' : '片商';
  const hint = isKeywordSearch
    ? scopeLoading
      ? `${scopeLabel}搜索中…`
      : scopeError
        ? `${scopeLabel}搜索失败`
        : `${scopeLabel} · ${scopeItems.length} 条`
    : sehuaTotal > 0
      ? `最新 · ${Math.min(sehuaTotal, BROWSE_LATEST_MAX)} 条`
      : '最新资源';

  function onFilterChange<T>(setter: (v: T) => void) {
    return (v: T) => {
      setter(v);
      setScopePage(1);
      scrollBodyRef.current?.scrollTo({ top: 0 });
    };
  }

  return {
    mode,
    draft,
    setDraft,
    keyword,
    browsing,
    sortType,
    setSortType,
    matchMode,
    setMatchMode,
    filterTime,
    setFilterTime,
    filterSize,
    setFilterSize,
    items,
    msg,
    setMsg,
    pasteOpen,
    setPasteOpen,
    chatOpen,
    setChatOpen,
    boardsOpen,
    setBoardsOpen,
    detailHash,
    detailSource,
    scopeItem,
    closeScopeDetail,
    searchRegion,
    searchScope,
    searchSource,
    onSearchSourceChange,
    sentinelRef,
    mainCover,
    scrollBodyRef,
    openSehualDetail,
    closeDetail,
    onSearchScopeChange,
    openScopeDetail,
    goLanding,
    submitSearch,
    browseLatest,
    isKeywordSearch,
    resultKeywords,
    scopeItems,
    scopePage,
    setScopePage,
    scopeLoading,
    scopeFetching,
    scopeError,
    scopeSourceErrors,
    scopeHasMore,
    activeLoading,
    activeLoadingMore,
    activeHasMore,
    hint,
    onFilterChange,
    error: sehuaError,
    retrySearch,
  };
}
