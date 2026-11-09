'use client';

import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type FormEvent,
} from 'react';
import {
  fetchDramaRank,
  fetchDramaRankGroups,
  fetchDramaSearch,
  fetchDramaSeries,
  fetchDramaSites,
  type DramaCard,
  type DramaEpisode,
  type DramaRankGroup,
  type DramaSeries,
  type DramaSite,
} from '@/lib/api';
import { useTabPaneVisible } from '@/shell/TabPane';

export type RankSection = {
  id: string;
  group: string;
  title: string;
  items: DramaCard[];
  loading: boolean;
  error: string;
};

export const SHELF_LIMIT = 15;

export function useDramaSites() {
  // 所有 Tab 都会挂载：远离的短剧页不发请求，避免冷启动时串行拉起插件
  const visible = useTabPaneVisible();
  const [sites, setSites] = useState<DramaSite[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!visible) return;
    const ctrl = new AbortController();
    const load = async (silent = false) => {
      if (!silent) setLoading(true);
      setError('');
      try {
        const items = await fetchDramaSites(ctrl.signal);
        if (!ctrl.signal.aborted) setSites(items.filter((item) => item.enabled));
      } catch (e: unknown) {
        if (ctrl.signal.aborted) return;
        setError(e instanceof Error ? e.message : '短剧站点加载失败');
      } finally {
        if (!ctrl.signal.aborted && !silent) setLoading(false);
      }
    };
    void load();
    const refresh = () => void load(true);
    window.addEventListener('rexhub:shortdrama-sites', refresh);
    window.addEventListener('focus', refresh);
    return () => {
      ctrl.abort();
      window.removeEventListener('rexhub:shortdrama-sites', refresh);
      window.removeEventListener('focus', refresh);
    };
  }, [visible]);

  return { sites, loading, error };
}

export function useDramaCatalog(site: string, onSearch: (q: string) => void) {
  const [keyword, setKeyword] = useState('');
  const [groups, setGroups] = useState<DramaRankGroup[]>([]);
  const [group, setGroup] = useState('');
  const [groupsLoading, setGroupsLoading] = useState(true);
  const [groupsError, setGroupsError] = useState('');
  const [sections, setSections] = useState<RankSection[]>([]);
  const [filterOpen, setFilterOpen] = useState(false);
  const [filterIdx, setFilterIdx] = useState(0);
  const [filterId, setFilterId] = useState('');

  const activeGroup = groups.find((item) => item.id === group);
  const filterGroups = activeGroup?.ranks[0]?.filters ?? [];
  const filterItems = filterGroups[filterIdx]?.items ?? [];

  useEffect(() => {
    const ctrl = new AbortController();
    const load = async () => {
      setGroupsLoading(true);
      setGroupsError('');
      try {
        const list = await fetchDramaRankGroups(site, ctrl.signal);
        if (ctrl.signal.aborted) return;
        setGroups(list);
        setGroup(list[0]?.id ?? '');
      } catch (e: unknown) {
        if (ctrl.signal.aborted) return;
        setGroups([]);
        setGroup('');
        setGroupsError(e instanceof Error ? e.message : '榜单加载失败');
      } finally {
        if (!ctrl.signal.aborted) setGroupsLoading(false);
      }
    };
    void load();
    return () => ctrl.abort();
  }, [site]);

  useEffect(() => {
    const active = groups.find((item) => item.id === group);
    if (!active) return;
    const ctrl = new AbortController();

    // 首页只取第 1 页，每个横滑架最多 15 部；更多内容走「全部」页
    const load = async () => {
      setSections(
        active.ranks.map((rank) => ({
          id: rank.id,
          group: active.id,
          title: rank.title,
          items: [],
          loading: true,
          error: '',
        })),
      );
      await Promise.all(
        active.ranks.map(async (rank) => {
          try {
            const data = await fetchDramaRank(
              site,
              active.id,
              rank.id,
              1,
              ctrl.signal,
              filterId,
              SHELF_LIMIT,
            );
            if (ctrl.signal.aborted) return;
            setSections((prev) =>
              prev.map((item) =>
                item.id === rank.id
                  ? { ...item, items: data.items, loading: false }
                  : item,
              ),
            );
          } catch (e: unknown) {
            if (ctrl.signal.aborted) return;
            const message = e instanceof Error ? e.message : '榜单加载失败';
            setSections((prev) =>
              prev.map((item) =>
                item.id === rank.id
                  ? { ...item, loading: false, error: message }
                  : item,
              ),
            );
          }
        }),
      );
    };
    void load();
    return () => ctrl.abort();
  }, [site, group, groups, filterId]);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    const text = keyword.trim();
    if (text) onSearch(text);
  };

  return {
    keyword,
    setKeyword,
    groups,
    group,
    setGroup,
    groupsLoading,
    groupsError,
    sections,
    filterOpen,
    setFilterOpen,
    filterIdx,
    setFilterIdx,
    filterId,
    setFilterId,
    filterGroups,
    filterItems,
    submit,
  };
}

