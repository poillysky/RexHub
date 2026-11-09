'use client';

import { useState } from 'react';
import { SoftImg } from '@/components/SoftImg';
import { P115SaveButton } from '@/features/home/P115SaveButton';
import { linkKindOf } from '@/lib/resourceView';
import { useOverlay } from '@/components/overlay/OverlayContext';
import type { MakerMagnet, MakerResource, MakerTorrent } from '@/lib/api/makers';
import { canSave115, makerImageUrl } from './shared';

/* ── 磁力 ───────────────────────────────────────── */

function magnetMeta(m: MakerMagnet): string {
  return [m.size, m.createdAt, m.filesCount > 1 ? `${m.filesCount} 个文件` : '']
    .filter(Boolean)
    .join(' · ');
}

export function MagnetRow({ magnet }: { magnet: MakerMagnet }) {
  const { toast } = useOverlay();
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(magnet.url);
      toast('磁力链接已复制', 'success');
    } catch {
      toast('复制失败，请长按选择', 'error');
    }
  };
  return (
    <div className="maker-magnet">
      <div className="maker-magnet__head">
        <span className="maker-magnet__name allow-select">
          {magnet.name || '磁力链接'}
        </span>
        <div className="maker-magnet__actions">
          <button type="button" className="maker-magnet__btn" onClick={copy}>
            复制
          </button>
          <P115SaveButton
            item={{
              hash: '',
              name: magnet.name || '磁力链接',
              ed2k_link: magnet.url,
              ed2k_links: [magnet.url],
              link_kind: 'magnet',
            }}
            urls={[magnet.url]}
            source="maker"
            className="maker-magnet__btn maker-magnet__btn--p115"
            onToast={(msg) => toast(msg, 'info')}
          />
        </div>
      </div>
      {magnetMeta(magnet) ? (
        <span className="maker-magnet__meta">{magnetMeta(magnet)}</span>
      ) : null}
    </div>
  );
}

/* ── 共享资源 ───────────────────────────────────── */

export function ResourceRow({ resource }: { resource: MakerResource }) {
  const { toast } = useOverlay();
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(resource.url);
      toast(`${resource.type.toUpperCase()} 链接已复制`, 'success');
    } catch {
      toast('复制失败，请长按选择', 'error');
    }
  };
  const size = resource.sizeBytes
    ? `${(resource.sizeBytes / 1024 / 1024 / 1024).toFixed(2)} GB`
    : '';
  return (
    <div className="maker-magnet">
      <div className="maker-magnet__head">
        <span className="maker-magnet__name allow-select">
          {resource.type.toUpperCase()}
          {resource.hd ? ' · HD' : ''} · {resource.name || '资源'}
        </span>
        <div className="maker-magnet__actions">
          <button type="button" className="maker-magnet__btn" onClick={copy}>
            复制
          </button>
          {canSave115(resource.url) ? (
            <P115SaveButton
              item={{
                hash: resource.hash || '',
                name: resource.name || '资源',
                ed2k_link: resource.url,
                ed2k_links: [resource.url],
                link_kind: linkKindOf(resource.url),
              }}
              urls={[resource.url]}
              source="maker"
              className="maker-magnet__btn maker-magnet__btn--p115"
              onToast={(msg) => toast(msg, 'info')}
            />
          ) : null}
        </div>
      </div>
      <span className="maker-magnet__meta">
        {[size, resource.sourceLabel, resource.hash].filter(Boolean).join(' · ')}
      </span>
    </div>
  );
}

/* ── AVDB 自有种子库资源 ────────────────────────── */

function torrentSize(t: MakerTorrent): string {
  if (t.sizeBytes) return `${(t.sizeBytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  if (t.sizeMb) return `${(t.sizeMb / 1024).toFixed(2)} GB`;
  return '';
}

function torrentFlags(t: MakerTorrent): string[] {
  const flags: string[] = [];
  if (t.chinese) flags.push('中文');
  if (t.uncensored) flags.push('无码');
  if (t.uc) flags.push('破解');
  if (t.uhd) flags.push('4K');
  else if (t.hd) flags.push('HD');
  if (t.mosaic) flags.push('有码');
  if (t.free) flags.push('免费');
  return flags;
}

export function TorrentRow({ torrent }: { torrent: MakerTorrent }) {
  const { toast } = useOverlay();
  const [gone, setGone] = useState(false);
  const link = torrent.downloadUrl || '';
  const isMagnet = link.startsWith('magnet:');
  const copy = async () => {
    if (!link) return;
    try {
      await navigator.clipboard.writeText(link);
      toast(isMagnet ? '磁力链接已复制' : '下载链接已复制', 'success');
    } catch {
      toast('复制失败，请长按选择', 'error');
    }
  };
  const cover = makerImageUrl(torrent.previewImage, 320);
  const flags = torrentFlags(torrent);

  return (
    <div className="maker-magnet maker-torrent">
      {cover && !gone ? (
        <span className="maker-torrent__cover">
          <SoftImg
            src={cover}
            alt=""
            loading="lazy"
            referrerPolicy="no-referrer"
            onError={() => setGone(true)}
          />
        </span>
      ) : null}
      <div className="maker-torrent__body">
        <div className="maker-magnet__head">
          <span className="maker-magnet__name allow-select">
            {torrent.website || torrent.site || torrent.section || '资源'}
          </span>
          <div className="maker-torrent__actions">
            {link ? (
              <button type="button" className="maker-magnet__btn" onClick={copy}>
                {isMagnet ? '复制磁力' : '复制链接'}
              </button>
            ) : null}
            {canSave115(torrent.downloadUrl) ? (
              <P115SaveButton
                item={{
                  hash: '',
                  name: torrent.title || torrent.number || '资源',
                  title: torrent.title,
                  ed2k_link: torrent.downloadUrl,
                  ed2k_links: [torrent.downloadUrl],
                  link_kind: linkKindOf(torrent.downloadUrl),
                }}
                urls={[torrent.downloadUrl]}
                source="maker"
                className="maker-magnet__btn maker-magnet__btn--p115"
                onToast={(msg) => toast(msg, 'info')}
              />
            ) : null}
          </div>
          {flags.length > 0 ? (
            <span className="maker-chip-row maker-torrent__flags">
              {flags.map((f) => (
                <span key={f} className="maker-chip">
                  {f}
                </span>
              ))}
            </span>
          ) : null}
        </div>
        {torrent.title ? (
          <span className="maker-torrent__title allow-select">{torrent.title}</span>
        ) : null}
        <span className="maker-magnet__meta">
          {[
            torrent.number,
            torrentSize(torrent),
            torrent.seeders ? `${torrent.seeders} 做种` : '',
            torrent.postTime || '',
            (torrent.tags || []).join(' '),
          ]
            .filter(Boolean)
            .join(' · ')}
        </span>
      </div>
    </div>
  );
}
