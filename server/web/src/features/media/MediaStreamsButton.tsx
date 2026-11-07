'use client';

/**
 * 在线播放：把已启用 Stremio 插件聚合出的片源列出来，直链交给页面内 <video>。
 * 种子源网页端无法直接播，只提供复制磁链；外部源走新窗口。
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { Film } from 'lucide-react';
import {
  fetchMediaStreams,
  fetchMediaSubtitles,
  fetchMoreplayStreams,
  toBridgeMediaId,
  type MediaItem,
  type MediaStreamsResult,
  type MediaSubtitle,
} from '@/lib/api';
import { StreamPlayModal } from './StreamPlayModal';

export function MediaStreamsButton({
  item,
  title,
}: {
  item: MediaItem;
  title: string;
}) {
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<MediaStreamsResult | null>(null);
  const [error, setError] = useState('');
  const [subtitles, setSubtitles] = useState<MediaSubtitle[]>([]);
  const [subtitleLoading, setSubtitleLoading] = useState(false);
  const [subtitleReason, setSubtitleReason] = useState('');
  const abortRef = useRef<AbortController | null>(null);
  const isTv = item.mediaType === 'tv';
  // 详情页的 item.id 是裸 id（TMDB 为数字），后端需要 `tmdb:movie/123` 这种桥 id
  const bridgeId = toBridgeMediaId(item.source, item.id, item.mediaType);

  const load = useCallback(async () => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setLoading(true);
    setError('');
    setResult(null);
    setSubtitles([]);
    setSubtitleReason('');
    setSubtitleLoading(true);
    // 字幕独立请求：慢插件不阻塞片源列表
    void fetchMediaSubtitles({
      id: bridgeId,
      imdbId: item.imdbId,
      mediaType: isTv ? 'series' : 'movie',
      season: isTv ? 1 : 0,
      episode: isTv ? 1 : 0,
      signal: controller.signal,
    })
      .then((data) => {
        if (controller.signal.aborted) return;
        setSubtitles(data.subtitles);
        setSubtitleReason(data.reason);
      })
      .catch((exc: Error) => {
        if (controller.signal.aborted) return;
        setSubtitleReason(exc?.message || '字幕拉取失败');
      })
      .finally(() => {
        if (!controller.signal.aborted) setSubtitleLoading(false);
      });
    try {
      // 两个来源并行请求；社区片源先到先展示，猫源解析完成后再合并。
      const communityTask = fetchMediaStreams({
        id: bridgeId,
        imdbId: item.imdbId,
        mediaType: item.mediaType,
        season: isTv ? 1 : 0,
        episode: isTv ? 1 : 0,
        signal: controller.signal,
      });
      const moreplayTask = fetchMoreplayStreams({
        title: item.title,
        year: item.year,
        mediaType: item.mediaType,
        season: isTv ? 1 : 0,
        episode: isTv ? 1 : 0,
        signal: controller.signal,
      });
      const community = await communityTask
        .then((value) => ({ ok: true as const, value }))
        .catch((reason: unknown) => ({ ok: false as const, reason }));
      if (controller.signal.aborted) return;
      if (community.ok) {
        setResult({
          streams: community.value.streams,
          total: community.value.total,
          addons: community.value.addons,
          reason: community.value.reason,
        });
        setLoading(false);
      }
      const moreplay = await moreplayTask
        .then((value) => ({ ok: true as const, value }))
        .catch((reason: unknown) => ({ ok: false as const, reason }));
      if (controller.signal.aborted) return;
      if (!community.ok && !moreplay.ok) throw community.reason;
      const communityData = community.ok ? community.value : null;
      const moreplayData = moreplay.ok ? moreplay.value : null;
      const streams = [...(moreplayData?.streams || []), ...(communityData?.streams || [])];
      const reasons = [moreplayData?.reason, communityData?.reason]
        .map((value) => value?.trim())
        .filter(Boolean);
      setResult({
        streams,
        total: streams.length,
        addons: (communityData?.addons || 0) + (moreplayData ? 1 : 0),
        reason: streams.length === 0 ? reasons.join('；') : '',
      });
    } catch (exc) {
      if ((exc as Error)?.name === 'AbortError') return;
      setError((exc as Error)?.message || '片源拉取失败');
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }, [bridgeId, item.imdbId, item.mediaType, item.title, item.year, isTv]);

  useEffect(() => {
    if (!open) {
      abortRef.current?.abort();
      setResult(null);
      setError('');
    }
  }, [open]);

  useEffect(() => () => abortRef.current?.abort(), []);

  return (
    <>
      <button
        type="button"
        className="media-detail__cta media-detail__cta--stream"
        onClick={() => {
          setOpen(true);
          void load();
        }}
      >
        <Film size={17} strokeWidth={2.25} aria-hidden />
        在线播放
      </button>

      <StreamPlayModal
        open={open}
        title="在线片源"
        streams={result?.streams || []}
        total={result?.total || 0}
        reason={result?.reason}
        loading={loading}
        error={error}
        subtitles={subtitles}
        subtitleLoading={subtitleLoading}
        subtitleReason={subtitleReason}
        hint={
          isTv
            ? '当前展示第 1 季第 1 集的片源；猫源来自 MorePlay，社区插件多为种子源。'
            : '猫源来自 MorePlay；社区插件多为种子源，网页播放需要直链。'
        }
        footerHint={`片源来自 MorePlay 猫源与 ${title} 社区插件，版权内容请自行判断。`}
        onRetry={() => void load()}
        onClose={() => setOpen(false)}
      />
    </>
  );
}
