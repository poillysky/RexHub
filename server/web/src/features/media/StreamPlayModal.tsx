'use client';

/**
 * 片源弹层：列表 + 页面内 <video>。
 * 影视详情页（聚合全部插件）与插件详情页（只看单个插件）共用。
 */

import { useEffect, useRef, useState } from 'react';
import { Copy, ExternalLink, LoaderCircle, Play, RefreshCw } from 'lucide-react';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { useOverlay } from '@/components/overlay/OverlayContext';
import { copyText } from '@/lib/clipboard';
import {
  mediaStreamProxyUrl,
  mediaSubtitleProxyUrl,
  type MediaStream,
  type MediaSubtitle,
} from '@/lib/api';

const MAX_ROWS = 40;

/** `srcLang` 只接受合法的语言标签，上游偶尔给 "Chinese" 之类的名字。 */
function trackLang(lang: string) {
  const value = String(lang || '').trim();
  return /^[a-z]{2,3}(-[a-z0-9]{2,8})*$/i.test(value) ? value : 'und';
}

/** Safari 可直接播 m3u8；其他浏览器交给 hls.js，不能同时设置 src。 */
const NATIVE_HLS =
  typeof document !== 'undefined' &&
  document.createElement('video').canPlayType('application/vnd.apple.mpegurl') !== '';

function formatSize(size: number | null) {
  if (!size || size <= 0) return '';
  if (size >= 1024 ** 3) return `${(size / 1024 ** 3).toFixed(2)} GB`;
  return `${Math.max(1, Math.round(size / 1024 ** 2))} MB`;
}

function kindLabel(kind: string) {
  if (kind === 'direct') return '直链';
  if (kind === 'external') return '外链';
  if (kind === 'moreplay') return '猫源';
  return 'BT';
}

