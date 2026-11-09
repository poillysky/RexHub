'use client';

/**
 * 单个插件的「内容」页：读取该 addon 的 catalog，点条目直接用它自己的片源播放。
 *
 * 覆盖 Stremio 协议的四类资源：
 * - catalog：目录 + search / genre / skip 额外参数；
 * - meta：剧集/番剧分集列表（选集）；
 * - stream：本插件自己的片源（类型原样透传给上游）；
 * - subtitles：播放时自动聚合已启用字幕插件。
 * 插件没有 stream 资源时，可一键改用「全部已启用插件」聚合。
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { LoaderCircle, RefreshCw, Search } from 'lucide-react';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { AppPush } from '@/components/ui/AppPush';
import { SoftImg } from '@/components/SoftImg';
import { StreamPlayModal } from '@/features/media/StreamPlayModal';
import {
  fetchMediaStreams,
  fetchMediaSubtitles,
  getAddonCatalogItems,
  getAddonCatalogs,
  getAddonMeta,
  getAddonStreams,
  type AddonCatalogEntry,
  type AddonMeta,
  type AddonVideo,
  type MediaStream,
  type MediaSubtitle,
  type StremioAddon,
} from '@/lib/api';

function addonName(addon: StremioAddon) {
  return addon.manifest?.name || addon.slug;
}

/** meta 视频 ID 已带季集（tt123:1:1）时，streams 不能再补后缀。 */
function pad(value: number) {
  return value < 10 ? `0${value}` : String(value);
}

/** 目录能否在进入时直接拉取：必填 search 或无法自动补齐的参数需要用户先操作。 */
function autoLoadable(entry: AddonCatalogEntry) {
  const required = entry.extraRequired.filter((key) => key !== 'skip');
  if (required.includes('search')) return false;
  if (required.includes('genre') && entry.genres.length === 0) return false;
  return required.every((key) => ['genre', 'year'].includes(key));
}

type PlayTarget = {
  item: AddonMeta;
  type: string;
  streamId: string;
  season: number;
  episode: number;
  composite: boolean;
};

/** 只有 IMDb 条目能跨插件聚合；自定义类型（trakt/mixed/collections…）只要 ID 是 tt 也可以。 */
function aggregatable(target: PlayTarget) {
  return target.streamId.split(':')[0].startsWith('tt');
}

/** 聚合接口只认 movie/tv 两种类型。 */
function aggregateKind(type: string) {
  return type === 'series' || type === 'tv' || type === 'anime' ? 'tv' : 'movie';
}

