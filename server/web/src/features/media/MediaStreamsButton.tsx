'use client';

/**
 * 在线播放：调用插件中心的 MorePlay 能力，按站源流式拉取网盘原画线路。
 * 线路都经服务端代理，页面内 <video> 直接播放。
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { Film } from 'lucide-react';
import {
  streamMoreplayStreams,
  type MediaItem,
  type MediaStream,
  type MediaStreamsResult,
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
  const [result, setResult] = useState<MediaStreamsResult | null>(null);
  const [error, setError] = useState('');
  // 仍有站源在请求中，用于展示“正在匹配”状态
  const [searching, setSearching] = useState(false);
  // 剧集默认第 1 季第 1 集，用户可在片源面板里切换
  const [season, setSeason] = useState(1);
  const [episode, setEpisode] = useState(1);
  const abortRef = useRef<AbortController | null>(null);
  // 流式追加的片源（按到达顺序），以及已出现过的 key，避免重复
  const streamsRef = useRef<MediaStream[]>([]);
  const seenRef = useRef<Set<string>>(new Set());
  const siteNamesRef = useRef<Set<string>>(new Set());
  const reasonRef = useRef('');
  const isTv = item.mediaType === 'tv';

  const publish = useCallback(() => {
    setResult({
      streams: streamsRef.current,
      total: streamsRef.current.length,
      addons: siteNamesRef.current.size,
      reason: streamsRef.current.length > 0 ? '' : reasonRef.current,
    });
  }, []);

  const load = useCallback(async () => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setError('');
    setResult(null);
    streamsRef.current = [];
    seenRef.current = new Set();
    siteNamesRef.current = new Set();
    reasonRef.current = '';
    setSearching(true);
    try {
      await streamMoreplayStreams(
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
            const added = streams.filter((stream) => {
              const key = streamKey(stream);
              if (!key || seenRef.current.has(key)) return false;
              seenRef.current.add(key);
              return true;
            });
            if (added.length === 0) return;
            streamsRef.current = [...streamsRef.current, ...added];
            publish();
          },
          onDone: (reason) => {
            if (controller.signal.aborted) return;
            if (reason) reasonRef.current = reason;
          },
        },
      );
      if (controller.signal.aborted) return;
      publish();
    } catch (exc) {
      if ((exc as Error)?.name === 'AbortError') return;
      setError((exc as Error)?.message || '片源拉取失败');
    } finally {
      if (!controller.signal.aborted) setSearching(false);
    }
  }, [item.title, item.year, item.mediaType, isTv, season, episode, publish]);

  useEffect(() => {
    if (!open) {
      abortRef.current?.abort();
      setResult(null);
      setError('');
      setSearching(false);
    }
  }, [open]);

  // 打开面板或切换季/集后重新拉取片源
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
        searching={searching}
        error={error}
        season={isTv ? season : undefined}
        episode={isTv ? episode : undefined}
        onSeasonChange={isTv ? setSeason : undefined}
        onEpisodeChange={isTv ? setEpisode : undefined}
        footerHint={`片源来自 MorePlay 猫源（${title}），版权内容请自行判断。`}
        onRetry={() => void load()}
        onClose={() => setOpen(false)}
      />
    </>
  );
}
