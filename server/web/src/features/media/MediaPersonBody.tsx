'use client';

import { useMemo, useState } from 'react';
import { Loader2 } from 'lucide-react';
import {
  proxiedCoverUrl,
  type MediaCastPerson,
  type MediaItem,
  type MediaSourceId,
} from '@/lib/api';
import { SoftImg } from '@/components/SoftImg';
import { MediaPosterCard } from './MediaPosterCard';
import { useMpPerson, useMpPersonWorks } from './useMediaQueries';

function yearOf(item: MediaItem): string {
  const y = String(item.year || '').trim();
  return /^\d{4}$/.test(y) ? y : '';
}

function sortByYearDesc(items: MediaItem[]): MediaItem[] {
  return [...items].sort((a, b) => {
    const ya = yearOf(a) ? Number(yearOf(a)) : -1;
    const yb = yearOf(b) ? Number(yearOf(b)) : -1;
    if (yb !== ya) return yb - ya;
    const ra = Number(a.rating || 0);
    const rb = Number(b.rating || 0);
    return rb - ra;
  });
}

function groupByYear(items: MediaItem[]): Array<{ year: string; items: MediaItem[] }> {
  const sorted = sortByYearDesc(items);
  const map = new Map<string, MediaItem[]>();
  for (const it of sorted) {
    const y = yearOf(it) || '未知年份';
    const bucket = map.get(y);
    if (bucket) bucket.push(it);
    else map.set(y, [it]);
  }
  return Array.from(map.entries()).map(([year, rows]) => ({ year, items: rows }));
}

