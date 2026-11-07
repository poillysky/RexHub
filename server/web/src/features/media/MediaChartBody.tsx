'use client';

import { useState } from 'react';
import type { MediaItem } from '@/lib/api';
import {
  chartItemCategory,
  chartsForTab,
  type MediaHubTab,
} from './mediaUi';
import { MediaPosterCard } from './MediaPosterCard';
import { useMpList } from './useMediaQueries';

/** 由父级用 key 携带 initialChart，切换榜单入口时整体重挂载，无需 effect 同步 */
export function MediaChartBody({
  tab,
  initialChart,
  onOpen,
}: {
  tab: MediaHubTab;
  initialChart?: string;
  onOpen: (item: MediaItem) => void;
}) {
  const charts = chartsForTab(tab);
  const [page, setPage] = useState(1);

  // 榜单由入口带入（货架「查看全部」/详情返回），不再在页内切换
  const active = charts.find((c) => c.id === initialChart) || charts[0];
  const query = useMpList({
    path: active?.path || '',
    params: { ...(active?.params || {}), page },
  });
  const items: MediaItem[] = query.data?.items || [];
  // MoviePilot 推荐/探索列表不返回总页数，用「本页是否满整页」判断是否还有下一页
  const pageSize = Number(active?.params.count || 20);
  const hasNext = items.length >= pageSize;
  // 翻页时 placeholderData 仍是上一页，显示骨架避免误以为已加载完成
  const loading = query.isPending || query.isPlaceholderData;
  const err = query.isError
    ? query.error instanceof Error
      ? query.error.message
      : '加载失败'
    : '';

  return (
    <div className="media-chart">
      {loading ? (
        <div className="media-wall media-wall--skel" aria-hidden>
          {Array.from({ length: 9 }).map((_, i) => (
            <span key={i} className="media-poster-skel media-poster-skel--wall" />
          ))}
        </div>
      ) : null}

      {!loading && err ? (
        <p className="media-empty allow-select">{err}</p>
      ) : null}
      {!loading && !err && items.length === 0 ? (
        <p className="media-empty">暂无条目</p>
      ) : null}

      {!loading && !err && items.length > 0 ? (
        <div className="media-wall">
          {items.map((it) => (
            <MediaPosterCard
              key={`${it.source}-${it.id}`}
              item={it}
              category={chartItemCategory(tab, it)}
              size="md"
              onClick={() => onOpen(it)}
            />
          ))}
        </div>
      ) : null}

      {!loading && !err && (page > 1 || hasNext) ? (
        <div className="media-chart__pager">
          <button
            type="button"
            className="media-chart__page-btn"
            disabled={page <= 1}
            onClick={() => setPage((p) => Math.max(1, p - 1))}
          >
            上一页
          </button>
          <span className="media-chart__page-meta">第 {page} 页</span>
          <button
            type="button"
            className="media-chart__page-btn"
            disabled={!hasNext}
            onClick={() => setPage((p) => p + 1)}
          >
            下一页
          </button>
        </div>
      ) : null}
    </div>
  );
}
