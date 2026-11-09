'use client';

import { ChevronRight, Search, SlidersHorizontal } from 'lucide-react';
import { LazyImg } from '@/components/SoftImg';
import type { DramaCard } from '@/lib/api';
import { SHELF_LIMIT, useDramaCatalog } from './useDramaScreen';

export function DramaCatalogBody({
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
  const {
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
  } = useDramaCatalog(site, onSearch);

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
                id={`drama-tab-${item.id}`}
                aria-controls="drama-panel"
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
            aria-controls="drama-filter-panel"
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
        <div className="drama-filter-panel" id="drama-filter-panel">
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
                  id={`drama-filter-tab-${index}`}
                  aria-controls="drama-filter-options"
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
          <div className="drama-filter-row" id="drama-filter-options">
            {filterItems.map((option) => (
              <button
                key={option.id || 'all'}
                type="button"
                aria-pressed={option.id === filterId}
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
        <div
          className="drama-shelves"
          id="drama-panel"
          role="tabpanel"
          aria-labelledby={group ? `drama-tab-${group}` : undefined}
        >
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
                        <LazyImg src={card.cover} alt="" loading="lazy" />
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