type PagedCache = {
  items: DramaCard[];
  page: number;
  hasMore: boolean;
  at: number;
};

const PAGE_CACHE_TTL = 5 * 60 * 1000;
const rankPageCache = new Map<string, PagedCache>();
const searchPageCache = new Map<string, PagedCache>();

function readPageCache(cache: Map<string, PagedCache>, key: string): PagedCache | null {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at > PAGE_CACHE_TTL) {
    cache.delete(key);
    return null;
  }
  return hit;
}

function writePageCache(
  cache: Map<string, PagedCache>,
  key: string,
  value: Omit<PagedCache, 'at'>,
) {
  cache.set(key, { ...value, at: Date.now() });
}

function mergeCards(prev: DramaCard[], next: DramaCard[]) {
  const seen = new Set(prev.map((item) => item.id));
  return [...prev, ...next.filter((item) => !seen.has(item.id))];
}

export function useDramaRank(site: string, group: string, rank: string) {
  const cacheKey = `${site}|${group}|${rank}`;
  const [initial] = useState(() => readPageCache(rankPageCache, cacheKey));
  const [items, setItems] = useState<DramaCard[]>(initial?.items ?? []);
  const [page, setPage] = useState(initial?.page ?? 1);
  const [hasMore, setHasMore] = useState(initial?.hasMore ?? false);
  const [loading, setLoading] = useState(!initial);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');
  const sentinelRef = useRef<HTMLDivElement>(null);
  const moreCtrlRef = useRef<AbortController | null>(null);

  useEffect(() => {
    // 从详情返回时直接复用缓存，避免列表清空导致滚动位置丢失
    const cached = readPageCache(rankPageCache, cacheKey);
    if (cached) {
      setItems(cached.items);
      setPage(cached.page);
      setHasMore(cached.hasMore);
      setError('');
      setLoading(false);
      return;
    }
    const ctrl = new AbortController();
    const load = async () => {
      setLoading(true);
      setError('');
      try {
        const data = await fetchDramaRank(site, group, rank, 1, ctrl.signal);
        if (ctrl.signal.aborted) return;
        setItems(data.items);
        setPage(1);
        setHasMore(Boolean(data.hasMore));
        writePageCache(rankPageCache, cacheKey, {
          items: data.items,
          page: 1,
          hasMore: Boolean(data.hasMore),
        });
      } catch (e: unknown) {
        if (ctrl.signal.aborted) return;
        setItems([]);
        setHasMore(false);
        setError(e instanceof Error ? e.message : '榜单加载失败');
      } finally {
        if (!ctrl.signal.aborted) setLoading(false);
      }
    };
    void load();
    return () => ctrl.abort();
  }, [cacheKey, site, group, rank]);

  useEffect(() => () => moreCtrlRef.current?.abort(), []);

  const loadMore = useCallback(() => {
    if (loadingMore || !hasMore) return;
    const next = page + 1;
    moreCtrlRef.current?.abort();
    const ctrl = new AbortController();
    moreCtrlRef.current = ctrl;
    setLoadingMore(true);
    fetchDramaRank(site, group, rank, next, ctrl.signal)
      .then((data) => {
        if (ctrl.signal.aborted) return;
        const merged = mergeCards(items, data.items);
        const nextHasMore = Boolean(data.hasMore) && data.items.length > 0;
        setItems(merged);
        setPage(next);
        setHasMore(nextHasMore);
        writePageCache(rankPageCache, cacheKey, {
          items: merged,
          page: next,
          hasMore: nextHasMore,
        });
      })
      .catch((e: unknown) => {
        if (ctrl.signal.aborted) return;
        setError(e instanceof Error ? e.message : '加载更多失败');
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoadingMore(false);
      });
  }, [site, group, rank, cacheKey, page, hasMore, loadingMore, items]);

  useEffect(() => {
    if (!hasMore) return;
    const el = sentinelRef.current;
    if (!el) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) loadMore();
      },
      { root: el.closest('.app-push__body') || null, rootMargin: '160px' },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [hasMore, loadMore, items.length]);

  return { items, loading, loadingMore, error, sentinelRef };
}

