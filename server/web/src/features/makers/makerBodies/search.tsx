'use client';

import { useState } from 'react';
import { ChevronRight, Search } from 'lucide-react';
import type {
  MakerEntityKind,
  MakerHit,
  MakerMovie,
  MakerMovieSearchFilter,
  MakerSearchItem,
  MakerSearchType,
} from '@/lib/api/makers';
import {
  useMakerMovieSearch,
  useMakerSearch,
  useMakerTorrents,
} from '../useMakerQueries';
import {
  ActorGrid,
  MakerMovieCard,
  Pager,
  WallSkeleton,
  type OpenActorHandler,
} from './shared';
import { TorrentRow } from './resources';

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
  onOpenMaker,
  onOpenMovie,
  onOpenActor,
  onOpenEntity,
  onOpenList,
}: {
  onOpenMaker: (hit: MakerHit) => void;
  onOpenMovie: (movie: MakerMovie) => void;
  onOpenActor: OpenActorHandler;
  onOpenEntity: (kind: MakerEntityKind, id: string, name: string) => void;
  onOpenList: (list: { id: string; name: string }) => void;
}) {
  const [mode, setMode] = useState<SearchMode>('movie');
  const [draft, setDraft] = useState('');
  const [q, setQ] = useState('');
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
