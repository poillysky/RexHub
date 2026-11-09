'use client';

import { useMemo, useState } from 'react';
import { HardDrive, Search, Star } from 'lucide-react';
import {
  type MediaCastPerson,
  type MediaItem,
  proxiedCoverUrl,
} from '@/lib/api';
import { useTabNavigation } from '@/shell';
import { SoftImg } from '@/components/SoftImg';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { useOverlay } from '@/components/overlay/OverlayContext';
import { openHomeSearchFromItem } from './mediaUi';
import { MediaPosterCard } from './MediaPosterCard';
import { MediaStreamsButton } from './MediaStreamsButton';
import { useMediaRelated } from './useMediaQueries';
import { normalizeCast, pickAka, shortCountry } from './detailHelpers';

/** 头像代理失败时退回首字占位，避免出现破图 */
function CastAvatar({ src, name }: { src: string; name: string }) {
  const [failed, setFailed] = useState(false);
  return (
    <span className="media-detail__cast-avatar" aria-hidden>
      {src && !failed ? (
        <img
          src={src}
          alt=""
          loading="lazy"
          decoding="async"
          referrerPolicy="no-referrer"
          onError={() => setFailed(true)}
        />
      ) : (
        <span className="media-detail__cast-ph">
          {(name || '演').slice(0, 1)}
        </span>
      )}
    </span>
  );
}