export function useDramaSearch(site: string, initialQuery: string) {
  const cacheKey = initialQuery ? `${site}|${initialQuery}` : '';
  const [input, setInput] = useState(initialQuery);
  const [query, setQuery] = useState(initialQuery);
  const [initial] = useState(() =>
    cacheKey ? readPageCache(searchPageCache, cacheKey) : null,
  );
  const [items, setItems] = useState<DramaCard[]>(initial?.items ?? []);
  const [page, setPage] = useState(initial?.page ?? 1);
  const [hasMore, setHasMore] = useState(initial?.hasMore ?? false);
  const [loading, setLoading] = useState(Boolean(initialQuery) && !initial);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');
  const moreCtrlRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (!query) return;
    const key = `${site}|${query}`;
    // 从详情返回时复用上次搜索结果
    const cached = readPageCache(searchPageCache, key);
    if (cached) {
      setItems(cached.items);
      setPage(cached.page);
      setHasMore(cached.hasMore);
      setError('');
      setLoading(false);
      return;
    }
    const ctrl = new AbortController();
    const load = async () => {
      setLoading(true);
      setError('');
      try {
        const data = await fetchDramaSearch(site, query, 1, ctrl.signal);
        if (ctrl.signal.aborted) return;
        setItems(data.items);
        setPage(1);
        setHasMore(data.hasMore);
        writePageCache(searchPageCache, key, {
          items: data.items,
          page: 1,
          hasMore: data.hasMore,
        });
      } catch (e: unknown) {
        if (ctrl.signal.aborted) return;
        setItems([]);
        setHasMore(false);
        setError(e instanceof Error ? e.message : '搜索失败');
      } finally {
        if (!ctrl.signal.aborted) setLoading(false);
      }
    };
    void load();
    return () => ctrl.abort();
  }, [site, query]);

  useEffect(() => () => moreCtrlRef.current?.abort(), []);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    const next = input.trim();
    if (!next) {
      setQuery('');
      setItems([]);
      setPage(1);
      setHasMore(false);
      setError('');
      setLoading(false);
      return;
    }
    setQuery(next);
  };

  const loadMore = () => {
    if (loadingMore || !query || !hasMore) return;
    const next = page + 1;
    const key = `${site}|${query}`;
    moreCtrlRef.current?.abort();
    const ctrl = new AbortController();
    moreCtrlRef.current = ctrl;
    setLoadingMore(true);
    setError('');
    fetchDramaSearch(site, query, next, ctrl.signal)
      .then((data) => {
        if (ctrl.signal.aborted) return;
        const merged = mergeCards(items, data.items);
        setItems(merged);
        setPage(next);
        setHasMore(data.hasMore);
        writePageCache(searchPageCache, key, {
          items: merged,
          page: next,
          hasMore: data.hasMore,
        });
      })
      .catch((e: unknown) => {
        if (ctrl.signal.aborted) return;
        setError(e instanceof Error ? e.message : '加载更多失败');
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoadingMore(false);
      });
  };

  return {
    input,
    setInput,
    query,
    items,
    loading,
    loadingMore,
    hasMore,
    error,
    submit,
    loadMore,
  };
}

export function useDramaDetail(site: string, card: DramaCard) {
  const [detail, setDetail] = useState<DramaSeries | null>(null);
  const [current, setCurrent] = useState<DramaEpisode | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    const ctrl = new AbortController();
    const load = async () => {
      setLoading(true);
      setError('');
      setCurrent(null);
      try {
        const data = await fetchDramaSeries(site, card.id, ctrl.signal);
        if (!ctrl.signal.aborted) setDetail(data);
      } catch (e: unknown) {
        if (ctrl.signal.aborted) return;
        setError(e instanceof Error ? e.message : '详情加载失败');
      } finally {
        if (!ctrl.signal.aborted) setLoading(false);
      }
    };
    void load();
    return () => ctrl.abort();
  }, [site, card.id]);

  const play = (episode: DramaEpisode) => setCurrent(episode);

  return { detail, current, loading, error, play };
}
