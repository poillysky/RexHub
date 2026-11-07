'use client';

import { useEffect } from 'react';
import { ChevronRight } from 'lucide-react';
import type { MediaCategoryId, MediaItem, MpListParams } from '@/lib/api';
import { useTabPaneVisible } from '@/shell';
import { MediaPosterCard } from './MediaPosterCard';
import { useMpList } from './useMediaQueries';

function shelfErrorLabel(raw: string): string {
  const s = (raw || '').trim();
  if (!s) return '加载失败';
  if (s.includes('暂时关闭') || s.includes('stability')) return '暂不可用';
  return s;
}

/** MoviePilot 式横滑海报架 */
export function MediaShelf({
  category,
  path,
  params,
  title,
  onOpenAll,
  onOpenItem,
  onLoadError,
}: {
  category?: MediaCategoryId;
  path: string;
  params: MpListParams;
  title: string;
  onOpenAll: () => void;
  onOpenItem: (item: MediaItem) => void;
  onLoadError?: (message: string) => void;
}) {
  const paneVisible = useTabPaneVisible();
  const query = useMpList({ path, params, enabled: paneVisible });
  const items: MediaItem[] = (query.data?.items || []).slice(0, 12);
  const loading = query.isPending;
  const err = query.isError
    ? query.error instanceof Error
      ? query.error.message
      : '加载失败'
    : '';

  // onLoadError 故意不入依赖，避免父组件重渲染反复拉取
  useEffect(() => {
    if (err) onLoadError?.(err);
  }, [err]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <section className="media-shelf">
      <button type="button" className="media-shelf__head" onClick={onOpenAll}>
        <span className="media-shelf__title">{title}</span>
        <span className="media-shelf__more">
          全部
          <ChevronRight size={15} strokeWidth={2.25} aria-hidden />
        </span>
      </button>

      {loading ? (
        <div className="media-shelf__rail media-shelf__rail--skel" aria-hidden>
          {Array.from({ length: 5 }).map((_, i) => (
            <span key={i} className="media-poster-skel" />
          ))}
        </div>
      ) : null}

      {!loading && err ? (
        <p className="media-shelf__err allow-select">{shelfErrorLabel(err)}</p>
      ) : null}

      {!loading && !err && items.length === 0 ? (
        <p className="media-shelf__err">暂无内容</p>
      ) : null}

      {!loading && !err && items.length > 0 ? (
        <div className="media-shelf__rail">
          {items.map((it) => (
            <MediaPosterCard
              key={`${it.source}-${it.id}`}
              item={it}
              category={category}
              size="sm"
              onClick={() => onOpenItem(it)}
            />
          ))}
        </div>
      ) : null}
    </section>
  );
}