export function MediaDetailBody({
  item,
  enriching = false,
  onOpenRelated,
  onOpenPerson,
  onPtSearch,
}: {
  item: MediaItem;
  /** 列表项已展示、详情接口仍在拉取时 */
  enriching?: boolean;
  onOpenRelated?: (next: MediaItem) => void;
  onOpenPerson?: (person: MediaCastPerson) => void;
  onPtSearch?: (mode: 'title' | 'imdbid') => void;
}) {
  const tabCtx = useTabNavigation();
  const { toast } = useOverlay();
  const [imgGone, setImgGone] = useState(false);
  /** 点击 PT 搜索后先弹窗选搜索方式 */
  const [ptPickOpen, setPtPickOpen] = useState(false);
  /**
   * 同一条目内锁定首张已展示海报（详情回填换 URL 时不再闪没）；
   * 条目切换由调用方 key 重新挂载，因此这里只需保存首值。
   */
  const [firstPoster] = useState(() => proxiedCoverUrl(item.posterUrl));
  const poster = firstPoster || proxiedCoverUrl(item.posterUrl);
  const cast = normalizeCast(item.cast);
  const showCastSkel = enriching && cast.length === 0;
  const imdbId = (item.imdbId || '').trim();
  const ptKeyword = (item.originalTitle || item.title || '').trim();

  const relatedQuery = useMediaRelated({
    source: item.source,
    id: item.id,
    mediaType: item.mediaType,
    enabled: Boolean(onOpenRelated) && !enriching,
  });
  const related = useMemo(() => {
    const merged = [
      ...(relatedQuery.data?.recommendations || []),
      ...(relatedQuery.data?.similar || []),
    ];
    const seen = new Set<string>();
    const uniq: MediaItem[] = [];
    for (const row of merged) {
      const k = `${row.source}-${row.id}`;
      if (seen.has(k) || row.id === item.id) continue;
      seen.add(k);
      uniq.push(row);
      if (uniq.length >= 12) break;
    }
    return uniq;
  }, [relatedQuery.data, item.id]);
  const relatedLoading = Boolean(onOpenRelated) && relatedQuery.isPending;
  const showRelatedSkel = relatedLoading && related.length === 0;

  const akaLine = pickAka(item);
  const rating =
    item.rating != null && Number(item.rating) > 0
      ? Number(item.rating).toFixed(1)
      : null;

  /** 走搜索页「影视」通道（source=bitmagnet，scope=movie） */
  function onSearch() {
    const ok = openHomeSearchFromItem(item, (t) => tabCtx?.scrollToTab(t));
    if (!ok) toast('没有可用的片名用于搜索', 'error');
    else toast('已跳转影视搜索', 'success');
  }

  return (
    <div className="media-detail">
      {poster && !imgGone ? (
        <div className="media-detail__wash" aria-hidden>
          <SoftImg
            src={poster}
            loading="eager"
            fetchPriority="high"
            onError={() => setImgGone(true)}
          />
        </div>
      ) : null}

      <div className="media-detail__hero">
        <div className="media-detail__poster" aria-hidden>
          <span className="media-detail__poster-ph">
            {(item.title || item.originalTitle || '').slice(0, 1) || '影'}
          </span>
          {poster && !imgGone ? (
            <SoftImg
              src={poster}
              loading="eager"
              fetchPriority="high"
              onError={() => setImgGone(true)}
            />
          ) : null}
          {rating ? (
            <span className="media-detail__score">
              <Star size={11} strokeWidth={2.6} aria-hidden />
              <span className="media-detail__score-n">{rating}</span>
            </span>
          ) : null}
        </div>
        <div className="media-detail__meta">
          <h2 className="media-detail__title allow-select">
            {item.title || '未知条目'}
          </h2>
          {akaLine.length > 0 ? (
            <p className="media-detail__aka allow-select">
              {akaLine.join(' · ')}
            </p>
          ) : null}

          <div className="media-detail__stats">
            <div className="media-detail__stats-main">
              <p className="media-detail__meta-line allow-select">
                {[
                  item.year || '',
                  item.mediaType === 'tv' ? '剧集' : '电影',
                  item.runtime ? `${item.runtime} 分钟` : '',
                ]
                  .filter(Boolean)
                  .join(' · ')}
              </p>
              {(item.genres?.length || item.countries?.length) ? (
                <div className="media-detail__tags" aria-label="类型与地区">
                  {(item.genres || []).slice(0, 4).map((g) => (
                    <span key={`g-${g}`} className="media-detail__tag">
                      {g}
                    </span>
                  ))}
                  {(item.countries || []).slice(0, 2).map((c) => (
                    <span
                      key={`c-${c}`}
                      className="media-detail__tag media-detail__tag--place"
                    >
                      {shortCountry(c)}
                    </span>
                  ))}
                </div>
              ) : null}
            </div>
          </div>

        </div>
      </div>

      {cast.length > 0 || showCastSkel ? (
        <section className="media-detail__section media-detail__cast-sec">
          <h3 className="media-detail__h">主演</h3>
          {showCastSkel ? (
            <div className="media-detail__cast-rail" aria-hidden>
              {Array.from({ length: 6 }).map((_, i) => (
                <div
                  key={i}
                  className="media-detail__cast-card media-detail__cast-card--static"
                >
                  <span className="media-detail__cast-avatar media-detail__cast-skel" />
                  <span className="media-detail__cast-skel-name" />
                </div>
              ))}
            </div>
          ) : (
            <div className="media-detail__cast-rail">
              {cast.map((p, i) => {
                const avatar = proxiedCoverUrl(p.avatarUrl);
                const body = (
                  <>
                    <CastAvatar src={avatar} name={p.name} />
                    <span className="media-detail__cast-name">{p.name}</span>
                  </>
                );
                return onOpenPerson ? (
                  <button
                    key={`${p.id || p.name}-${i}`}
                    type="button"
                    className="media-detail__cast-card"
                    onClick={() => onOpenPerson(p)}
                  >
                    {body}
                  </button>
                ) : (
                  <div
                    key={`${p.id || p.name}-${i}`}
                    className="media-detail__cast-card media-detail__cast-card--static"
                  >
                    {body}
                  </div>
                );
              })}
            </div>
          )}
        </section>
      ) : null}

      {item.overview ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">简介</h3>
          <p className="media-detail__overview allow-select">{item.overview}</p>
        </section>
      ) : enriching ? (
        <section className="media-detail__section" aria-hidden>
          <h3 className="media-detail__h">简介</h3>
          <div className="media-detail__overview-skel">
            <span />
            <span />
            <span />
            <span className="media-detail__overview-skel__short" />
          </div>
        </section>
      ) : null}

      <div className="media-detail__actions">
        <button type="button" className="media-detail__cta media-detail__cta--bt" onClick={onSearch}>
          <Search size={17} strokeWidth={2.25} aria-hidden />
          影视搜索
        </button>
        {onPtSearch ? (
          <button
            type="button"
            className="media-detail__cta media-detail__cta--pt"
            onClick={() => setPtPickOpen(true)}
          >
            <HardDrive size={17} strokeWidth={2.25} aria-hidden />
            PT搜索
          </button>
        ) : null}
        <MediaStreamsButton item={item} title={item.title || '未知条目'} />
      </div>

      <AppCenterModal
        open={ptPickOpen}
        title="PT 搜索方式"
        onClose={() => setPtPickOpen(false)}
        cardClassName="media-pt-pick-modal"
      >
        <div className="media-pt-pick">
          <button
            type="button"
            className="media-pt-pick__opt"
            onClick={() => {
              setPtPickOpen(false);
              onPtSearch?.('title');
            }}
          >
            <span className="media-pt-pick__opt-title">按标题搜索</span>
            <span className="media-pt-pick__opt-desc">
              用「{ptKeyword}」在全部已启用站点模糊匹配
            </span>
          </button>
          <button
            type="button"
            className="media-pt-pick__opt"
            onClick={() => {
              setPtPickOpen(false);
              onPtSearch?.('imdbid');
            }}
          >
            <span className="media-pt-pick__opt-title">按 IMDb 搜索</span>
            <span className="media-pt-pick__opt-desc">
              {imdbId
                ? `按 ${imdbId} 精确匹配`
                : '由 MoviePilot 解析该条目对应的 IMDb 编号后匹配'}
            </span>
          </button>
        </div>
      </AppCenterModal>

      {onOpenRelated && (showRelatedSkel || related.length > 0) ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">相似推荐</h3>
          {showRelatedSkel ? (
            <div className="media-shelf__rail media-shelf__rail--skel" aria-hidden>
              {Array.from({ length: 5 }).map((_, i) => (
                <span key={i} className="media-poster-skel" />
              ))}
            </div>
          ) : (
            <div className="media-shelf__rail">
              {related.map((it) => (
                <MediaPosterCard
                  key={`${it.source}-${it.id}`}
                  item={it}
                  size="sm"
                  onClick={() => onOpenRelated(it)}
                />
              ))}
            </div>
          )}
        </section>
      ) : null}
    </div>
  );
}
