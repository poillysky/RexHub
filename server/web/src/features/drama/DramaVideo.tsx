'use client';

import { useEffect, useRef, useState } from 'react';
import Hls from 'hls.js';

export function DramaVideo({
  src,
  poster,
}: {
  src: string;
  poster?: string;
}) {
  const ref = useRef<HTMLVideoElement | null>(null);
  const [failure, setFailure] = useState<{ src: string; message: string } | null>(null);
  const error = failure && failure.src === src ? failure.message : '';

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    let hls: Hls | null = null;
    let disposed = false;
    const controller = new AbortController();

    const setup = async () => {
      const nativeHls = video.canPlayType('application/vnd.apple.mpegurl');
      if (nativeHls || !Hls.isSupported()) {
        video.src = src;
        return;
      }
      let isHls = false;
      try {
        // 只取前 2 字节判断类型：HLS 会忽略 Range 返回列表，MP4 走 206 不会拉整包
        const response = await fetch(src, {
          credentials: 'include',
          signal: controller.signal,
          headers: { Range: 'bytes=0-1' },
        });
        if (!response.ok && response.status !== 206) {
          if (!disposed) setFailure({ src, message: '播放源暂时不可用，请切换剧集重试' });
          return;
        }
        if (/mpegurl/i.test(response.headers.get('content-type') || '')) {
          isHls = true;
        } else if (
          response.status !== 206 &&
          !response.headers.get('content-range') &&
          response.body
        ) {
          const reader = response.body.getReader();
          const { value } = await reader.read();
          if (value) {
            const head = new TextDecoder().decode(
              value.subarray(0, Math.min(value.length, 64)),
            );
            isHls = head.trimStart().startsWith('#EXTM3U');
          }
          await reader.cancel();
        }
      } catch {
        // 探测失败时退回原生播放
      }
      if (disposed) return;
      if (!isHls) {
        video.src = src;
        return;
      }
      const instance = new Hls({ enableWorker: true });
      hls = instance;
      instance.on(Hls.Events.ERROR, (_event, data) => {
        if (!data.fatal || disposed) return;
        instance.destroy();
        hls = null;
        video.src = src;
        void video.play().catch(() => {});
      });
      instance.loadSource(src);
      instance.attachMedia(video);
    };

    void setup();
    return () => {
      disposed = true;
      controller.abort();
      if (hls) hls.destroy();
      video.removeAttribute('src');
      video.load();
    };
  }, [src]);

  return (
    <>
      <video
        ref={ref}
        className="drama-player__video"
        poster={poster || undefined}
        controls
        autoPlay
        playsInline
        preload="metadata"
        onError={(event) => {
          // 卸载时清空 src 也会触发 error，忽略这种空源事件
          if (!event.currentTarget.currentSrc) return;
          setFailure({ src, message: '视频播放失败，请切换剧集重试' });
        }}
      />
      {error ? <p className="drama-player__error">{error}</p> : null}
    </>
  );
}
