'use client';

import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type ImgHTMLAttributes,
  type SyntheticEvent,
} from 'react';

type SoftImgProps = Omit<ImgHTMLAttributes<HTMLImageElement>, 'onError' | 'onLoad'> & {
  /** 加载成功前保持透明，避免破图图标闪一下 */
  onError?: (e: SyntheticEvent<HTMLImageElement>) => void;
  onLoad?: (e: SyntheticEvent<HTMLImageElement>) => void;
};

/**
 * 封面/头像用：未 onLoad 前 opacity:0，失败也不露破图。
 * 父级背景/字母占位继续可见。
 */
export function SoftImg({
  src,
  className,
  onError,
  onLoad,
  alt = '',
  decoding = 'async',
  referrerPolicy = 'no-referrer',
  ...rest
}: SoftImgProps) {
  const url = String(src || '').trim();
  /** 记录「已就绪的 URL」，src 变化时自动回到未就绪，无需额外重置 */
  const [readyUrl, setReadyUrl] = useState('');
  const ready = readyUrl === url;

  // 缓存命中时部分浏览器不触发 onLoad：挂载/换 src 后主动认 ready
  const attachImg = useCallback(
    (el: HTMLImageElement | null) => {
      if (el && el.complete && el.naturalWidth > 0) setReadyUrl(url);
    },
    [url],
  );

  if (!url) return null;

  return (
    <img
      {...rest}
      ref={attachImg}
      className={['soft-img', className].filter(Boolean).join(' ')}
      data-ready={ready ? '1' : undefined}
      src={url}
      alt={alt}
      decoding={decoding}
      referrerPolicy={referrerPolicy}
      onLoad={(e) => {
        setReadyUrl(url);
        onLoad?.(e);
      }}
      onError={(e) => {
        setReadyUrl('');
        onError?.(e);
      }}
    />
  );
}

type LazyImgProps = Omit<SoftImgProps, 'src'> & {
  src: string;
  /** 距离视口多远开始加载（纵向 / 横向），默认一屏上下各 240px */
  rootMargin?: string;
};

/**
 * 进入（或临近）视口才真正发起请求的图片。
 *
 * 首页一屏之外的海报、横滑架里未滑到的卡片都不会下载，避免同时压几十个
 * 图片请求把插件与元数据接口一起拖慢；占位沿用父级背景，加载后淡入。
 */
export function LazyImg({ src, rootMargin = '240px 320px', ...rest }: LazyImgProps) {
  const holderRef = useRef<HTMLSpanElement>(null);
  const [shown, setShown] = useState(false);

  useEffect(() => {
    if (shown) return;
    const el = holderRef.current;
    if (!el) return;
    if (typeof IntersectionObserver === 'undefined') {
      // 老环境没有 IntersectionObserver：下一帧直接加载，避免在 effect 里同步 setState
      const id = requestAnimationFrame(() => setShown(true));
      return () => cancelAnimationFrame(id);
    }
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setShown(true);
          io.disconnect();
        }
      },
      { rootMargin },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [rootMargin, shown]);

  return (
    <span ref={holderRef} className="lazy-img">
      {shown ? <SoftImg src={src} {...rest} /> : null}
    </span>
  );
}
