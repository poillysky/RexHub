'use client';

import {
  startTransition,
  useCallback,
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type FormEvent,
} from 'react';
import {
  ChevronRight,
  Clapperboard,
  Play,
  Search,
  SlidersHorizontal,
} from 'lucide-react';
import { AppPush } from '@/components/ui/AppPush';
import { SoftImg } from '@/components/SoftImg';
import Hls from 'hls.js';
import { useTabNavigation } from '@/shell';
import { useStackCover } from '@/hooks/useStackCover';
import {
  dramaStreamUrl,
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

type Stack =
  | { kind: 'hub' }
  | { kind: 'catalog'; site: string; name: string }
  | { kind: 'search'; site: string; name: string; q: string }
  | {
      kind: 'rank';
      site: string;
      siteName: string;
      group: string;
      rank: string;
      title: string;
    }
  | {
      kind: 'detail';
      site: string;
      siteName: string;
      card: DramaCard;
      back: Stack;
    };

export function DramaScreen() {
  const tabCtx = useTabNavigation();
  const [stack, setStack] = useState<Stack>({ kind: 'hub' });
  const hubCover = useStackCover(
    stack.kind !== 'hub',
    'drama-hub',
    'app-hub drama-hub',
  );

  // 再点当前 Tab：回到 Hub
  useEffect(() => {
    if (!tabCtx || tabCtx.activeTab !== '/drama') return;
    if (tabCtx.tabReselect > 0) {
      startTransition(() => setStack({ kind: 'hub' }));
    }
  }, [tabCtx?.tabReselect, tabCtx?.activeTab]);

  const hub = (
    <div {...hubCover}>
      <div className="media-hub__top">
        <div className="media-hub__top-row">
          <h1 className="app-hub__title">短剧</h1>
        </div>
      </div>
      <div className="app-hub__scroll">
        <DramaHub
          onOpen={(site) =>
            startTransition(() =>
              setStack({ kind: 'catalog', site: site.id, name: site.name }),
            )
          }
        />
      </div>
    </div>
  );

  let push = null;
  if (stack.kind === 'catalog') {
    push = (
      <AppPush
        title={stack.name}
        scrollKey={`drama-catalog-${stack.site}`}
        onBack={() => setStack({ kind: 'hub' })}
      >
        <DramaCatalogBody
          site={stack.site}
          onSearch={(q) =>
            startTransition(() =>
              setStack({ kind: 'search', site: stack.site, name: stack.name, q }),
            )
          }
          onOpenRank={(groupId, rankId, rankTitle) =>
            startTransition(() =>
              setStack({
                kind: 'rank',
                site: stack.site,
                siteName: stack.name,
                group: groupId,
                rank: rankId,
                title: rankTitle,
              }),
            )
          }
          onOpen={(card) =>
            startTransition(() =>
              setStack({
                kind: 'detail',
                site: stack.site,
                siteName: stack.name,
                card,
                back: stack,
              }),
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'search') {
    push = (
      <AppPush
        title="搜索"
        scrollKey={`drama-search-${stack.site}-${stack.q}`}
        onBack={() =>
          setStack({ kind: 'catalog', site: stack.site, name: stack.name })
        }
      >
        <DramaSearchBody
          site={stack.site}
          initialQuery={stack.q}
          onOpen={(card) =>
            startTransition(() =>
              setStack({
                kind: 'detail',
                site: stack.site,
                siteName: stack.name,
                card,
                back: stack,
              }),
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'rank') {
    push = (
      <AppPush
        title={stack.title}
        scrollKey={`drama-rank-${stack.site}-${stack.group}-${stack.rank}`}
        onBack={() =>
          setStack({ kind: 'catalog', site: stack.site, name: stack.siteName })
        }
      >
        <DramaRankBody
          key={`${stack.site}-${stack.group}-${stack.rank}`}
          site={stack.site}
          group={stack.group}
          rank={stack.rank}
          onOpen={(card) =>
            startTransition(() =>
              setStack({
                kind: 'detail',
                site: stack.site,
                siteName: stack.siteName,
                card,
                back: stack,
              }),
            )
          }
        />
      </AppPush>
    );
  } else if (stack.kind === 'detail') {
    push = (
      <AppPush
        title={stack.card.title || stack.siteName}
        scrollKey={`drama-detail-${stack.site}-${stack.card.id}`}
        scrollMode="top"
        onBack={() => startTransition(() => setStack(stack.back))}
      >
        <DramaDetailBody site={stack.site} card={stack.card} />
      </AppPush>
    );
  }

  return (
    <div className="app-stack-root drama-stack">
      {hub}
      {push}
    </div>
  );
}

/* ── Hub：片单来源卡片（首个为红果） ── */

function DramaHub({ onOpen }: { onOpen: (site: DramaSite) => void }) {
  const [sites, setSites] = useState<DramaSite[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
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
  }, []);

  return (
    <section className="drama-hub__section">
      <div className="drama-sites">
        {loading
          ? Array.from({ length: 1 }).map((_, i) => (
              <span key={i} className="drama-site-skel" />
            ))
          : null}
        {!loading && error ? (
          <p className="drama-empty allow-select">{error}</p>
        ) : null}
        {!loading && !error && sites.length === 0 ? (
          <p className="drama-empty">暂无可用的短剧片源</p>
        ) : null}
        {sites.map((site, index) => {
          const ui = site.ui?.shortdrama;
          const accent = ui?.accent;
          const cardStyle = accent
            ? ({ '--site-accent': accent } as CSSProperties)
            : undefined;
          return (
            <button
              key={site.id}
              type="button"
              className="drama-site-card"
              style={cardStyle}
              onClick={() => onOpen(site)}
            >
              <span
                className={`drama-site-card__logo${
                  ui?.logo
                    ? ' is-logo-image'
                    : site.id === 'rexhub.hongguo.video' || index === 0
                      ? ' is-hot'
                      : ''
                }`}
                style={
                  accent && !ui?.logo
                    ? {
                        background: `linear-gradient(135deg, ${accent}, color-mix(in srgb, ${accent} 55%, #fff))`,
                        boxShadow: `0 6px 16px color-mix(in srgb, ${accent} 30%, transparent)`,
                      }
                    : undefined
                }
                aria-hidden
              >
                {ui?.logo ? (
                  <SoftImg
                    className="drama-site-card__logo-img"
                    src={ui.logo}
                    loading="lazy"
                  />
                ) : ui?.icon ? (
                  <span
                    className="drama-site-card__glyph"
                    dangerouslySetInnerHTML={{ __html: ui.icon }}
                  />
                ) : (
                  <Clapperboard size={22} strokeWidth={1.9} aria-hidden />
                )}
              </span>
              <span className="drama-site-card__main">
                <span className="drama-site-card__name">
                  {ui?.title || site.name}
                  {ui?.badge ? (
                    <span className="drama-site-card__badge">{ui.badge}</span>
                  ) : null}
                </span>
                <span className="drama-site-card__desc">
                  {ui?.subtitle || '短剧片单 · 可直接播放'}
                </span>
              </span>
              <ChevronRight
                size={18}
                className="drama-site-card__arrow"
                aria-hidden
              />
            </button>
          );
        })}
      </div>
    </section>
  );
}

/* ── 片单 ── */

type RankSection = {
  id: string;
  group: string;
  title: string;
  items: DramaCard[];
  loading: boolean;
  error: string;
};

const SHELF_LIMIT = 15;

function DramaCatalogBody({
  site,
  onSearch,
  onOpenRank,
  onOpen,
}: {
  site: string;
  onSearch: (q: string) => void;
  onOpenRank: (group: string, rank: string, title: string) => void;
  onOpen: (card: DramaCard) => void;
}) {
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

  return (
    <div className="drama-catalog">
      <form className="drama-search drama-search--page" onSubmit={submit} role="search">
        <Search size={16} className="drama-search__icon" aria-hidden />
        <input
          className="drama-search__input"
          value={keyword}
          onChange={(event) => setKeyword(event.target.value)}
          placeholder="搜索短剧"
          type="search"
          enterKeyHint="search"
          aria-label="搜索短剧"
        />
        <button
          type="submit"
          className="drama-search__submit"
          disabled={!keyword.trim()}
        >
          搜索
        </button>
      </form>

      <div className="drama-stage-bar">
        {groups.length > 1 ? (
          <div
            className="media-source-switch"
            role="tablist"
            aria-label="短剧类型"
          >
            {groups.map((item) => (
              <button
                key={item.id}
                type="button"
                role="tab"
                aria-selected={item.id === group}
                className={
                  item.id === group
                    ? 'media-source-switch__btn is-active'
                    : 'media-source-switch__btn'
                }
                onClick={() => {
                  setGroup(item.id);
                  setFilterIdx(0);
                  setFilterId('');
                  setFilterOpen(false);
                }}
              >
                {item.title}
              </button>
            ))}
          </div>
        ) : null}
        {filterGroups.length > 0 ? (
          <button
            type="button"
            aria-expanded={filterOpen}
            className={
              filterOpen || filterId
                ? 'drama-filter-trigger is-active'
                : 'drama-filter-trigger'
            }
            onClick={() => setFilterOpen((open) => !open)}
          >
            <SlidersHorizontal size={14} strokeWidth={2} aria-hidden />
            筛选
          </button>
        ) : null}
      </div>

      {filterOpen && filterGroups.length > 0 ? (
        <div className="drama-filter-panel">
          {filterGroups.length > 1 ? (
            <div
              className="media-source-switch"
              role="tablist"
              aria-label="筛选维度"
            >
              {filterGroups.map((filterGroup, index) => (
                <button
                  key={filterGroup.title}
                  type="button"
                  role="tab"
                  aria-selected={index === filterIdx}
                  className={
                    index === filterIdx
                      ? 'media-source-switch__btn is-active'
                      : 'media-source-switch__btn'
                  }
                  onClick={() => {
                    setFilterIdx(index);
                    setFilterId('');
                  }}
                >
                  {filterGroup.title}
                </button>
              ))}
            </div>
          ) : null}
          <div className="drama-filter-row">
            {filterItems.map((option) => (
              <button
                key={option.id || 'all'}
                type="button"
                className={
                  option.id === filterId
                    ? 'drama-filter-chip is-active'
                    : 'drama-filter-chip'
                }
                onClick={() => setFilterId(option.id)}
              >
                {option.title}
              </button>
            ))}
          </div>
        </div>
      ) : null}

      {groupsLoading ? (
        <div className="drama-shelves">
          {Array.from({ length: 3 }).map((_, i) => (
            <section key={i} className="media-shelf">
              <span className="drama-shelf-skel-title" />
              <div className="media-shelf__rail media-shelf__rail--skel" aria-hidden>
                {Array.from({ length: 5 }).map((__, j) => (
                  <span key={j} className="drama-card-skel drama-card-skel--rail" />
                ))}
              </div>
            </section>
          ))}
        </div>
      ) : null}

      {!groupsLoading && groupsError ? (
        <p className="drama-empty allow-select">{groupsError}</p>
      ) : null}

      {!groupsLoading && !groupsError && groups.length === 0 ? (
        <p className="drama-empty">暂无榜单</p>
      ) : null}

      {sections.length > 0 ? (
        <div className="drama-shelves">
          {sections.map((section) => (
            <section key={section.id} className="media-shelf">
              <button
                type="button"
                className="media-shelf__head"
                onClick={() =>
                  onOpenRank(section.group, section.id, section.title)
                }
              >
                <span className="media-shelf__title">{section.title}</span>
                <span className="media-shelf__more">
                  全部
                  <ChevronRight size={15} strokeWidth={2.25} aria-hidden />
                </span>
              </button>
              {section.loading ? (
                <div
                  className="media-shelf__rail media-shelf__rail--skel"
                  aria-hidden
                >
                  {Array.from({ length: 5 }).map((_, i) => (
                    <span key={i} className="drama-card-skel drama-card-skel--rail" />
                  ))}
                </div>
              ) : null}
              {!section.loading && section.error ? (
                <p className="media-shelf__err allow-select">{section.error}</p>
              ) : null}
              {!section.loading && !section.error && section.items.length === 0 ? (
                <p className="media-shelf__err">暂无内容</p>
              ) : null}
              {!section.loading && !section.error && section.items.length > 0 ? (
                <div className="media-shelf__rail">
                  {section.items.slice(0, SHELF_LIMIT).map((card) => (
                    <button
                      key={card.id}
                      type="button"
                      className="drama-card drama-card--rail"
                      onClick={() => onOpen(card)}
                    >
                      <span className="drama-card__cover">
                        <SoftImg src={card.cover} alt="" loading="lazy" />
                        {card.episodeCount > 0 ? (
                          <span className="drama-card__badge">
                            {card.episodeCount}集
                          </span>
                        ) : null}
                      </span>
                      <span className="drama-card__title">{card.title}</span>
                    </button>
                  ))}
                </div>
              ) : null}
            </section>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/* ── 全部（单个榜单，滚动到底自动加载） ── */

function DramaRankBody({
  site,
  group,
  rank,
  onOpen,
}: {
  site: string;
  group: string;
  rank: string;
  onOpen: (card: DramaCard) => void;
}) {
  const [items, setItems] = useState<DramaCard[]>([]);
  const [page, setPage] = useState(1);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');
  const sentinelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
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
  }, [site, group, rank]);

  const loadMore = useCallback(() => {
    if (loadingMore || !hasMore) return;
    const next = page + 1;
    setLoadingMore(true);
    fetchDramaRank(site, group, rank, next)
      .then((data) => {
        setItems((prev) => {
          const seen = new Set(prev.map((item) => item.id));
          return [...prev, ...data.items.filter((item) => !seen.has(item.id))];
        });
        setPage(next);
        setHasMore(Boolean(data.hasMore) && data.items.length > 0);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : '加载更多失败');
      })
      .finally(() => setLoadingMore(false));
  }, [site, group, rank, page, hasMore, loadingMore]);

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

  return (
    <div className="drama-catalog">
      {loading ? (
        <div className="drama-grid">
          {Array.from({ length: 9 }).map((_, i) => (
            <span key={i} className="drama-card-skel" />
          ))}
        </div>
      ) : null}

      {!loading && error && items.length === 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}

      {!loading && !error && items.length === 0 ? (
        <p className="drama-empty">暂无内容</p>
      ) : null}

      {!loading && items.length > 0 ? (
        <div className="drama-grid">
          {items.map((card) => (
            <button
              key={card.id}
              type="button"
              className="drama-card"
              onClick={() => onOpen(card)}
            >
              <span className="drama-card__cover">
                <SoftImg src={card.cover} alt="" loading="lazy" />
                {card.episodeCount > 0 ? (
                  <span className="drama-card__badge">{card.episodeCount}集</span>
                ) : null}
              </span>
              <span className="drama-card__title">{card.title}</span>
            </button>
          ))}
        </div>
      ) : null}

      {!loading && error && items.length > 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}

      {loadingMore ? <p className="drama-rank-more">加载中…</p> : null}
      <div ref={sentinelRef} className="drama-rank-sentinel" aria-hidden />
    </div>
  );
}

/* ── 搜索 ── */

function DramaSearchBody({
  site,
  initialQuery,
  onOpen,
}: {
  site: string;
  initialQuery: string;
  onOpen: (card: DramaCard) => void;
}) {
  const [input, setInput] = useState(initialQuery);
  const [query, setQuery] = useState(initialQuery);
  const [items, setItems] = useState<DramaCard[]>([]);
  const [page, setPage] = useState(1);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(Boolean(initialQuery));
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!query) return;
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
    if (loadingMore || !query) return;
    const next = page + 1;
    setLoadingMore(true);
    setError('');
    fetchDramaSearch(site, query, next)
      .then((data) => {
        setItems((prev) => {
          const seen = new Set(prev.map((item) => item.id));
          return [...prev, ...data.items.filter((item) => !seen.has(item.id))];
        });
        setPage(next);
        setHasMore(data.hasMore);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : '加载更多失败');
      })
      .finally(() => setLoadingMore(false));
  };

  return (
    <div className="drama-catalog">
      <form className="drama-search drama-search--page" onSubmit={submit} role="search">
        <Search size={16} className="drama-search__icon" aria-hidden />
        <input
          className="drama-search__input"
          value={input}
          onChange={(event) => setInput(event.target.value)}
          placeholder="搜索短剧"
          type="search"
          enterKeyHint="search"
          aria-label="搜索短剧"
        />
        <button
          type="submit"
          className="drama-search__submit"
          disabled={!input.trim()}
        >
          搜索
        </button>
      </form>

      {!query ? <p className="drama-empty">输入关键词，搜索短剧</p> : null}

      {loading ? (
        <div className="drama-grid">
          {Array.from({ length: 6 }).map((_, i) => (
            <span key={i} className="drama-card-skel" />
          ))}
        </div>
      ) : null}
      {!loading && error && items.length === 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}
      {!loading && query && !error && items.length === 0 ? (
        <p className="drama-empty">没有找到相关短剧</p>
      ) : null}
      {!loading && items.length > 0 ? (
        <div className="drama-grid">
          {items.map((card) => (
            <button
              key={card.id}
              type="button"
              className="drama-card"
              onClick={() => onOpen(card)}
            >
              <span className="drama-card__cover">
                <SoftImg src={card.cover} alt="" loading="lazy" />
                {card.episodeCount > 0 ? (
                  <span className="drama-card__badge">{card.episodeCount}集</span>
                ) : null}
              </span>
              <span className="drama-card__title">{card.title}</span>
            </button>
          ))}
        </div>
      ) : null}
      {!loading && items.length > 0 && hasMore ? (
        <button
          type="button"
          className="drama-more"
          onClick={loadMore}
          disabled={loadingMore}
        >
          {loadingMore ? '加载中…' : '加载更多'}
        </button>
      ) : null}
      {error && items.length > 0 ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}
    </div>
  );
}

/* ── 详情 + 播放 ── */

function DramaVideo({ src, poster }: { src: string; poster?: string }) {
  const ref = useRef<HTMLVideoElement | null>(null);

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    let hls: Hls | null = null;
    let disposed = false;
    const controller = new AbortController();

    const setup = async () => {
      const nativeHls = video.canPlayType('application/vnd.apple.mpegurl');
      if (nativeHls || !Hls.isSupported()) {
        video.src = src;
        return;
      }
      let isHls = false;
      try {
        // 读第一个数据块判断是不是 HLS 播放列表；MP4 只读一小段就取消。
        const response = await fetch(src, {
          credentials: 'include',
          signal: controller.signal,
        });
        if (/mpegurl/i.test(response.headers.get('content-type') || '')) {
          isHls = true;
        } else if (response.body) {
          const reader = response.body.getReader();
          const { value } = await reader.read();
          if (value) {
            const head = new TextDecoder().decode(
              value.subarray(0, Math.min(value.length, 64)),
            );
            isHls = head.trimStart().startsWith('#EXTM3U');
          }
          await reader.cancel();
        }
      } catch {
        // 探测失败时退回原生播放
      }
      if (disposed) return;
      if (!isHls) {
        video.src = src;
        return;
      }
      const instance = new Hls({ enableWorker: true });
      hls = instance;
      instance.on(Hls.Events.ERROR, (_event, data) => {
        if (!data.fatal || disposed) return;
        instance.destroy();
        hls = null;
        video.src = src;
        void video.play().catch(() => {});
      });
      instance.loadSource(src);
      instance.attachMedia(video);
    };

    void setup();
    return () => {
      disposed = true;
      controller.abort();
      if (hls) hls.destroy();
      video.removeAttribute('src');
      video.load();
    };
  }, [src]);

  return (
    <video
      ref={ref}
      className="drama-player__video"
      poster={poster || undefined}
      controls
      autoPlay
      playsInline
      preload="metadata"
    />
  );
}

function DramaDetailBody({ site, card }: { site: string; card: DramaCard }) {
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

  const episodes = detail?.episodes ?? [];
  const playable = episodes.filter((item) => !item.disabled);
  const title = detail?.title || card.title;
  const cover = detail?.cover || card.cover;
  const description = detail?.description || card.description;

  const play = (episode: DramaEpisode) => setCurrent(episode);

  return (
    <div className="drama-detail">
      <div className="drama-player">
        {current ? (
          <DramaVideo
            key={current.id}
            src={dramaStreamUrl(site, current.id)}
            poster={cover}
          />
        ) : (
          <button
            type="button"
            className="drama-player__poster"
            onClick={() => {
              const first = playable[0];
              if (first) play(first);
            }}
            disabled={loading || playable.length === 0}
          >
            {cover ? <SoftImg src={cover} alt="" /> : null}
            <span className="drama-player__mask" aria-hidden />
            <span className="drama-player__play">
              <Play size={24} strokeWidth={2} aria-hidden />
            </span>
            <span className="drama-player__label">
              {loading ? '加载中…' : playable.length ? '点击播放' : '暂无可播放剧集'}
            </span>
          </button>
        )}
      </div>

      <div className="drama-detail__head">
        <h2 className="drama-detail__title">{title}</h2>
        <p className="drama-detail__meta">
          {detail?.siteName || card.siteName}
          {episodes.length ? ` · 共 ${episodes.length} 集` : ''}
          {current ? ` · 第 ${current.episode} 集` : ''}
        </p>
        {description ? (
          <p className="drama-detail__desc allow-select">{description}</p>
        ) : null}
      </div>

      {!loading && error ? (
        <p className="drama-empty allow-select">{error}</p>
      ) : null}

      {episodes.length > 0 ? (
        <section className="drama-episodes">
          <div className="drama-episodes__head">
            <span>选集</span>
            <span className="drama-episodes__count">{episodes.length}</span>
          </div>
          <div className="drama-episodes__grid">
            {episodes.map((episode) => (
              <button
                key={episode.id}
                type="button"
                className={
                  current?.id === episode.id
                    ? 'drama-episode is-active'
                    : 'drama-episode'
                }
                disabled={episode.disabled}
                onClick={() => play(episode)}
              >
                {episode.episode || episode.title}
              </button>
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}
