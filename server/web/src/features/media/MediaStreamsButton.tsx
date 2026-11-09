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
  streamMoreplayStreams,
  toBridgeMediaId,
  type MediaItem,
  type MediaStream,
  type MediaStreamsResult,
  type MediaSubtitle,
} from '@/lib/api';
import { StreamPlayModal } from './StreamPlayModal';

const streamKey = (stream: MediaStream) =>
  stream.url || stream.externalUrl || stream.infoHash || '';

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
  // 仍有片源来源在请求中（社区 / 猫源），用于展示“正在匹配”状态
  const [pendingSources, setPendingSources] = useState(0);
  // 剧集默认第 1 季第 1 集，用户可在片源面板里切换
  const [season, setSeason] = useState(1);
  const [episode, setEpisode] = useState(1);
  const abortRef = useRef<AbortController | null>(null);
  // 流式追加的片源（按到达顺序），以及已出现过的 key，避免重复
  const streamsRef = useRef<MediaStream[]>([]);
  const seenRef = useRef<Set<string>>(new Set());
  const siteNamesRef = useRef<Set<string>>(new Set());
  const communityAddonsRef = useRef(0);
  const reasonRef = useRef('');
  const isTv = item.mediaType === 'tv';
  // 详情页的 item.id 是裸 id（TMDB 为数字），后端需要 `tmdb:movie/123` 这种桥 id
  const bridgeId = toBridgeMediaId(item.source, item.id, item.mediaType);

  const publish = useCallback(() => {
    setResult({
      streams: streamsRef.current,
      total: streamsRef.current.length,
      addons: communityAddonsRef.current + siteNamesRef.current.size,
      reason: streamsRef.current.length > 0 ? '' : reasonRef.current,
    });
  }, []);

  const appendStreams = useCallback((list: MediaStream[]) => {
    const added = list.filter((stream) => {
      const key = streamKey(stream);
      if (!key || seenRef.current.has(key)) return false;
      seenRef.current.add(key);
      return true;
    });
    if (added.length === 0) return false;
    streamsRef.current = [...streamsRef.current, ...added];
    return true;
  }, []);

  const load = useCallback(async () => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setLoading(false);
    setError('');
    setResult(null);
    streamsRef.current = [];
    seenRef.current = new Set();
    siteNamesRef.current = new Set();
    communityAddonsRef.current = 0;
    reasonRef.current = '';
    setSubtitles([]);
    setSubtitleReason('');
    setSubtitleLoading(true);
    // 字幕独立请求：慢插件不阻塞片源列表
    void fetchMediaSubtitles({
      id: bridgeId,
      imdbId: item.imdbId,
      mediaType: isTv ? 'series' : 'movie',
      season: isTv ? season : 0,
      episode: isTv ? episode : 0,
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
      // 社区片源一次性返回，猫源按站点流式追加；谁先到谁先展示。
      // 先挂上 catch，避免后返回的一方在无人等待时产生未处理的 rejection。
      const settle = <T,>(task: Promise<T>) =>
        task
          .then((value) => ({ ok: true as const, value }))
          .catch((reason: unknown) => ({ ok: false as const, reason }));
      setPendingSources(2);
      const communityTask = settle(
        fetchMediaStreams({
          id: bridgeId,
          imdbId: item.imdbId,
          mediaType: item.mediaType,
          season: isTv ? season : 0,
          episode: isTv ? episode : 0,
          title: item.title,
          signal: controller.signal,
        }),
      );
      const moreplayTask = settle(
        streamMoreplayStreams(
          {
            title: item.title,
            year: item.year,
            mediaType: item.mediaType,
            season: isTv ? season : 0,
            episode: isTv ? episode : 0,
            signal: controller.signal,
          },
          {
            // 每命中一个站源就把线路追加进列表，后面的站点继续刷新
            onSite: (site, streams) => {
              if (controller.signal.aborted) return;
              siteNamesRef.current.add(site);
              if (appendStreams(streams)) publish();
            },
            onDone: (reason) => {
              if (controller.signal.aborted) return;
              if (reason) reasonRef.current = reason;
            },
          },
        ),
      );
      const community = await communityTask;
      if (controller.signal.aborted) return;
      setPendingSources((count) => Math.max(0, count - 1));
      if (community.ok) {
        communityAddonsRef.current = community.value.addons;
        reasonRef.current = community.value.reason || reasonRef.current;
        appendStreams(community.value.streams);
        publish();
      }
      const moreplay = await moreplayTask;
      if (controller.signal.aborted) return;
      setPendingSources((count) => Math.max(0, count - 1));
      if (!community.ok && !moreplay.ok) {
        throw community.ok ? moreplay.reason : community.reason;
      }
      publish();
    } catch (exc) {
      if ((exc as Error)?.name === 'AbortError') return;
      setError((exc as Error)?.message || '片源拉取失败');
    } finally {
      if (!controller.signal.aborted) {
        setPendingSources(0);
        setLoading(false);
      }
    }
  }, [appendStreams, publish, bridgeId, item.imdbId, item.mediaType, item.title, item.year, isTv, season, episode]);

  useEffect(() => {
    if (!open) {
      abortRef.current?.abort();
      setResult(null);
      setError('');
      setPendingSources(0);
    }
  }, [open]);

  // 打开面板或切换季/集后重新拉取片源与字幕
  useEffect(() => {
    if (open) void load();
  }, [open, load]);

  useEffect(() => () => abortRef.current?.abort(), []);

  return (
    <>
      <button
        type="button"
        className="media-detail__cta media-detail__cta--stream"
        onClick={() => {
          setOpen(true);
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
        searching={!loading && pendingSources > 0}
        error={error}
        subtitles={subtitles}
        subtitleLoading={subtitleLoading}
        subtitleReason={subtitleReason}
        season={isTv ? season : undefined}
        episode={isTv ? episode : undefined}
        onSeasonChange={isTv ? setSeason : undefined}
        onEpisodeChange={isTv ? setEpisode : undefined}
        footerHint={`片源来自 MorePlay 猫源与 ${title} 社区插件，版权内容请自行判断。`}
        onRetry={() => void load()}
        onClose={() => setOpen(false)}
      />
    </>
  );
}
