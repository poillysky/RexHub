'use client';

import { useState, type ReactNode } from 'react';
import { Copy } from 'lucide-react';
import { copyText } from '@/lib/clipboard';
import type { P115SaveSource, ScopeSearchItem } from '@/lib/api';
import { AppMsg } from '@/components/ui/AppMsg';
import {
  scopeCopyTarget,
  scopeLinkRows,
  scopeSaveItem,
  scopeUrls,
} from './ScopeResultList';
import { P115SaveButton } from './P115SaveButton';

function Kv({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="bm-kv__row">
      <span className="bm-kv__k">{label}</span>
      <span className="bm-kv__v">{children}</span>
    </div>
  );
}

/** 范围搜索结果详情：AVDB / CloudSaver 等无本地 hash 的条目展示自身信息与链接。 */
export function ScopeDetailBody({
  item,
  source,
}: {
  item: ScopeSearchItem;
  /** 转存目录：影视 → media，片商 → maker */
  source: P115SaveSource;
}) {
  const [msg, setMsg] = useState('');
  const [coverGone, setCoverGone] = useState(false);
  const rows = scopeLinkRows(item);
  const allCopy = scopeCopyTarget(item);
  // AVDB 封面 CDN 为加扰字节流，必须走服务端 img-proxy 解码
  const coverSrc = item.thumbUrl
    ? `/api/makers/image?${new URLSearchParams({
        url: item.thumbUrl,
        w: '960',
      }).toString()}`
    : '';

  async function onCopy(text: string, okText = '已复制链接') {
    if (!text) {
      setMsg('没有可复制的链接');
      return;
    }
    const ok = await copyText(text);
    setMsg(ok ? okText : '复制失败');
  }

  return (
    <div className="bm-detail">
      <h1 className="bm-detail__title allow-select">{item.title}</h1>
      <div className="bm-detail__stack">
        <section className="bm-card">
          <header className="bm-card__head bm-card__head--static">详情</header>
          <div className="bm-card__body">
            <div className="bm-kv">
              <Kv label="来源">{item.sourceLabel}</Kv>
              <Kv label="大小">{item.sizeLabel}</Kv>
              {item.publishedAt ? (
                <Kv label="日期">{item.publishedAt}</Kv>
              ) : null}
              {item.category === 'pan' ? <Kv label="类型">网盘</Kv> : null}
              {item.hash ? (
                <Kv label="Hash">
                  <span className="allow-select">{item.hash}</span>
                </Kv>
              ) : null}
            </div>
          </div>
        </section>

        <section className="bm-card">
          <header className="bm-card__head bm-card__head--static bm-card__head--actions">
            <span>下载链接</span>
            <div className="bm-card__actions">
              {allCopy ? (
                <button
                  type="button"
                  className="bm-action-btn"
                  onClick={() => void onCopy(allCopy)}
                >
                  <Copy size={13} strokeWidth={2.25} aria-hidden />
                  复制链接
                </button>
              ) : null}
              <P115SaveButton
                item={scopeSaveItem(item)}
                urls={scopeUrls(item)}
                source={source}
                className="bm-action-btn bm-action-btn--save"
                onToast={setMsg}
              />
            </div>
          </header>
          <div className="bm-card__body">
            {rows.length === 0 ? (
              <p className="detail-stub-hint">暂无下载链接</p>
            ) : (
              <div className="detail-link-list">
                {rows.map((row, index) => (
                  <div
                    key={`${row.url}-${index}`}
                    className="detail-link-row"
                  >
                    <span className="detail-link-row__idx">{index + 1}</span>
                    <span className="detail-link-row__url allow-select">
                      {row.url}
                    </span>
                    <button
                      type="button"
                      className="detail-link-row__copy"
                      aria-label={`复制链接 ${index + 1}`}
                      onClick={() => void onCopy(row.url, '已复制')}
                    >
                      <Copy size={13} strokeWidth={2.25} aria-hidden />
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </section>

        {coverSrc && !coverGone ? (
          <section className="bm-card">
            <header className="bm-card__head bm-card__head--static">
              内容预览
            </header>
            <div className="bm-card__body bm-card__body--preview">
              <div className="detail-preview-grid detail-preview-grid--single">
                <span className="detail-preview-grid__slot detail-preview-grid__slot--full">
                  <img
                    className="detail-preview-grid__img"
                    src={coverSrc}
                    alt=""
                    loading="lazy"
                    decoding="async"
                    onError={() => setCoverGone(true)}
                  />
                </span>
              </div>
            </div>
          </section>
        ) : null}
      </div>
      <AppMsg onDismiss={() => setMsg('')}>{msg}</AppMsg>
    </div>
  );
}
