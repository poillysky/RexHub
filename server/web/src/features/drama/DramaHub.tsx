'use client';

import { ChevronRight, Clapperboard } from 'lucide-react';
import { SoftImg } from '@/components/SoftImg';
import type { DramaSite } from '@/lib/api';
import type { CSSProperties } from 'react';
import { useDramaSites } from './useDramaScreen';

export function DramaHub({ onOpen }: { onOpen: (site: DramaSite) => void }) {
  const { sites, loading, error } = useDramaSites();

  return (
    <section className="drama-hub__section">
      <div className="drama-sites">
        {loading
          ? Array.from({ length: 4 }).map((_, i) => (
              <span key={i} className="drama-site-skel" />
            ))
          : null}
        {!loading && error ? (
          <p className="drama-empty allow-select">{error}</p>
        ) : null}
        {!loading && !error && sites.length === 0 ? (
          <p className="drama-empty">暂无可用的短剧片源</p>
        ) : null}
        {sites.map((site, index) => {
          const ui = site.ui?.shortdrama;
          const accent = ui?.accent;
          const cardStyle = accent
            ? ({ '--site-accent': accent } as CSSProperties)
            : undefined;
          return (
            <button
              key={site.id}
              type="button"
              className="drama-site-card"
              style={cardStyle}
              onClick={() => onOpen(site)}
            >
              <span
                className={`drama-site-card__logo${
                  ui?.logo
                    ? ' is-logo-image'
                    : site.id === 'rexhub.hongguo.video' || index === 0
                      ? ' is-hot'
                      : ''
                }`}
                style={
                  accent && !ui?.logo
                    ? {
                        background: `linear-gradient(135deg, ${accent}, color-mix(in srgb, ${accent} 55%, #fff))`,
                        boxShadow: `0 6px 16px color-mix(in srgb, ${accent} 30%, transparent)`,
                      }
                    : undefined
                }
                aria-hidden
              >
                {ui?.logo ? (
                  <SoftImg
                    className="drama-site-card__logo-img"
                    src={ui.logo}
                    loading="lazy"
                  />
                ) : ui?.icon ? (
                  <span
                    className="drama-site-card__glyph"
                    dangerouslySetInnerHTML={{ __html: ui.icon }}
                  />
                ) : (
                  <Clapperboard size={22} strokeWidth={1.9} aria-hidden />
                )}
              </span>
              <span className="drama-site-card__main">
                <span className="drama-site-card__name">
                  {ui?.title || site.name}
                  {ui?.badge ? (
                    <span className="drama-site-card__badge">{ui.badge}</span>
                  ) : null}
                </span>
                <span className="drama-site-card__desc">
                  {ui?.subtitle || '短剧片单 · 可直接播放'}
                </span>
              </span>
              <ChevronRight
                size={18}
                className="drama-site-card__arrow"
                aria-hidden
              />
            </button>
          );
        })}
      </div>
    </section>
  );
}