export function StreamPlayModal({
  open,
  title,
  streams,
  total,
  reason = '',
  loading = false,
  error = '',
  hint = '',
  footerHint = '',
  subtitles = [],
  subtitleLoading = false,
  subtitleReason = '',
  onRetry,
  onNeedAggregate,
  onClose,
}: {
  open: boolean;
  title: string;
  streams: MediaStream[];
  total: number;
  reason?: string;
  loading?: boolean;
  error?: string;
  hint?: string;
  footerHint?: string;
  subtitles?: MediaSubtitle[];
  subtitleLoading?: boolean;
  subtitleReason?: string;
  onRetry?: () => void;
  onNeedAggregate?: () => void;
  onClose: () => void;
}) {
  const { toast } = useOverlay();
  const [playing, setPlaying] = useState<MediaStream | null>(null);
  const [playError, setPlayError] = useState('');
  const videoRef = useRef<HTMLVideoElement | null>(null);

  useEffect(() => {
    if (!open) {
      setPlaying(null);
      setPlayError('');
    }
  }, [open]);

  async function onCopyMagnet(stream: MediaStream) {
    if (!stream.infoHash) return;
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const ok = await copyText(magnet);
    toast(ok ? '已复制磁力链接' : '复制失败');
  }

  /** 播放失败时补一次探测：能拿到上游状态/类型就给出具体的中文原因。 */
  async function describePlayError(url: string) {
    try {
      const res = await fetch(
        playing?.kind === 'moreplay' ? url : mediaStreamProxyUrl(url),
        {
          headers: { Range: 'bytes=0-1' },
          cache: 'no-store',
        },
      );
      if (!res.ok) {
        const data = (await res.json().catch(() => null)) as { detail?: string } | null;
        return (
          data?.detail ||
          `片源直链返回 ${res.status}，可能已失效或需要鉴权，可换一条或外部打开。`
        );
      }
      void res.body?.cancel();
      const contentType = (res.headers.get('content-type') || '').toLowerCase();
      if (
        contentType &&
        !/^(video\/|audio\/|application\/octet-stream|binary\/octet-stream)/.test(
          contentType,
        )
      ) {
        return `片源返回的不是视频流（${contentType}），可能被跳转到了网页，可外部打开。`;
      }
    } catch {
      // 探测失败就退回 MediaError 文案
    }
    const code = videoRef.current?.error?.code ?? 0;
    if (code === 1) return '播放被中断，请重试。';
    if (code === 2) return '网络中断或直链已失效，可换一条或外部打开。';
    if (code === 3) {
      return '视频解码失败：编码格式（如 HEVC / AC3）浏览器不支持，可换一条或外部打开。';
    }
    return '浏览器不支持这个片源的格式（多为 MKV 容器或 HEVC 编码），可换一条或外部打开。';
  }

  const visible = streams.slice(0, MAX_ROWS);
  const isHls = Boolean(playing && /\.m3u8?(\?|$)/i.test(playing.url));
  const src = playing
    ? playing.kind === 'moreplay'
      ? playing.url
      : isHls
        ? NATIVE_HLS
          ? playing.url
          : ''
        : mediaStreamProxyUrl(playing.url)
    : '';

  /** Safari 原生支持 HLS；其他浏览器按需加载 hls.js。 */
  useEffect(() => {
    const video = videoRef.current;
    if (!playing || !video || !isHls || NATIVE_HLS) return;
    let hls: import('hls.js').default | null = null;
    let cancelled = false;
    void import('hls.js').then(({ default: Hls }) => {
      if (cancelled || !Hls.isSupported()) return;
      hls = new Hls({ enableWorker: true });
      hls.loadSource(playing.url);
      hls.attachMedia(video);
    });
    return () => {
      cancelled = true;
      hls?.destroy();
    };
  }, [playing, isHls]);

  return (
    <AppCenterModal
      open={open}
      title={playing ? '在线播放' : `${title}${total ? ` · ${total}` : ''}`}
      onClose={onClose}
      cardClassName={playing ? 'stream-modal stream-modal--player' : 'stream-modal'}
    >
      {playing ? (
        <div className="stream-player">
          <video
            key={playing.url}
            ref={videoRef}
            className="stream-player__video"
            src={src || undefined}
            controls
            autoPlay
            playsInline
            onError={() => {
              void describePlayError(playing.url).then(setPlayError);
            }}
          >
            {subtitles.map((track, index) => (
              <track
                key={`${track.url}-${index}`}
                kind="subtitles"
                src={mediaSubtitleProxyUrl(track.url)}
                srcLang={trackLang(track.lang)}
                label={track.label || track.lang || '字幕'}
                default={index === 0}
              />
            ))}
          </video>
          <div className="stream-player__meta">
            <p className="stream-player__title allow-select">
              {playing.filename || playing.title || playing.name || '未命名片源'}
            </p>
            <p className="stream-player__sub">
              {playing.addon}
              {subtitles.length > 0
                ? ` · 字幕 ${subtitles.length} 条`
                : subtitleLoading
                  ? ' · 正在匹配字幕…'
                  : subtitleReason
                    ? ` · ${subtitleReason}`
                    : ''}
            </p>
          </div>
          {playError ? <p className="stream-modal__error">{playError}</p> : null}
          <div className="stream-modal__actions">
            {playing.externalUrl ? (
              <a
                className="stream-modal__link"
                href={playing.externalUrl}
                target="_blank"
                rel="noreferrer noopener"
              >
                <ExternalLink size={14} strokeWidth={2.3} aria-hidden />
                外部打开
              </a>
            ) : null}
            <button
              type="button"
              className="stream-modal__plain"
              onClick={() => {
                setPlaying(null);
                setPlayError('');
              }}
            >
              返回片源列表
            </button>
          </div>
        </div>
      ) : loading ? (
        <div className="stream-modal__state">
          <LoaderCircle size={22} strokeWidth={2.2} className="media-detail__cta-spin" />
          <span>正在拉取片源…</span>
        </div>
      ) : error ? (
        <div className="stream-modal__state">
          <span className="stream-modal__error">{error}</span>
          {onRetry ? (
            <button type="button" className="stream-modal__plain" onClick={onRetry}>
              <RefreshCw size={14} strokeWidth={2.3} aria-hidden />
              重试
            </button>
          ) : null}
        </div>
      ) : visible.length === 0 ? (
        <div className="stream-modal__state">
          <span>{reason || '没有找到可播放的片源'}</span>
          {hint ? <span className="stream-modal__hint">{hint}</span> : null}
          {onNeedAggregate ? (
            <button type="button" className="stream-modal__plain" onClick={onNeedAggregate}>
              <RefreshCw size={14} strokeWidth={2.3} aria-hidden />
              从全部插件找片源
            </button>
          ) : null}
        </div>
      ) : (
        <>
          {hint ? <p className="stream-modal__hint">{hint}</p> : null}
          <ul className="stream-list">
            {visible.map((stream, index) => (
              <li className="stream-item" key={`${stream.addonSlug}-${index}`}>
                <div className="stream-item__main">
                  <p className="stream-item__title allow-select">
                    {stream.filename || stream.title || stream.name || '未命名片源'}
                  </p>
                  <span className="stream-item__actions">
                    {stream.playable ? (
                      <button
                        type="button"
                        className="stream-item__play"
                        onClick={() => {
                          setPlaying(stream);
                          setPlayError('');
                        }}
                      >
                        <Play size={12} strokeWidth={2.4} aria-hidden />
                        播放
                      </button>
                    ) : null}
                    {stream.externalUrl ? (
                      <a
                        className="stream-item__open"
                        href={stream.externalUrl}
                        target="_blank"
                        rel="noreferrer noopener"
                      >
                        <ExternalLink size={12} strokeWidth={2.3} aria-hidden />
                        打开
                      </a>
                    ) : null}
                    {stream.kind === 'torrent' && stream.infoHash ? (
                      <button
                        type="button"
                        className="stream-item__open"
                        onClick={() => void onCopyMagnet(stream)}
                      >
                        <Copy size={12} strokeWidth={2.3} aria-hidden />
                        磁链
                      </button>
                    ) : null}
                  </span>
                </div>
                <div className="stream-item__meta-row">
                  <span className="stream-item__addon">{stream.addon}</span>
                  <span className={`stream-item__kind stream-item__kind--${stream.kind}`}>
                    {kindLabel(stream.kind)}
                  </span>
                  <span className="stream-item__meta">
                    {[stream.name, formatSize(stream.size)].filter(Boolean).join(' · ')}
                  </span>
                </div>
              </li>
            ))}
          </ul>
          {total > visible.length ? (
            <p className="stream-modal__hint">
              仅展示前 {visible.length} 条，共 {total} 条。
            </p>
          ) : null}
          {footerHint ? <p className="stream-modal__hint">{footerHint}</p> : null}
        </>
      )}
    </AppCenterModal>
  );
}
