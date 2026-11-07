'use client';

import { useState, type MouseEvent } from 'react';
import { copyText } from '@/lib/clipboard';
import { formatByteSize } from '@/lib/format';
import { parseEd2kLink } from '@/lib/resourceView';
import type { P115SaveSource, ScopeSearchItem } from '@/lib/api';
import { AppMsg } from '@/components/ui/AppMsg';
import { P115SaveButton } from './P115SaveButton';

export function scopeCopyTarget(item: ScopeSearchItem): string {
  if (item.magnet) return item.magnet;
  if (item.ed2k) return item.ed2k;
  return item.links[0]?.url || '';
}

type LinkRow = {
  kind: 'magnet' | 'ed2k' | 'link';
  primary: string;
  secondary: string;
  url: string;
};

function shortHash(hash: string): string {
  const h = hash.trim().toUpperCase();
  if (h.length <= 16) return h;
  return `${h.slice(0, 8)}…${h.slice(-6)}`;
}

function decodeEd2kName(raw: string): string {
  try {
    return decodeURIComponent(raw.replace(/\+/g, ' '));
  } catch {
    return raw;
  }
}

export function scopeLinkRows(item: ScopeSearchItem): LinkRow[] {
  const rows: LinkRow[] = [];
  if (item.magnet) {
    rows.push({
      kind: 'magnet',
      primary: item.magnet,
      secondary: '',
      url: item.magnet,
    });
  }
  if (item.ed2k) {
    const parsed = parseEd2kLink(item.ed2k);
    rows.push({
      kind: 'ed2k',
      primary: parsed?.filename ? decodeEd2kName(parsed.filename) : item.ed2k,
      secondary: [
        parsed?.size ? formatByteSize(Number(parsed.size)) : '',
        parsed?.hash ? shortHash(parsed.hash) : '',
      ]
        .filter(Boolean)
        .join(' · '),
      url: item.ed2k,
    });
  }
  for (const link of item.links) {
    const url = link.url.trim();
    if (!url || rows.some((r) => r.url === url)) continue;
    rows.push({
      kind: 'link',
      primary: link.label || '链接',
      secondary: link.password ? `${url} · 提取码 ${link.password}` : url,
      url,
    });
  }
  return rows;
}

export function scopeSaveItem(item: ScopeSearchItem) {
  return {
    hash: item.hash ?? '',
    ed2k_link: item.ed2k ?? '',
    ed2k_links: [] as string[],
    extract_password: item.links.find((l) => l.password)?.password ?? null,
    description: '',
    name: item.title,
    title: item.title,
    link_kind: item.magnet ? 'magnet' : item.ed2k ? 'ed2k' : '115share',
  };
}

export function scopeUrls(item: ScopeSearchItem): string[] {
  return [item.magnet, item.ed2k, ...item.links.map((l) => l.url)].filter(
    (u): u is string => Boolean(u),
  );
}

export function ScopeResultList({
  items,
  page,
  hasMore,
  loadingMore,
  saveSource,
  onPrev,
  onNext,
  onOpenDetail,
}: {
  items: ScopeSearchItem[];
  page: number;
  hasMore: boolean;
  loadingMore: boolean;
  /** 当前搜索范围对应的转存目录：影视 → media，片商 → maker */
  saveSource: P115SaveSource;
  onPrev: () => void;
  onNext: () => void;
  onOpenDetail?: (item: ScopeSearchItem) => void;
}) {
  const [msg, setMsg] = useState('');

  async function onCopy(e: MouseEvent, item: ScopeSearchItem) {
    e.stopPropagation();
    const target = scopeCopyTarget(item);
    if (!target) {
      setMsg('没有可复制的链接');
      return;
    }
    const ok = await copyText(target);
    setMsg(ok ? '已复制链接' : '复制失败');
  }

  function openDetail(item: ScopeSearchItem) {
    onOpenDetail?.(item);
  }

  return (
    <>
      {msg ? <AppMsg onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}
      <div className="bm-result-list">
        {items.map((item) => {
          const rows = scopeLinkRows(item);
          const copyTarget = scopeCopyTarget(item);
          return (
            <article className="bm-card" key={item.id}>
              <header className="bm-card__head">
                <button
                  type="button"
                  className="bm-card__title allow-select"
                  title={item.title}
                  onClick={() => openDetail(item)}
                >
                  <span className="bm-card__title-text bm-card__title-text--inline-badge">
                    <span
                      className={`bm-card__badge bm-card__badge--inline bm-card__badge--${item.source}`}
                    >
                      {item.sourceLabel}
                    </span>
                    {item.title}
                  </span>
                </button>
              </header>
              <div className="bm-card__body bm-card__body--links">
                {rows.length ? (
                  <ul className="bm-card__links">
                    {rows.map((row, index) => (
                      <li
                        key={`${row.url}-${index}`}
                        className={`bm-card__link-row bm-card__link-row--${row.kind}`}
                      >
                        <button
                          type="button"
                          className="bm-card__link-main"
                          title={row.url}
                          onClick={() => openDetail(item)}
                        >
                          <span className="bm-card__link-text">
                            <span
                              className={`bm-card__link-primary allow-select${
                                row.kind === 'magnet'
                                  ? ' bm-card__link-primary--uri'
                                  : ''
                              }`}
                            >
                              {row.primary}
                            </span>
                            {row.secondary ? (
                              <span className="bm-card__link-secondary allow-select">
                                {row.secondary}
                              </span>
                            ) : null}
                          </span>
                        </button>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="bm-card__links-empty">暂无下载链接</p>
                )}
              </div>
              <footer className="bm-card__foot">
                {copyTarget ? (
                  <span className="bm-card__magnet-ico" aria-hidden="true">
                    {item.magnet ? '🧲' : '🔗'}
                  </span>
                ) : null}
                <div className="bm-card__meta bm-card__meta--lead">
                  <span className="bm-card__chip">
                    大小 {item.sizeLabel}
                  </span>
                  {item.publishedAt ? (
                    <span className="bm-card__chip">{item.publishedAt}</span>
                  ) : null}
                  {item.category === 'pan' ? (
                    <span className="bm-card__chip">网盘</span>
                  ) : null}
                </div>
                {copyTarget ? (
                  <button
                    type="button"
                    className="bm-card__magnet"
                    onClick={(e) => void onCopy(e, item)}
                  >
                    复制链接
                  </button>
                ) : null}
                <P115SaveButton
                  item={scopeSaveItem(item)}
                  urls={scopeUrls(item)}
                  source={saveSource}
                  className="bm-card__magnet bm-card__magnet--primary"
                  onToast={setMsg}
                />
              </footer>
            </article>
          );
        })}
      </div>
      <div className="media-chart__pager">
        <button
          type="button"
          className="media-chart__page-btn"
          disabled={page <= 1 || loadingMore}
          onClick={onPrev}
        >
          上一页
        </button>
        <span className="media-chart__page-meta">
          {loadingMore ? '加载中…' : `第 ${page} 页`}
        </span>
        <button
          type="button"
          className="media-chart__page-btn"
          disabled={!hasMore || loadingMore}
          onClick={onNext}
        >
          下一页
        </button>
      </div>
    </>
  );
}