export function AddonContent({
  addon,
  onBack,
}: {
  addon: StremioAddon;
  onBack: () => void;
}) {
  const title = addonName(addon);
  const [catalogs, setCatalogs] = useState<AddonCatalogEntry[]>([]);
  const [resources, setResources] = useState<string[]>([]);
  const [activeKey, setActiveKey] = useState('');
  const [items, setItems] = useState<AddonMeta[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const [genre, setGenre] = useState('');

  const [picked, setPicked] = useState<PlayTarget | null>(null);
  const [streams, setStreams] = useState<MediaStream[]>([]);
  const [streamTotal, setStreamTotal] = useState(0);
  const [streamLoading, setStreamLoading] = useState(false);
  const [streamError, setStreamError] = useState('');
  const [streamReason, setStreamReason] = useState('');
  const [aggregated, setAggregated] = useState(false);
  const [attempted, setAttempted] = useState(false);
  const [subtitles, setSubtitles] = useState<MediaSubtitle[]>([]);
  const [subtitleLoading, setSubtitleLoading] = useState(false);
  const [subtitleReason, setSubtitleReason] = useState('');

  const [episodeFor, setEpisodeFor] = useState<AddonMeta | null>(null);
  const [episodeType, setEpisodeType] = useState('');
  const [episodeVideos, setEpisodeVideos] = useState<AddonVideo[]>([]);
  const [episodeLoading, setEpisodeLoading] = useState(false);
  const [season, setSeason] = useState(1);
  const requestSeq = useRef(0);
  const catalogSeq = useRef(0);

  const active = catalogs.find((entry) => entry.key === activeKey) || null;
  const hasStream = resources.includes('stream');
  const hasMeta = resources.includes('meta');

  const loadCatalog = useCallback(
    async (
      entry: AddonCatalogEntry,
      opts?: { genre?: string; search?: string; skip?: number; append?: boolean },
    ) => {
      const append = Boolean(opts?.append);
      const seq = append ? catalogSeq.current : ++catalogSeq.current;
      if (append) {
        setLoadingMore(true);
      } else {
        setLoading(true);
        setLoadingMore(false);
        setError('');
        setItems([]);
        setHasMore(false);
      }
      try {
        const page = await getAddonCatalogItems(addon.slug, {
          mediaType: entry.type,
          id: entry.id,
          genre: opts?.genre || undefined,
          search: opts?.search || undefined,
          skip: opts?.skip || undefined,
        });
        if (seq !== catalogSeq.current) return;
        setItems((prev) => {
          if (!append) return page.items;
          const seen = new Set(prev.map((item) => item.id));
          return [...prev, ...page.items.filter((item) => !seen.has(item.id))];
        });
        setHasMore(Boolean(page.hasMore));
      } catch (exc) {
        if (seq !== catalogSeq.current) return;
        if (!append) setError((exc as Error)?.message || '目录读取失败');
      } finally {
        if (seq === catalogSeq.current) {
          if (append) setLoadingMore(false);
          else setLoading(false);
        }
      }
    },
    [addon.slug],
  );

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError('');
    void getAddonCatalogs(addon.slug)
      .then((data) => {
        if (cancelled) return;
        setCatalogs(data.catalogs);
        setResources(
          data.resources?.length
            ? data.resources
            : [
                ...(data.hasStream ? ['stream'] : []),
                ...(data.hasMeta ? ['meta'] : []),
                ...(data.hasSubtitles ? ['subtitles'] : []),
              ],
        );
        // 优先选不需要必填 extra 的目录
        const first =
          data.catalogs.find((entry) => entry.extraRequired.length === 0) ||
          data.catalogs.find((entry) => autoLoadable(entry)) ||
          data.catalogs[0];
        if (first) {
          setActiveKey(first.key);
          const nextGenre = first.extraRequired.includes('genre') ? first.genres[0] || '' : '';
          setGenre(nextGenre);
          if (autoLoadable(first)) {
            void loadCatalog(first, { genre: nextGenre });
          } else {
            setLoading(false);
          }
        } else {
          setLoading(false);
        }
      })
      .catch((exc: Error) => {
        if (cancelled) return;
        setError(exc?.message || '插件目录读取失败');
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [addon.slug, loadCatalog]);

  function pickCatalog(entry: AddonCatalogEntry) {
    if (entry.key === activeKey) return;
    catalogSeq.current += 1;
    setActiveKey(entry.key);
    setQuery('');
    const nextGenre = entry.extraRequired.includes('genre') ? entry.genres[0] || '' : '';
    setGenre(nextGenre);
    if (autoLoadable(entry)) {
      void loadCatalog(entry, { genre: nextGenre });
    } else {
      setItems([]);
      setHasMore(false);
      setLoadingMore(false);
      setError('');
      setLoading(false);
    }
  }

  function reloadFilters(nextGenre = genre, nextQuery = query) {
    if (!active) return;
    void loadCatalog(active, { genre: nextGenre, search: nextQuery.trim() });
  }

  function loadMore() {
    if (!active || loadingMore) return;
    void loadCatalog(active, { genre, search: query.trim(), skip: items.length, append: true });
  }

  const loadAggregate = useCallback(async (target: PlayTarget) => {
    const seq = requestSeq.current;
    setAggregated(true);
    setStreamLoading(true);
    setStreamError('');
    setStreamReason('');
    setStreams([]);
    setStreamTotal(0);
    const baseId = target.streamId.split(':')[0];
    if (!baseId.startsWith('tt')) {
      setStreamReason('该条目不是 IMDb ID，无法跨插件聚合片源');
      setStreamLoading(false);
      return;
    }
    const kind = aggregateKind(target.type);
    const seasonNo = target.season || (kind === 'tv' ? 1 : 0);
    const episodeNo = target.episode || (kind === 'tv' ? 1 : 0);
    try {
      const data = await fetchMediaStreams({
        id: baseId,
        mediaType: kind,
        season: seasonNo,
        episode: episodeNo,
      });
      if (seq !== requestSeq.current) return;
      setStreams(data.streams);
      setStreamTotal(data.total);
      setStreamReason(data.reason);
    } catch (exc) {
      if (seq !== requestSeq.current) return;
      setStreamError((exc as Error)?.message || '片源拉取失败');
    } finally {
      if (seq === requestSeq.current) setStreamLoading(false);
    }
  }, []);

  const loadSubtitles = useCallback(async (target: PlayTarget, seq: number) => {
    const baseId = target.streamId.split(':')[0];
    setSubtitles([]);
    setSubtitleReason('');
    if (!baseId.startsWith('tt')) {
      setSubtitleLoading(false);
      setSubtitleReason('该条目不是 IMDb ID，暂无社区字幕');
      return;
    }
    setSubtitleLoading(true);
    try {
      const data = await fetchMediaSubtitles({
        id: baseId,
        mediaType: target.type === 'movie' ? 'movie' : 'series',
        season: target.season,
        episode: target.episode,
      });
      if (seq !== requestSeq.current) return;
      setSubtitles(data.subtitles);
      setSubtitleReason(data.reason);
    } catch (exc) {
      if (seq !== requestSeq.current) return;
      setSubtitleReason((exc as Error)?.message || '字幕拉取失败');
    } finally {
      if (seq === requestSeq.current) setSubtitleLoading(false);
    }
  }, []);

  const playTarget = useCallback(
    async (target: PlayTarget) => {
      const seq = ++requestSeq.current;
      setPicked(target);
      setStreams([]);
      setStreamTotal(0);
      setStreamError('');
      setStreamReason('');
      setAggregated(false);
      setAttempted(true);
      void loadSubtitles(target, seq);
      if (!hasStream) {
        if (aggregatable(target)) {
          void loadAggregate(target);
        } else {
          setStreamReason('该插件没有片源，且该条目不是 IMDb ID，无法跨插件聚合。');
          setStreamLoading(false);
        }
        return;
      }
      setStreamLoading(true);
      let fellBack = false;
      try {
        const data = await getAddonStreams(addon.slug, {
          mediaType: target.type,
          id: target.streamId,
          season: target.composite ? 0 : target.season,
          episode: target.composite ? 0 : target.episode,
        });
        if (seq !== requestSeq.current) return;
        if (data.total === 0 && aggregatable(target)) {
          // 插件声明了 stream 但没有此条目的片源：自动回退到跨插件聚合
          fellBack = true;
          void loadAggregate(target);
          return;
        }
        setStreams(data.streams);
        setStreamTotal(data.total);
        setStreamReason(data.reason);
      } catch (exc) {
        if (seq !== requestSeq.current) return;
        if (aggregatable(target)) {
          // 插件片源接口异常时仍可尝试跨插件聚合
          fellBack = true;
          void loadAggregate(target);
          return;
        }
        setStreamError((exc as Error)?.message || '该插件的片源读取失败');
      } finally {
        if (seq === requestSeq.current && !fellBack) setStreamLoading(false);
      }
    },
    [addon.slug, hasStream, loadAggregate, loadSubtitles],
  );

  const openItem = useCallback(
    async (item: AddonMeta) => {
      const itemType = item.type || active?.type || 'movie';
      const base: PlayTarget = {
        item,
        type: itemType,
        streamId: item.id,
        season: 0,
        episode: 0,
        composite: false,
      };
      // 剧集/番剧优先取 meta 分集；失败或没有分集时退回条目 ID（后端会补默认集）
      if (hasMeta && (itemType === 'series' || itemType === 'anime')) {
        setEpisodeFor(item);
        setEpisodeType(itemType);
        setEpisodeVideos([]);
        setEpisodeLoading(true);
        try {
          const data = await getAddonMeta(addon.slug, { mediaType: itemType, id: item.id });
          const videos = data.videos.filter((video) => video.episode > 0);
          if (videos.length === 0) {
            setEpisodeFor(null);
            void playTarget(base);
          } else {
            setEpisodeVideos(videos);
            setSeason(videos[0]?.season || 1);
          }
        } catch {
          // 没有 meta 或上游失败时退回条目 ID，由后端补默认集
          setEpisodeFor(null);
          void playTarget(base);
        } finally {
          setEpisodeLoading(false);
        }
        return;
      }
      void playTarget(base);
    },
    [active, addon.slug, hasMeta, playTarget],
  );

  function pickEpisode(video: AddonVideo) {
    if (!episodeFor) return;
    // meta 里的分集 ID 有的已带季集（tt123:1:1），有的就是完整流 ID
    // （hmm-xxx-episode-1）：统一用分集 ID，后端会按需再补季集后缀。
    const composite = video.id.includes(':');
    setEpisodeFor(null);
    void playTarget({
      item: {
        ...episodeFor,
        name: `${episodeFor.name} · S${pad(video.season || season)}E${pad(video.episode)}`,
      },
      type: episodeType,
      streamId: video.id,
      season: video.season || season,
      episode: video.episode,
      composite,
    });
  }

  const seasons = Array.from(
    new Set(episodeVideos.map((video) => video.season || 1)),
  ).sort((a, b) => a - b);
  const currentSeason = seasons.includes(season) ? season : seasons[0] || 1;
  const seasonEpisodes = episodeVideos.filter((video) => (video.season || 1) === currentSeason);

  return (
    <AppPush title={title} onBack={onBack} bodyClassName="stremio-page">
      {catalogs.length > 1 ? (
        <div className="media-source-switch addon-cat-tabs" role="tablist" aria-label="插件目录">
          {catalogs.map((entry) => (
            <button
              key={entry.key}
              type="button"
              role="tab"
              aria-selected={entry.key === activeKey}
              className={`media-source-switch__btn${entry.key === activeKey ? ' is-active' : ''}`}
              onClick={() => pickCatalog(entry)}
            >
              {entry.name || entry.type || '内容'}
            </button>
          ))}
        </div>
      ) : null}

      {active && active.hasSearch ? (
        <form
          className="addon-filter"
          onSubmit={(event) => {
            event.preventDefault();
            reloadFilters();
          }}
        >
          <Search size={15} strokeWidth={2.2} aria-hidden />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={`在「${active.name}」中搜索`}
            enterKeyHint="search"
          />
          {query ? (
            <button
              type="button"
              className="addon-filter__clear"
              onClick={() => {
                setQuery('');
                reloadFilters(genre, '');
              }}
            >
              清除
            </button>
          ) : null}
        </form>
      ) : null}

      {active && active.hasGenre && active.genres.length > 0 ? (
        <div className="addon-chip-row" role="group" aria-label="题材筛选">
          {['', ...active.genres].map((value) => (
            <button
              key={value || '__all__'}
              type="button"
              className={`addon-chip${genre === value ? ' is-active' : ''}`}
              onClick={() => {
                setGenre(value);
                reloadFilters(value, query);
              }}
            >
              {value || '全部'}
            </button>
          ))}
        </div>
      ) : null}

      {loading ? (
        <div className="addon-content__state">
          <LoaderCircle size={22} strokeWidth={2.2} className="media-detail__cta-spin" />
          <span>正在读取插件目录…</span>
        </div>
      ) : error ? (
        <div className="addon-content__state">
          <span className="stream-modal__error">{error}</span>
          {active ? (
            <button
              type="button"
              className="stream-modal__plain"
              onClick={() => reloadFilters()}
            >
              <RefreshCw size={14} strokeWidth={2.3} aria-hidden />
              重试
            </button>
          ) : null}
        </div>
      ) : !active ? (
        <div className="addon-content__state">
          <span>该插件没有提供可浏览的目录</span>
          <span className="stream-modal__hint">
            {hasStream
              ? '这是纯片源插件：请到影视详情页点「播放」，它会在聚合结果里出现。'
              : resources.includes('subtitles')
                ? '这是字幕插件：播放任意影片时会自动匹配它提供的字幕。'
                : resources.includes('meta')
                  ? '这是元数据插件：打开条目详情时会自动使用它的信息。'
                  : '该插件没有声明任何可用的资源。'}
          </span>
        </div>
      ) : items.length === 0 ? (
        <div className="addon-content__state">
          <span>
            {active.extraRequired.includes('search') && !query
              ? `「${active.name}」需要先搜索`
              : `「${active.name}」暂时没有返回条目`}
          </span>
          <span className="stream-modal__hint">
            {active.extraRequired.includes('search') && !query
              ? '在上方输入关键词后回车，即可读取该目录。'
              : query
                ? `没有搜到「${query}」，换个关键词试试。`
                : active.extraRequired.length
                  ? `该目录需要额外参数：${active.extraRequired.join('、')}，当前插件未提供可选项。`
                  : '换一个目录或稍后再试。'}
          </span>
          {!active.extraRequired.includes('search') || query ? (
            <button type="button" className="stream-modal__plain" onClick={() => reloadFilters()}>
              <RefreshCw size={14} strokeWidth={2.3} aria-hidden />
              重试
            </button>
          ) : null}
        </div>
      ) : (
        <>
          <p className="addon-content__hint">
            {active.type || '内容'} · 共 {items.length} 条
            {hasStream ? ' · 点开可直接播放' : ' · 该插件无片源，点开将聚合全部插件'}
          </p>
          <div className="addon-content-grid">
            {items.map((item) => (
              <button
                key={item.id}
                type="button"
                className="media-poster media-poster--md addon-content-card"
                onClick={() => void openItem(item)}
              >
                <span className="media-poster__frame">
                  {item.poster ? (
                    <SoftImg src={item.poster} alt="" loading="lazy" />
                  ) : (
                    <span className="media-poster__ph">{item.name.slice(0, 1)}</span>
                  )}
                  {item.rating ? (
                    <span className="media-poster__score">{item.rating}</span>
                  ) : null}
                </span>
                <span className="media-poster__caption">
                  <span className="media-poster__title">{item.name}</span>
                </span>
              </button>
            ))}
          </div>
          {hasMore && active.hasSkip ? (
            <button
              type="button"
              className="addon-more"
              disabled={loadingMore}
              onClick={loadMore}
            >
              {loadingMore ? (
                <LoaderCircle size={15} strokeWidth={2.2} className="media-detail__cta-spin" />
              ) : null}
              {loadingMore ? '正在加载…' : '加载更多'}
            </button>
          ) : null}
        </>
      )}

      <AppCenterModal
        open={Boolean(episodeFor)}
        title={episodeFor ? `选集 · ${episodeFor.name}` : '选集'}
        onClose={() => setEpisodeFor(null)}
      >
        {episodeLoading ? (
          <div className="addon-content__state">
            <LoaderCircle size={22} strokeWidth={2.2} className="media-detail__cta-spin" />
            <span>正在读取分集…</span>
          </div>
        ) : (
          <>
            {seasons.length > 1 ? (
              <div className="addon-chip-row" role="group" aria-label="季">
                {seasons.map((value) => (
                  <button
                    key={value}
                    type="button"
                    className={`addon-chip${currentSeason === value ? ' is-active' : ''}`}
                    onClick={() => setSeason(value)}
                  >
                    第 {value} 季
                  </button>
                ))}
              </div>
            ) : null}
            <div className="addon-episode-grid">
              {seasonEpisodes.map((video) => (
                <button
                  key={video.id}
                  type="button"
                  className="addon-episode"
                  onClick={() => pickEpisode(video)}
                >
                  <span className="addon-episode__no">E{pad(video.episode)}</span>
                  <span className="addon-episode__name">
                    {video.name || `第 ${video.episode} 集`}
                  </span>
                </button>
              ))}
            </div>
            {seasonEpisodes.length === 0 ? (
              <p className="stream-modal__hint">该季没有分集。</p>
            ) : null}
          </>
        )}
      </AppCenterModal>

      <StreamPlayModal
        open={Boolean(picked)}
        title={picked?.item.name || '片源'}
        streams={streams}
        total={streamTotal}
        reason={streamReason}
        loading={streamLoading}
        error={streamError}
        subtitles={subtitles}
        subtitleLoading={subtitleLoading}
        subtitleReason={subtitleReason}
        hint={
          aggregated
            ? '已改为从全部已启用插件聚合片源。'
            : hasStream
              ? `片源仅来自当前插件（${picked?.type || 'movie'}）。`
              : '当前插件没有片源，已从全部插件聚合。'
        }
        footerHint={`片源来自插件 ${title}，版权内容请自行判断。`}
        onRetry={() => {
          if (!picked) return;
          if (aggregated) void loadAggregate(picked);
          else void playTarget(picked);
        }}
        onNeedAggregate={
          attempted && !aggregated && picked && aggregatable(picked)
            ? () => void loadAggregate(picked)
            : undefined
        }
        onClose={() => {
          requestSeq.current += 1;
          setPicked(null);
          setAttempted(false);
          setSubtitles([]);
          setSubtitleReason('');
        }}
      />
    </AppPush>
  );
}
