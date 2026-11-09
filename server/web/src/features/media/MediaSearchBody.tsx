'use client';

import { useRef, useState } from 'react';
import { Search } from 'lucide-react';
import type { MediaItem, MediaSourceId } from '@/lib/api';
import { SEARCH_KEYWORD_LENGTH_MIN } from '@/config/search';
import { MediaPosterCard } from './MediaPosterCard';
import { useMediaSearch } from './useMediaQueries';

export function MediaSearchBody({
  source,
  initialQuery = '',
  initialPage = 1,
  onOpen,
  onStateChange,
}: {
  source: MediaSourceId;
  initialQuery?: string;
  /** 从详情返回时恢复页码 */
  initialPage?: number;
  onOpen: (item: MediaItem) => void;
  /** 把关键词与页码回传给页面栈，返回时可原样恢复 */
  onStateChange?: (state: { q: string; page: number }) => void;
}) {
  const [draft, setDraft] = useState(initialQuery);
  const [query, setQuery] = useState(initialQuery.trim());
  const [page, setPage] = useState(() => Math.max(1, initialPage));
  const [formErr, setFormErr] = useState('');
  const rootRef = useRef<HTMLDivElement>(null);

  const result = useMediaSearch({
    source,
    q: query,
    page,
    minLength: SEARCH_KEYWORD_LENGTH_MIN,
  });
  const items: MediaItem[] = result.data?.items || [];
  const terms = Array.isArray(result.data?.terms) ? result.data.terms : [];
  const hasMore = Boolean(result.data?.hasMore);
  // query 为空时查询是 disabled，isPending 会一直为 true，不能当成加载中
  const loading = Boolean(query) && (result.isPending || result.isPlaceholderData);
  const rawErr = result.isError
    ? result.error instanceof Error
      ? result.error.message
      : '搜索失败'
    : '';
  const err = rawErr || formErr;

  function submit() {
    const next = draft.trim();
    if (next.length < SEARCH_KEYWORD_LENGTH_MIN) {
      setFormErr(`请输入至少 ${SEARCH_KEYWORD_LENGTH_MIN} 个字`);
      return;
    }
    setFormErr('');
    setPage(1);
    setQuery(next);
    onStateChange?.({ q: next, page: 1 });
    rootRef.current?.closest('.app-push__body')?.scrollTo({ top: 0 });
  }

  function goPage(next: number) {
    setPage(next);
    onStateChange?.({ q: query, page: next });
    rootRef.current?.closest('.app-push__body')?.scrollTo({ top: 0 });
  }

  const multi = terms.length > 1;

  return (
    <div className="media-search" ref={rootRef}>
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
            placeholder="片名… 多部用逗号/顿号分隔"
            aria-label="搜索片名"
            enterKeyHint="search"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
          />
        </label>
        <button type="submit" className="media-search__go">
          搜索
        </button>
      </form>

      {!query ? (
        <div className="media-empty">
          输入片名、演员或关键词
          <p className="media-empty__hint">
            多片名请用逗号、顿号分隔；英文片名含空格时也请用逗号
          </p>
        </div>
      ) : null}

      {!loading && !err && multi ? (
        <p className="media-empty__hint media-search__terms allow-select">
          已按 {terms.length} 个片名分别搜索并合并
        </p>
      ) : null}

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
      {!loading && !err && query && items.length === 0 ? (
        <p className="media-empty">没有匹配结果</p>
      ) : null}

      {!loading && !err && items.length > 0 ? (
        <div className="media-wall">
          {items.map((it) => (
            <MediaPosterCard
              key={`${it.source}-${it.id}`}
              item={it}
              size="md"
              onClick={() => onOpen(it)}
            />
          ))}
        </div>
      ) : null}

      {!loading && !multi && (page > 1 || (!err && hasMore)) ? (
        <div className="media-chart__pager">
          <button
            type="button"
            className="media-chart__page-btn"
            disabled={page <= 1}
            onClick={() => goPage(Math.max(1, page - 1))}
          >
            上一页
          </button>
          <span className="media-chart__page-meta">第 {page} 页</span>
          <button
            type="button"
            className="media-chart__page-btn"
            disabled={!hasMore || Boolean(err)}
            onClick={() => goPage(page + 1)}
          >
            下一页
          </button>
        </div>
      ) : null}
    </div>
  );
}
