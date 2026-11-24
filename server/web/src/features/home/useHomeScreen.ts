'use client';

import {
  startTransition,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type RefObject,
} from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';
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
import { navDepth, navPush, rememberTabUrl } from '@/shell/nav/urlNav';

/** 详情页地址（保留当前搜索条件，只替换 detail/ds） */
function detailHref(hash: string, source: FeedSource): string {
  const url = new URL(window.location.href);
  url.searchParams.set('detail', hash);
  if (source === 'bitmagnet') url.searchParams.set('ds', 'bitmagnet');
  else url.searchParams.delete('ds');
  return `${url.pathname}${url.search}${url.hash}`;
}

export type HomeScreenState = ReturnType<typeof useHomeScreen>;

/** DOM 引用由渲染方持有，避免 ref 混进状态对象后被跨组件传递 */
export type HomeScreenRefs = {
  scrollBodyRef: RefObject<HTMLDivElement | null>;
  sentinelRef: RefObject<HTMLDivElement | null>;
};

export function useHomeScreen({ scrollBodyRef, sentinelRef }: HomeScreenRefs) {
  const tabCtx = useTabNavigation();
  const activeTab = tabCtx?.activeTab;
  const tabReselect = tabCtx?.tabReselect ?? 0;
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
  const overlayOpen = Boolean(
    detailHash || scopeItem || pasteOpen || chatOpen || boardsOpen,
  );
  const mainCover = useStackCover(
    overlayOpen,
    'home-main',
    'home-stack-main',
  );
  const hydrated = useRef(false);
  const skipUrlWrite = useRef(false);

  // iOS 下拉刷新：仅列表态（results）启用，刷新时换 key 重拉第一页
  usePullToRefresh({
    scrollRef: scrollBodyRef,
    disabled: mode !== 'results' || Boolean(detailHash || scopeItem),
    onRefresh: () => {
      setReloadToken((n) => n + 1);
    },
  });

  const openSehualDetail = useCallback((hash: string) => {
    setDetailSource('sehua');
    setDetailHash(hash);
    const next = detailHref(hash, 'sehua');
    if (
      `${window.location.pathname}${window.location.search}${window.location.hash}` !==
      next
    ) {
      navPush(next);
    }
  }, []);

  const closeDetail = useCallback(() => {
    const hasDetail = Boolean(
      new URLSearchParams(window.location.search).get('detail'),
    );
    // 详情是压栈打开的：返回上一层由浏览器历史处理
    if (hasDetail && navDepth() > 0) {
      window.history.back();
      return;
    }
    setDetailHash(null);
    setScopeItem(null);
    syncDetailUrl(null);
  }, []);

  const onSearchScopeChange = useCallback((next: SearchScope) => {
    setSearchScope(next);
    setSearchSource('all');
    scrollBodyRef.current?.scrollTo({ top: 0 });
  }, [scrollBodyRef]);

  const onSearchSourceChange = useCallback(
    (next: ScopeSearchSource | 'all') => {
      setSearchSource(next);
      scrollBodyRef.current?.scrollTo({ top: 0 });
    },
    [scrollBodyRef],
  );

  const openScopeDetail = useCallback((item: ScopeSearchItem) => {
    if (item.hash) {
      const src: FeedSource =
        item.source === 'bitmagnet' ? 'bitmagnet' : 'sehua';
      setDetailSource(src);
      setDetailHash(item.hash);
      setScopeItem(null);
      const next = detailHref(item.hash, src);
      if (
        `${window.location.pathname}${window.location.search}${window.location.hash}` !==
        next
      ) {
        navPush(next);
      }
      return;
    }
    setScopeItem(item);
  }, []);

  const closeScopeDetail = useCallback(() => setScopeItem(null), []);

  /** 打开板块：压一层历史，浏览器返回 / 页内返回都走 history.back() */
  const openBoards = useCallback(() => {
    try {
      window.history.pushState({ boardsHub: true }, '', '#boards');
    } catch {
      /* ignore */
    }
    setBoardsOpen(true);
  }, []);

  const retrySearch = useCallback(() => {
    setReloadToken((n) => n + 1);
  }, []);

  const goLanding = useCallback(() => {
    startTransition(() => {
      setMode('landing');
      setDraft('');
      setKeyword('');
      setBrowsing(false);
      setSearchRegion(null);
      setSearchScope('movie');
      setSearchSource('all');
    });
    closeDetail();
    try {
      clearSaveSource();
    } catch {
      /* ignore */
    }
  }, [closeDetail]);

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
        setMode('results');
      } else if (browse) {
        setDraft('');
        setKeyword('');
        setBrowsing(true);
        setSearchScope('movie');
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
      if (window.location.hash === '#boards') {
        // 深链 /#boards：先垫一个无 hash 的历史层，返回时可自然关闭板块
        window.history.replaceState(
          null,
          '',
          `${window.location.pathname}${window.location.search}`,
        );
        window.history.pushState({ boardsEntry: true }, '', '#boards');
        setBoardsOpen(true);
      }
      queueMicrotask(() => {
        skipUrlWrite.current = false;
      });
    } catch {
      skipUrlWrite.current = false;
    }
  }, []);

  useEffect(() => {
    // 板块与详情都跟地址栏同步：前进/返回时浮层状态一致
    const onPop = () => {
      setBoardsOpen(window.location.hash === '#boards');
      const sp = new URLSearchParams(window.location.search);
      const detail = sp.get('detail');
      if (detail) {
        setDetailSource(sp.get('ds') === 'bitmagnet' ? 'bitmagnet' : 'sehua');
        setDetailHash(decodeURIComponent(detail));
        setScopeItem(null);
      } else {
        setDetailHash(null);
      }
    };
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);

  useEffect(() => {
    if (!hydrated.current || skipUrlWrite.current) return;
    if (activeTab !== '/') return;
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
    activeTab,
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

  // 切 Tab 再回来时，恢复首页当前所在的地址（含详情 / 板块）
  useEffect(() => {
    if (activeTab !== '/') return;
    rememberTabUrl(
      '/',
      `${window.location.pathname}${window.location.search}${window.location.hash}`,
    );
  });

  useEffect(() => {
    if (activeTab !== '/' || tabReselect === 0) return;
    // 再次点中 Tab 回到落地页（产品行为）
    startTransition(() => goLanding());
  }, [activeTab, tabReselect, goLanding]);

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
  // 无限流：每批取 SCOPE_PAGE_SIZE 条，追加进列表后自动续拉，直到后端明确 hasMore=false。
  const scopeQuery = useInfiniteQuery({
    queryKey: [
      'home',
      'scope',
      searchScope,
      searchSource,
      keyword,
      sortType,
      filterTime,
      filterSize,
      reloadToken,
    ],
    queryFn: ({ pageParam, signal }) =>
      fetchScopeSearch({
        scope: searchScope,
        source: searchSource,
        keyword,
        page: pageParam,
        pageSize: SCOPE_PAGE_SIZE,
        sortType,
        filterTime,
        filterSize,
        signal,
      }),
    enabled: mode === 'results' && isKeywordSearch,
    initialPageParam: 1,
    getNextPageParam: (last) => (last.hasMore ? last.page + 1 : undefined),
    placeholderData: (prev) => prev,
    staleTime: 60 * 1000,
    // 单页偶发失败自动重试，避免连续加载链路被一次网络抖动打断
    retry: 2,
  });

  const staleScope = scopeQuery.isPlaceholderData;
  const scopePages = useMemo(
    () => (staleScope ? [] : (scopeQuery.data?.pages ?? [])),
    [staleScope, scopeQuery.data],
  );
  // 多批结果按 id 去重后顺序拼接：加载过程中只追加，不清空已展示内容
  const scopeItems = useMemo<ScopeSearchItem[]>(() => {
    const seen = new Set<string>();
    const out: ScopeSearchItem[] = [];
    for (const page of scopePages) {
      for (const item of page.items ?? []) {
        if (seen.has(item.id)) continue;
        seen.add(item.id);
        out.push(item);
      }
    }
    return out;
  }, [scopePages]);
  const scopeSourceErrors = useMemo(() => {
    const merged: Record<string, string> = {};
    for (const page of scopePages) Object.assign(merged, page.sourceErrors ?? {});
    return merged;
  }, [scopePages]);
  // placeholderData 会把上一次查询的结果挂在当前 key 下（isLoading 为 false），
  // 换关键词/重搜时必须按加载中处理，否则会显示旧结果且没有转圈。
  const scopeLoading =
    scopeQuery.isLoading ||
    (scopeQuery.isPlaceholderData && scopeQuery.isFetching && scopePages.length === 0);
  const scopeFetching = scopeQuery.isFetchingNextPage;
  const scopeHasMore = !staleScope && Boolean(scopeQuery.hasNextPage);
  const scopeError =
    scopeQuery.isError && scopePages.length === 0
      ? scopeQuery.error instanceof Error
        ? scopeQuery.error.message
        : '范围搜索失败'
      : '';
  // 已经有结果时后续批次失败：保留已加载内容，只提示可手动继续
  const scopeLoadMoreError =
    scopeQuery.isError && scopePages.length > 0
      ? scopeQuery.error instanceof Error
        ? scopeQuery.error.message
        : '加载更多失败'
      : '';

  const scopeLoadMore = useCallback(() => {
    if (scopeQuery.isFetching || !scopeQuery.hasNextPage) return;
    void scopeQuery.fetchNextPage();
  }, [scopeQuery]);

  // 自动续拉：每批加载完成立即请求下一批，直到无更多结果；
  // 请求失败时停下等用户手动继续，避免失败重试空转。
  useEffect(() => {
    if (mode !== 'results' || !isKeywordSearch) return;
    if (scopeQuery.isError || scopeQuery.isFetching) return;
    if (!scopeQuery.hasNextPage || scopeQuery.isFetchingNextPage) return;
    const timer = window.setTimeout(() => {
      void scopeQuery.fetchNextPage();
    }, 120);
    return () => window.clearTimeout(timer);
  }, [mode, isKeywordSearch, scopeQuery, scopeItems.length]);

  const resultKeywords = keyword ? [keyword] : [];
  const activeLoading = browsing ? sehuaLoading : scopeLoading;
  const activeLoadingMore = browsing ? sehuaLoadingMore : scopeFetching;
  const activeHasMore = browsing ? sehuaHasMore : scopeHasMore;

  // 下拉刷新完成后收起指示器（首屏加载态结束即代表新数据已拉取）
  useEffect(() => {
    if (mode !== 'results') return;
    if (browsing ? !sehuaLoading : !scopeLoading) {
      finishPullToRefresh(scrollBodyRef);
    }
  }, [browsing, sehuaLoading, scopeLoading, mode, scrollBodyRef]);

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
    scrollBodyRef,
    sentinelRef,
  ]);

  const scopeLabel = searchScope === 'movie' ? '影视' : '片商';
  const hint = isKeywordSearch
    ? scopeLoading
      ? `${scopeLabel}搜索中…`
      : scopeError
        ? `${scopeLabel}搜索失败`
        : `${scopeLabel} · 已加载 ${scopeItems.length} 条${scopeHasMore ? '，继续加载中…' : ''}`
    : sehuaTotal > 0
      ? `最新 · ${Math.min(sehuaTotal, BROWSE_LATEST_MAX)} 条`
      : '最新资源';

  function onFilterChange<T>(setter: (v: T) => void) {
    return (v: T) => {
      setter(v);
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
    openBoards,
    detailHash,
    detailSource,
    scopeItem,
    closeScopeDetail,
    searchRegion,
    searchScope,
    searchSource,
    onSearchSourceChange,
    mainCover,
    openSehualDetail,
    closeDetail,
    onSearchScopeChange,
    openScopeDetail,
    goLanding,
    submitSearch,
    isKeywordSearch,
    resultKeywords,
    scopeItems,
    scopeLoading,
    scopeFetching,
    scopeError,
    scopeSourceErrors,
    scopeHasMore,
    scopeLoadMore,
    scopeLoadMoreError,
    activeLoading,
    activeLoadingMore,
    activeHasMore,
    hint,
    onFilterChange,
    error: sehuaError,
    retrySearch,
  };
}
