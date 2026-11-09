'use client';

import { useEffect, useRef, useState } from 'react';
import type { MakerCategoryId, MakerMovie, MakerTag } from '@/lib/api/makers';
import { useMakerBrowse, useMakerTags } from '../useMakerQueries';
import { MakerMovieCard, Pager, WallSkeleton } from './shared';

/* ── 分类浏览（标签） ─────────────────────────────── */

/** 单选组：基本 / 年份 / 月份 / 时长 */
const SINGLE_GROUPS = new Set(['main', 'year', 'month', 'duration']);

/** 分类浏览的分组顺序（对齐 AVDB / JavDB 标准筛选面板） */
const TAG_GROUP_ORDER = [
  'main',
  'year',
  'subject',
  'role',
  'cloth',
  'body',
  'behavior',
  'play_method',
  'category',
  'duration',
];

/** 未列出的分组（其他 / 场景 / 标签）排在「时长」之前 */
function tagGroupRank(id: string): number {
  const i = TAG_GROUP_ORDER.indexOf(id);
  return i < 0 ? TAG_GROUP_ORDER.length - 1 : i;
}

/** 「资源」组：main 组里的资源类标签，浏览时走 main_filter */
const RESOURCE_TAGS: MakerTag[] = [
  { id: 'p', name: '可播放' },
  { id: 'm', name: '可下载' },
  { id: 'c', name: '有字幕' },
];

/** 「类型」组：切换内容类别 */
const TYPE_TAGS: MakerTag[] = [
  { id: '0', name: '有码' },
  { id: '1', name: '无码' },
  { id: '2', name: '欧美' },
  { id: '3', name: 'FC2' },
  { id: '4', name: '动漫' },
];

type TagRow = {
  key: string;
  name: string;
  tags: MakerTag[];
  kind: 'resource' | 'type' | 'tag';
  /** 浏览页使用的 group 参数（type 组不跳浏览页） */
  browseGroup?: string;
  single: boolean;
};

type TagFilter = { group: string; tagId: string; tagIds?: string[] };

const ALL_FILTER: TagFilter = { group: '', tagId: '' };