export function MediaPersonBody({
  source,
  person,
  onOpen,
}: {
  source: MediaSourceId;
  person: MediaCastPerson;
  onOpen: (item: MediaItem) => void;
}) {
  const [avatarGone, setAvatarGone] = useState(false);
  const [bioOpen, setBioOpen] = useState(false);

  // 父级用 key={person.id} 重挂载本组件，无需 effect 重置本地状态
  const personId = String(person.id || '').trim();

  const info = useMpPerson({ source, personId });
  const works = useMpPersonWorks({ source, personId });

  const detail = info.data;
  const displayName = detail?.name || person.name;
  const avatar = proxiedCoverUrl(detail?.avatarUrl || person.avatarUrl);

  const items = useMemo(() => {
    const rows = (works.data?.pages || []).flatMap((p) => p.items);
    const seen = new Set<string>();
    const uniq: MediaItem[] = [];
    for (const row of rows) {
      const key = `${row.source}-${row.id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      uniq.push(row);
    }
    return uniq;
  }, [works.data]);

  const loading = works.isPending;
  const err = works.isError
    ? works.error instanceof Error
      ? works.error.message
      : '加载失败'
    : '';

  const groups = useMemo(() => groupByYear(items), [items]);
  const yearSpan = useMemo(() => {
    const years = items.map(yearOf).filter(Boolean).map(Number);
    if (years.length === 0) return '';
    const max = Math.max(...years);
    const min = Math.min(...years);
    return max === min ? `${max}` : `${min}–${max}`;
  }, [items]);

  const aka = (detail?.aliases || []).filter((s) => s && s !== displayName);
  const originalName =
    detail?.originalName && detail.originalName !== displayName
      ? detail.originalName
      : '';
  const aliases = originalName ? [originalName, ...aka] : aka;

  const facts = [
    {
      k: '出生日期',
      v: [detail?.birthday, detail?.deathday ? `– ${detail.deathday}` : '']
        .filter(Boolean)
        .join(' '),
    },
    { k: '出生地', v: detail?.placeOfBirth || '' },
    { k: '性别', v: detail?.gender || '' },
    { k: '别名', v: aliases.slice(0, 5).join(' / ') },
  ].filter((f) => f.v);

  const bio = String(detail?.biography || '').trim();
  const bioLong = bio.length > 160;

  return (
    <div className="media-person">
      <header className="media-person__hero">
        <span className="media-person__avatar" aria-hidden>
          <span className="media-person__avatar-ph">
            {displayName.slice(0, 1)}
          </span>
          {avatar && !avatarGone ? (
            <SoftImg
              src={avatar}
              loading="lazy"
              onError={() => setAvatarGone(true)}
            />
          ) : null}
        </span>
        <div className="media-person__meta">
          <h2 className="media-person__name allow-select">{displayName}</h2>
          <div className="media-person__chips">
            {detail?.department ? (
              <span className="media-person__chip">{detail.department}</span>
            ) : null}
            {loading ? (
              <span className="media-person__chip media-person__chip--mute">
                加载中
              </span>
            ) : err ? (
              <span className="media-person__chip media-person__chip--warn">
                加载失败
              </span>
            ) : items.length > 0 ? (
              <>
                <span className="media-person__chip">
                  {items.length}
                  {works.hasNextPage ? '+' : ''} 部
                </span>
                {yearSpan ? (
                  <span className="media-person__chip">{yearSpan}</span>
                ) : null}
              </>
            ) : (
              <span className="media-person__chip media-person__chip--mute">
                暂无作品
              </span>
            )}
          </div>
        </div>
      </header>

      {facts.length > 0 ? (
        <div className="media-person__facts allow-select">
          {facts.map((f) => (
            <p key={f.k} className="media-person__fact">
              <span className="media-person__fact-k">{f.k}</span>
              <span className="media-person__fact-v">{f.v}</span>
            </p>
          ))}
        </div>
      ) : null}

      {bio ? (
        <section className="media-person__section">
          <h3 className="media-person__h">简介</h3>
          <p
            className={
              bioLong && !bioOpen
                ? 'media-person__bio is-clamped allow-select'
                : 'media-person__bio allow-select'
            }
          >
            {bio}
          </p>
          {bioLong ? (
            <button
              type="button"
              className="media-person__bio-more"
              onClick={() => setBioOpen((v) => !v)}
            >
              {bioOpen ? '收起' : '展开'}
            </button>
          ) : null}
        </section>
      ) : null}

      {loading ? (
        <div className="media-person__skel" aria-hidden>
          <div className="media-person__year-head media-person__year-head--skel">
            <span className="media-person__skel-bar" />
          </div>
          <div className="media-wall media-wall--skel">
            {Array.from({ length: 6 }).map((_, i) => (
              <span key={i} className="media-poster-skel media-poster-skel--wall" />
            ))}
          </div>
        </div>
      ) : null}

      {!loading && err ? (
        <p className="media-empty allow-select">{err}</p>
      ) : null}

      {!loading && !err && items.length === 0 ? (
        <p className="media-empty">暂无作品</p>
      ) : null}

      {!loading && !err
        ? groups.map((g) => (
            <section key={g.year} className="media-person__year">
              <div className="media-person__year-head">
                <h3 className="media-person__year-title">{g.year}</h3>
                <span className="media-person__year-count">{g.items.length} 部</span>
              </div>
              <div className="media-wall media-person__wall">
                {g.items.map((it) => (
                  <MediaPosterCard
                    key={`${it.source}-${it.id}`}
                    item={it}
                    category={it.mediaType === 'tv' ? 'tv' : 'movie'}
                    size="md"
                    onClick={() => onOpen(it)}
                  />
                ))}
              </div>
            </section>
          ))
        : null}

      {!loading && !err && works.hasNextPage ? (
        <button
          type="button"
          className="media-person__more"
          disabled={works.isFetchingNextPage}
          onClick={() => void works.fetchNextPage()}
        >
          {works.isFetchingNextPage ? (
            <Loader2 size={15} className="media-person__spinner" aria-hidden />
          ) : null}
          {works.isFetchingNextPage ? '加载中' : '加载更多作品'}
        </button>
      ) : null}
    </div>
  );
}
