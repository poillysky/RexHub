'use client';

import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Copy } from 'lucide-react';
import { fetchMagnetDetail, fetchMagnetPreview, proxiedCoverUrl, type MagnetHit } from '@/lib/api';
import { SoftImg } from '@/components/SoftImg';
import { copyText } from '@/lib/clipboard';
import { formatByteSize, formatDate } from '@/lib/format';
import { AppMsg } from '@/components/ui/AppMsg';
import { P115SaveButton } from '@/features/home/P115SaveButton';
import { BitmagnetFileList } from './BitmagnetFileList';

function magnetOf(item: MagnetHit) {
  return (item.magnet_uri || item.magnet || item.magnets?.[0] || '').trim();
}

function PreviewGrid({ images }: { images: string[] }) {
  /** 失败标记带上图片指纹：换图后旧标记自然失效，无需 effect 重置 */
  const [failed, setFailed] = useState<{
    key: string;
    map: Record<number, true>;
  }>({ key: '', map: {} });
  const proxied = images.map((u) => proxiedCoverUrl(u)).filter(Boolean);
  const key = proxied.join('\0');
  const failedMap = failed.key === key ? failed.map : {};

  const visible = proxied
    .map((src, index) => ({ src, index }))
    .filter(({ index }) => !failedMap[index]);
  if (!visible.length) return null;

  return (
    <section className="bm-card">
      <header className="bm-card__head bm-card__head--static">内容预览</header>
      <div className="bm-card__body bm-card__body--preview">
        <div className="detail-preview-grid detail-preview-grid--video">
          {visible.map(({ src, index }) => (
            <SoftImg
              key={`${src}-${index}`}
              src={src}
              loading="lazy"
              className="detail-preview-grid__img"
              onError={() =>
                setFailed({ key, map: { ...failedMap, [index]: true } })
              }
            />
          ))}
        </div>
      </div>
    </section>
  );
}

/** 对齐 Bitmagnet-Next-Web DetailContent：标题 / 详情 / 磁力 / 预览 / 文件列表 */
export function BitmagnetDetailBody({ hash }: { hash: string }) {
  const [msg, setMsg] = useState('');
  const detailQuery = useQuery({
    queryKey: ['magnet', 'detail', hash],
    queryFn: ({ signal }) => fetchMagnetDetail(hash, signal),
    staleTime: 60 * 1000,
    retry: 1,
  });
  const item = detailQuery.data ?? null;
  const error = detailQuery.isError
    ? detailQuery.error instanceof Error
      ? detailQuery.error.message
      : '加载失败'
    : '';
  const loading = detailQuery.isPending;

  const previewQuery = useQuery({
    queryKey: ['magnet', 'preview', hash],
    queryFn: ({ signal }) => fetchMagnetPreview(hash, signal),
    staleTime: 60 * 1000,
    retry: 0,
  });
  const previewImages = (previewQuery.data?.screenshots || [])
    .map((s) => (s.screenshot || '').trim())
    .filter(Boolean);

  async function onCopy(text: string, success = '已复制') {
    if (!text?.trim()) {
      setMsg('暂无内容可复制');
      return;
    }
    const ok = await copyText(text);
    setMsg(ok ? success : '复制失败');
  }

  if (loading) return <p className="app-loading">加载中…</p>;
  if (error) return <div className="app-error">{error}</div>;
  if (!item) return null;

  const name = item.name || item.title || hash;
  const magnet = magnetOf(item);
  const count = item.files_count ?? item.fileCount ?? item.files?.length ?? 0;
  const created = item.created_at || 0;
  const infoHash = (item.hash || hash).toLowerCase();
  const shortMagnet = `magnet:?xt=urn:btih:${infoHash}`;

  return (
    <div className="bm-detail">
      {msg ? <AppMsg onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}

      <h1 className="bm-detail__title allow-select">{name}</h1>

      <div className="bm-detail__stack">
        <section className="bm-card">
          <header className="bm-card__head bm-card__head--static">详情</header>
          <div className="bm-card__body">
            <div className="bm-kv">
              <div className="bm-kv__row">
                <span className="bm-kv__k">大小</span>
                <span className="bm-kv__v">{formatByteSize(item.size || 0)}</span>
              </div>
              <div className="bm-kv__row">
                <span className="bm-kv__k">文件</span>
                <span className="bm-kv__v">{count}</span>
              </div>
              <div className="bm-kv__row">
                <span className="bm-kv__k">创建</span>
                <span className="bm-kv__v">{formatDate(created)}</span>
              </div>
              <div className="bm-kv__row">
                <span className="bm-kv__k">Hash</span>
                <span className="bm-kv__v">
                  <code
                    className="bm-hash allow-select"
                    title="点击复制"
                    role="button"
                    tabIndex={0}
                    onClick={() => void onCopy(infoHash, '已复制 Hash')}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        void onCopy(infoHash, '已复制 Hash');
                      }
                    }}
                  >
                    {infoHash}
                  </code>
                </span>
              </div>
            </div>
          </div>
        </section>

        <section className="bm-card">
          <header className="bm-card__head bm-card__head--static bm-card__head--actions">
            <span>磁力链接</span>
            <div className="bm-card__actions">
              <P115SaveButton
                item={{
                  hash: infoHash,
                  name,
                  title: name,
                  ed2k_link: magnet,
                  ed2k_links: magnet ? [magnet] : [],
                  link_kind: 'magnet',
                }}
                compact
                onToast={setMsg}
              />
              <button
                type="button"
                className="bm-action-btn"
                onClick={() => void onCopy(magnet, '已复制磁力')}
              >
                <Copy size={13} strokeWidth={2.25} aria-hidden />
                复制
              </button>
            </div>
          </header>
          <div className="bm-card__body">
            <a className="bm-magnet-line allow-select" href={magnet}>
              <span aria-hidden>🧲</span>
              <span>{shortMagnet}</span>
            </a>
          </div>
        </section>

        {previewImages.length > 0 ? <PreviewGrid images={previewImages} /> : null}

        <section className="bm-card">
          <header className="bm-card__head bm-card__head--static">文件列表</header>
          <div className="bm-card__body">
            <BitmagnetFileList torrent={item} />
          </div>
          <footer className="bm-card__foot">
            <div className="bm-card__meta">
              <span>大小 {formatByteSize(item.size || 0)}</span>
              <span>文件 {count}</span>
              <span>创建 {formatDate(created)}</span>
            </div>
          </footer>
        </section>
      </div>
    </div>
  );
}
