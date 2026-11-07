'use client';

import { AppMsg } from '@/components/ui/AppMsg';
import { ResourceCard } from './ResourceCard';
import { SearchFilters } from './SearchFilters';
import { SearchResultsLoading } from './SearchResultsLoading';
import { ScopeResultList } from './ScopeResultList';
import type { HomeScreenState } from './useHomeScreen';

type Props = {
  h: HomeScreenState;
};

const SOURCE_LABELS: Record<string, string> = {
  bitmagnet: 'Bitmagnet',
  cloudsaver: 'CloudSaver',
  sehuatang: '色花堂',
  avdb: 'AVDB',
};

/** 结果列表区：筛选、提示、错误/空态、卡片列表、无限滚动 / 分页 */
export function HomeResultsBody({ h }: Props) {
  const sourceErrorText = Object.entries(h.scopeSourceErrors)
    .map(([key, value]) => `${SOURCE_LABELS[key] ?? key}：${value}`)
    .join('；');

  function goScopePage(next: number) {
    h.setScopePage(Math.max(1, next));
    h.scrollBodyRef.current?.scrollTo({ top: 0 });
  }

  return (
    <div className="app-body home-search-body" ref={h.scrollBodyRef}>
      {h.msg ? <AppMsg onDismiss={() => h.setMsg('')}>{h.msg}</AppMsg> : null}

      {h.isKeywordSearch ? (
        <SearchFilters
          sortType={h.sortType}
          filterTime={h.filterTime}
          filterSize={h.filterSize}
          showSource
          searchScope={h.searchScope}
          searchSource={h.searchSource}
          onSearchSourceChange={h.onSearchSourceChange}
          onSortType={h.onFilterChange(h.setSortType)}
          onFilterTime={h.onFilterChange(h.setFilterTime)}
          onFilterSize={h.onFilterChange(h.setFilterSize)}
        />
      ) : null}

      {h.activeLoading ? null : <p className="app-hint">{h.hint}</p>}

      {h.activeLoading ? (
        <SearchResultsLoading
          keyword={h.isKeywordSearch ? h.keyword : undefined}
        />
      ) : h.isKeywordSearch ? (
        h.scopeError && h.scopeItems.length === 0 ? (
          <div className="app-error">
            <p>{h.scopeError}</p>
            <div className="app-actions" style={{ justifyContent: 'center' }}>
              <button
                type="button"
                className="app-btn-secondary"
                onClick={h.retrySearch}
              >
                重试
              </button>
            </div>
          </div>
        ) : h.scopeItems.length === 0 ? (
          <div className="app-empty">
            <p>没有匹配结果</p>
            <p className="app-footnote" style={{ marginTop: 8 }}>
              试试更短的关键词，或切换搜索范围
            </p>
          </div>
        ) : (
          <>
            <ScopeResultList
              items={h.scopeItems}
              page={h.scopePage}
              hasMore={h.scopeHasMore}
              loadingMore={h.scopeFetching}
              saveSource={h.searchScope === 'maker' ? 'maker' : 'media'}
              onPrev={() => goScopePage(h.scopePage - 1)}
              onNext={() => goScopePage(h.scopePage + 1)}
              onOpenDetail={h.openScopeDetail}
            />
            {sourceErrorText ? (
              <p className="app-footnote" style={{ marginTop: 8 }}>
                部分来源失败：{sourceErrorText}
              </p>
            ) : null}
          </>
        )
      ) : h.error && h.items.length === 0 ? (
        <div className="app-error">
          <p>{h.error}</p>
          <p className="app-error-hint">请到「更多」检查资源库配置</p>
          <div className="app-actions" style={{ justifyContent: 'center' }}>
            <button
              type="button"
              className="app-btn-secondary"
              onClick={h.retrySearch}
            >
              重试
            </button>
          </div>
        </div>
      ) : h.items.length === 0 ? (
        <div className="app-empty">
          <p>暂无资源</p>
        </div>
      ) : (
        <>
          <div className="bm-result-list">
            {h.items.map((item) => (
              <ResourceCard
                key={item.hash}
                item={item}
                keywords={h.resultKeywords}
                cropRegion={h.searchRegion || undefined}
                onOpen={h.openSehualDetail}
              />
            ))}
          </div>
          <div className="home-infinite">
            <div
              ref={h.sentinelRef}
              className="home-infinite__sentinel"
              aria-hidden
            />
            {h.activeLoadingMore ? (
              <p className="app-loading">加载更多…</p>
            ) : null}
            {!h.activeHasMore ? (
              <p className="home-infinite__end">已全部加载</p>
            ) : null}
          </div>
        </>
      )}
    </div>
  );
}