/** 单行分组：按可用宽度自动缩减 chip 数量，超出部分「更多」展开 */
function TagRowView({
  row,
  category,
  active,
  expanded,
  onOpenAll,
  onToggleExpanded,
  onSelectCategory,
  onPickSingle,
  onToggleMulti,
}: {
  row: TagRow;
  category: MakerCategoryId;
  active: TagFilter;
  expanded: boolean;
  onOpenAll: () => void;
  onToggleExpanded: () => void;
  onSelectCategory: (category: MakerCategoryId) => void;
  onPickSingle: (group: string, tag: MakerTag) => void;
  onToggleMulti: (group: string, tag: MakerTag) => void;
}) {
  const rowRef = useRef<HTMLDivElement | null>(null);
  const [visible, setVisible] = useState<number | null>(null);
  const [overflow, setOverflow] = useState(false);

  const group = row.browseGroup || 'main';
  const allActive =
    row.kind === 'type' ? category === '0' : !(active.group === group);

  const chips: Array<{
    key: string;
    name: string;
    active: boolean;
    onClick: () => void;
  }> = [
    { key: '__all', name: '全部', active: allActive, onClick: onOpenAll },
    ...row.tags.map((tag) => {
      if (row.kind === 'type') {
        return {
          key: tag.id,
          name: tag.name,
          active: tag.id === category,
          onClick: () => onSelectCategory(tag.id as MakerCategoryId),
        };
      }
      if (row.single) {
        return {
          key: tag.id,
          name: tag.name,
          active: active.group === group && active.tagId === tag.id,
          onClick: () => onPickSingle(group, tag),
        };
      }
      return {
        key: tag.id,
        name: tag.name,
        active: active.group === row.key && (active.tagIds || []).includes(tag.id),
        onClick: () => onToggleMulti(row.key, tag),
      };
    }),
  ];

  useEffect(() => {
    if (expanded) return;
    const el = rowRef.current;
    if (!el) return;
    const measure = () => {
      const box = el.getBoundingClientRect();
      const items = Array.from(el.children) as HTMLElement[];
      let n = 0;
      for (const item of items) {
        if (item.getBoundingClientRect().right <= box.right + 1) n += 1;
        else break;
      }
      setVisible(n);
      setOverflow(n < items.length);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [expanded, chips.length]);

  const hiddenFrom = !expanded && visible != null ? visible : Infinity;

  return (
    <section className="maker-tags__cat">
      <h3 className="maker-tags__label">{row.name}</h3>
      <div className="maker-tags__row" data-expanded={expanded ? '' : undefined}>
        <div className="maker-chip-row" ref={rowRef}>
          {chips.map((chip, i) => {
            const hidden = i >= hiddenFrom;
            return (
              <button
                key={chip.key}
                type="button"
                className={chip.active ? 'maker-chip is-active' : 'maker-chip'}
                style={hidden ? { visibility: 'hidden' } : undefined}
                aria-hidden={hidden || undefined}
                aria-pressed={chip.active}
                tabIndex={hidden ? -1 : undefined}
                onClick={chip.onClick}
              >
                {chip.name}
              </button>
            );
          })}
        </div>
        {overflow || expanded ? (
          <button
            type="button"
            className="maker-tags__more"
            onClick={onToggleExpanded}
          >
            {expanded ? '收起' : '更多'}
          </button>
        ) : null}
      </div>
    </section>
  );
}

export function MakerTagsBody({
  category,
  onSelectCategory,
  onOpenMovie,
}: {
  category: MakerCategoryId;
  /** 「类型」组：切换类别 */
  onSelectCategory: (category: MakerCategoryId) => void;
  /** 点击影片封面打开详情 */
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const { data, isLoading, error } = useMakerTags(category);
  // 切换分类时重置筛选与分页：状态带上分类指纹，旧值自然失效
  const [view, setView] = useState<{
    category: MakerCategoryId;
    filter: TagFilter;
    page: number;
  }>({ category, filter: ALL_FILTER, page: 1 });
  const stale = view.category !== category;
  const filter = stale ? ALL_FILTER : view.filter;
  const page = stale ? 1 : view.page;
  const setPage = (next: number) => setView({ category, filter, page: next });
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const active = filter;

  const browse = useMakerBrowse(
    category,
    active.group,
    active.tagId,
    '',
    page,
    active.tagIds,
  );
  const items = browse.data?.items || [];
  const hasMore = !!browse.data?.hasMore;
  const listLoading = browse.isPending || browse.isPlaceholderData;
  const browseErr =
    browse.error instanceof Error
      ? browse.error.message
      : browse.error
        ? '加载失败'
        : '';

  const apply = (next: TagFilter) => {
    setView({ category, filter: next, page: 1 });
  };
  const reset = () => apply(ALL_FILTER);

  const toggleExpanded = (key: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const pickSingle = (group: string, tag: MakerTag) => {
    if (active.group === group && active.tagId === tag.id) reset();
    else apply({ group, tagId: tag.id });
  };

  const toggleMulti = (group: string, tag: MakerTag) => {
    const prevIds = active.group === group ? active.tagIds || [] : [];
    const ids = prevIds.includes(tag.id)
      ? prevIds.filter((id) => id !== tag.id)
      : [...prevIds, tag.id];
    if (ids.length === 0) reset();
    else apply({ group, tagId: '', tagIds: ids });
  };

  const rows: TagRow[] = [
    {
      key: 'resource',
      name: '资源',
      tags: RESOURCE_TAGS,
      kind: 'resource',
      browseGroup: 'main',
      single: true,
    },
    { key: 'type', name: '类型', tags: TYPE_TAGS, kind: 'type', single: true },
    ...(data?.categories || [])
      .filter((c) => c.id !== 'month')
      .slice()
      .sort((a, b) => tagGroupRank(a.id) - tagGroupRank(b.id))
      .map<TagRow>((c) => ({
        key: c.id,
        name: c.name,
        tags: c.tags,
        kind: 'tag',
        browseGroup: c.id,
        single: SINGLE_GROUPS.has(c.id),
      })),
  ];

  const selectCategory = (next: MakerCategoryId) => {
    apply(ALL_FILTER);
    onSelectCategory(next);
  };

  const openAll = (row: TagRow) => {
    if (row.kind === 'type') {
      selectCategory('0');
      return;
    }
    reset();
  };

  return (
    <div className="maker-movies">
      {isLoading ? (
        <div className="maker-chip-row" aria-hidden>
          {Array.from({ length: 10 }).map((_, i) => (
            <span key={i} className="maker-chip maker-chip--skel" />
          ))}
        </div>
      ) : null}
      {!isLoading && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!isLoading && !err && (data?.categories || []).length === 0 ? (
        <p className="media-empty">暂无分类</p>
      ) : null}
      {!isLoading && !err
        ? rows.map((row) => (
            <TagRowView
              key={row.key}
              row={row}
              category={category}
              active={active}
              expanded={expanded.has(row.key)}
              onOpenAll={() => openAll(row)}
              onToggleExpanded={() => toggleExpanded(row.key)}
              onSelectCategory={selectCategory}
              onPickSingle={pickSingle}
              onToggleMulti={toggleMulti}
            />
          ))
        : null}

      {!isLoading && !err ? (
        <div className="maker-tags__results">
          {listLoading ? <WallSkeleton /> : null}
          {!listLoading && browseErr ? (
            <p className="media-empty allow-select">{browseErr}</p>
          ) : null}
          {!listLoading && !browseErr && items.length === 0 ? (
            <p className="media-empty">暂无影片</p>
          ) : null}
          {items.length > 0 ? (
            <div className="media-wall">
              {items.map((movie) => (
                <MakerMovieCard
                  key={movie.id || movie.number}
                  movie={movie}
                  onClick={() => onOpenMovie(movie)}
                />
              ))}
            </div>
          ) : null}
          {items.length > 0 ? (
            <Pager
              page={page}
              hasMore={hasMore}
              isFetching={browse.isFetching}
              onChange={setPage}
              count={items.length}
            />
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
