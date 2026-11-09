'use client';

import { useState } from 'react';
import { Play, Search, Star } from 'lucide-react';
import { SoftImg } from '@/components/SoftImg';
import { StreamPlayModal } from '@/features/media/StreamPlayModal';
import {
  fetchMakerPlaySources,
  type MakerEntityKind,
  type MakerMovie,
  type MakerMovieDetail,
  type MakerPlaySource,
} from '@/lib/api/makers';
import { useMakerMovie, useMakerReviews } from '../useMakerQueries';
import {
  MakerMovieCard,
  Pager,
  ReviewRow,
  makerImageUrl,
  type OpenActorHandler,
} from './shared';
import { MagnetRow, ResourceRow, TorrentRow } from './resources';
import { MakerRelatedLists } from './lists';

/** 影片评论详情页：展示全部评论 */
export function MakerMovieReviewsBody({ id }: { id: string }) {
  const [page, setPage] = useState(1);
  const { data, isLoading, isFetching, error } = useMakerReviews(id, page);
  const items = data?.items || [];
  const hasMore = !!data?.hasMore;
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';

  if (isLoading) {
    return (
      <div className="maker-movies">
        <div className="maker-reviews" aria-hidden>
          {Array.from({ length: 6 }).map((_, i) => (
            <span key={i} className="maker-review maker-review--skel" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="maker-movies">
      {err ? <p className="media-empty allow-select">{err}</p> : null}
      {!err && items.length === 0 ? <p className="media-empty">暂无评论</p> : null}
      <div className="maker-reviews">
        {items.map((r) => (
          <ReviewRow key={r.id || `${r.username}-${r.createdAt}`} review={r} />
        ))}
      </div>
      {items.length > 0 || page > 1 ? (
        <Pager page={page} hasMore={hasMore} isFetching={isFetching} onChange={setPage} />
      ) : null}
    </div>
  );
}

/* ── 影片详情 ───────────────────────────────────── */

export function MakerMovieBody({
  id,
  seed,
  onOpenActor,
  onOpenEntity,
  onOpenList,
  onOpenMovie,
  onOpenReviews,
  onOpenSearch,
}: {
  id: string;
  seed?: MakerMovie | null;
  onOpenActor?: OpenActorHandler;
  onOpenEntity?: (kind: MakerEntityKind, id: string, name: string) => void;
  onOpenList?: (list: { id: string; name: string }) => void;
  onOpenMovie?: (movie: MakerMovie) => void;
  onOpenReviews?: () => void;
  onOpenSearch?: (query: string) => void;
}) {
  const { data, isLoading, error } = useMakerMovie(id);
  const detail: MakerMovieDetail | undefined = data;
  /** 顶栏配图沿用入口卡片那张图（列表卡用的是 cover / thumb），不再用预览截图 */
  const poster =
    makerImageUrl(seed?.coverUrl, 720) ||
    makerImageUrl(seed?.thumbUrl, 720) ||
    makerImageUrl(detail?.coverUrl, 720) ||
    makerImageUrl(detail?.thumbUrl, 720);
  const [imgGone, setImgGone] = useState(false);
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';

  const reviews = useMakerReviews(id, 1);
  const reviewItems = reviews.data?.items || [];
  const reviewTotal = detail?.reviewsCount || reviewItems.length;
  const hasMoreReviews = reviewTotal > 10;

  const title = detail?.number || seed?.number || detail?.title || seed?.title || id;
  const subtitle = detail?.title || seed?.title || '';
  const metaLine = [
    detail?.releaseDate || seed?.releaseDate || '',
    detail?.duration || seed?.duration
      ? `${detail?.duration || seed?.duration} 分钟`
      : '',
    (detail?.magnetsCount ?? seed?.magnetsCount)
      ? `${detail?.magnetsCount ?? seed?.magnetsCount} 个磁力`
      : '',
    detail?.hasCnsub || seed?.hasCnsub ? '中文字幕' : '',
    detail?.score != null && detail.score !== '' ? `评分 ${detail.score}` : '',
    detail?.watchedCount ? `${detail.watchedCount} 次观看` : '',
  ]
    .filter(Boolean)
    .join(' · ');
  const plainTags = detail?.tags || [];
  const magnets = detail?.magnets || [];
  const resources = detail?.resources || [];
  const torrents = detail?.avdbTorrents || [];
  const relative = detail?.relativeMovies || [];

  return (
    <div className="media-detail media-detail--hero-right">
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
          <span className="media-detail__poster-ph">{title.slice(0, 1)}</span>
          {poster && !imgGone ? (
            <SoftImg
              src={poster}
              loading="eager"
              fetchPriority="high"
              onError={() => setImgGone(true)}
            />
          ) : null}
          {detail?.score != null && detail.score !== '' ? (
            <span className="media-detail__score">
              <Star size={11} strokeWidth={2.6} aria-hidden />
              <span className="media-detail__score-n">{detail.score}</span>
            </span>
          ) : null}
        </div>
        <div className="media-detail__meta">
          <h2 className="media-detail__title allow-select">{title}</h2>
          {subtitle ? (
            <p className="media-detail__aka allow-select">{subtitle}</p>
          ) : null}

          <div className="media-detail__stats">
            <div className="media-detail__stats-main">
              {metaLine ? (
                <p className="media-detail__meta-line allow-select">{metaLine}</p>
              ) : null}
            </div>
          </div>
        </div>
      </div>

      {isLoading && !detail ? (
        <p className="media-empty">加载中…</p>
      ) : null}
      {!isLoading && err ? <p className="media-empty allow-select">{err}</p> : null}

      {detail?.summary ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">简介</h3>
          <p className="media-detail__overview allow-select">{detail.summary}</p>
        </section>
      ) : null}

      {detail?.actors?.length ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">演员</h3>
          <div className="media-detail__tags">
            {detail.actors.slice(0, 12).map((a) => {
              const avatar = makerImageUrl(a.avatarUrl, 96);
              return (
                <button
                  key={a.id || a.name}
                  type="button"
                  className="media-detail__tag media-detail__tag--btn media-detail__tag--actor"
                  onClick={() =>
                    onOpenActor?.({
                      id: a.id,
                      name: a.name,
                      videosCount: 0,
                    })
                  }
                >
                  {avatar ? (
                    <img
                      className="media-detail__tag-avatar"
                      src={avatar}
                      alt=""
                      loading="lazy"
                      referrerPolicy="no-referrer"
                    />
                  ) : null}
                  {a.name}
                </button>
              );
            })}
          </div>
        </section>
      ) : null}

      {(detail?.makers?.length || plainTags.length || detail?.publisher) ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">标签</h3>
          <div className="media-detail__tags">
            {(detail?.makers || []).slice(0, 4).map((m) => (
              <button
                key={`m-${m.id || m.name}`}
                type="button"
                className="media-detail__tag media-detail__tag--btn"
                onClick={() => onOpenEntity?.('maker', m.id, m.name)}
              >
                {m.name}
              </button>
            ))}
            {detail?.director && detail.directorId ? (
              <button
                type="button"
                className="media-detail__tag media-detail__tag--btn"
                onClick={() =>
                  onOpenEntity?.('director', detail.directorId!, detail.director!)
                }
              >
                导演 {detail.director}
              </button>
            ) : null}
            {detail?.series && detail.seriesId ? (
              <button
                type="button"
                className="media-detail__tag media-detail__tag--btn"
                onClick={() =>
                  onOpenEntity?.('series', detail.seriesId!, detail.series!)
                }
              >
                系列 {detail.series}
              </button>
            ) : null}
            {detail?.publisher ? (
              <span className="media-detail__tag">{detail.publisher}</span>
            ) : null}
            {plainTags.slice(0, 6).map((t) => (
              <span key={`t-${t}`} className="media-detail__tag">
                {t}
              </span>
            ))}
          </div>
        </section>
      ) : null}

      {detail || seed || onOpenSearch ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">在线播放和搜索</h3>
          <div className="maker-preview-row">
            {detail || seed ? (
              <MakerOnlinePlay
                movieId={id}
                number={detail?.number || seed?.number || ''}
                title={detail?.title || seed?.title || ''}
              />
            ) : null}
            {onOpenSearch ? (
              <button
                type="button"
                className="media-detail__cta media-detail__cta--bt"
                onClick={() =>
                  onOpenSearch(detail?.number || seed?.number || title)
                }
              >
                <Search size={17} strokeWidth={2.25} aria-hidden />
                搜索
              </button>
            ) : null}
          </div>
          {detail?.previews?.length ? (
            <>
              <h4 className="media-detail__h media-detail__subh">图片</h4>
              <div className="maker-previews">
                {detail.previews.slice(0, 12).map((p, i) => (
                  <SoftImg
                    key={`pv-${i}`}
                    className="maker-preview allow-select"
                    src={makerImageUrl(p.large || p.thumb, 480)}
                    alt=""
                    loading="lazy"
                    referrerPolicy="no-referrer"
                  />
                ))}
              </div>
            </>
          ) : null}
        </section>
      ) : null}

      {magnets.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">磁力链接</h3>
          <div className="maker-magnets">
            {magnets.map((m, i) => (
              <MagnetRow key={`${m.url}-${i}`} magnet={m} />
            ))}
          </div>
        </section>
      ) : null}

      {resources.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">共享资源</h3>
          <div className="maker-magnets">
            {resources.map((r) => (
              <ResourceRow key={`${r.id}-${r.url}`} resource={r} />
            ))}
          </div>
        </section>
      ) : null}

      {torrents.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">AVDB 资源（{torrents.length}）</h3>
          <div className="maker-magnets">
            {torrents.map((t) => (
              <TorrentRow key={t.id} torrent={t} />
            ))}
          </div>
        </section>
      ) : null}

      {reviewItems.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">
            评论{detail?.reviewsCount ? `（${detail.reviewsCount}）` : ''}
          </h3>
          <div className="maker-reviews">
            {reviewItems.slice(0, 10).map((r) => (
              <ReviewRow key={r.id || `${r.username}-${r.createdAt}`} review={r} />
            ))}
          </div>
          {hasMoreReviews ? (
            <button
              type="button"
              className="maker-reviews__more"
              onClick={() => onOpenReviews?.()}
            >
              查看全部 {reviewTotal} 条评论
            </button>
          ) : null}
        </section>
      ) : null}

      {relative.length > 0 ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">相关影片</h3>
          <div className="media-shelf__rail">
            {relative.slice(0, 12).map((m) => (
              <MakerMovieCard
                key={`rel-${m.id || m.number}`}
                movie={m}
                onClick={() => onOpenMovie?.(m)}
              />
            ))}
          </div>
        </section>
      ) : null}

      {detail?.actorMovies?.length ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">同演员作品</h3>
          <div className="media-shelf__rail">
            {detail.actorMovies.slice(0, 12).map((m) => (
              <MakerMovieCard
                key={`am-${m.id || m.number}`}
                movie={{
                  id: m.id,
                  number: m.number,
                  title: m.title,
                  coverUrl: m.coverUrl,
                  thumbUrl: m.thumbUrl,
                  previewUrl: null,
                  releaseDate: null,
                  duration: 0,
                  magnetsCount: 0,
                  hasCnsub: false,
                }}
                onClick={() =>
                  onOpenMovie?.({
                    id: m.id,
                    number: m.number,
                    title: m.title,
                    coverUrl: m.coverUrl,
                    thumbUrl: m.thumbUrl,
                    previewUrl: null,
                    releaseDate: null,
                    duration: 0,
                    magnetsCount: 0,
                    hasCnsub: false,
                  })
                }
              />
            ))}
          </div>
        </section>
      ) : null}

      {detail?.topRankings?.length ? (
        <section className="media-detail__section">
          <h3 className="media-detail__h">榜单排名</h3>
          <div className="maker-chip-row">
            {detail.topRankings.map((t, i) => (
              <span key={`tr-${t.type}-${t.period}-${i}`} className="maker-chip">
                {t.type} {t.period} 第 {t.rank} 名
              </span>
            ))}
          </div>
        </section>
      ) : null}

      {onOpenList ? (
        <MakerRelatedLists movieId={id} onOpenList={onOpenList} />
      ) : null}

      {detail?.shareUrl ? (
        <section className="media-detail__section">
          <a
            className="maker-link"
            href={detail.shareUrl}
            target="_blank"
            rel="noreferrer"
          >
            在 AVDB 查看原始条目
          </a>
        </section>
      ) : null}
    </div>
  );
}

/* ── 在线播放 ──────────────────────────────────── */

/** 在线播放：聚合片商类插件、Stremio 插件与 AVDB 播放源 */
function MakerOnlinePlay({
  movieId,
  number,
  title,
}: {
  movieId: string;
  number: string;
  title: string;
}) {
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [streams, setStreams] = useState<MakerPlaySource[]>([]);
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');

  async function openPlayer() {
    setOpen(true);
    setLoading(true);
    setError('');
    setStreams([]);
    setReason('');
    try {
      const data = await fetchMakerPlaySources({ movieId, number, title });
      setStreams(data.streams);
      setReason(data.reason);
    } catch (err) {
      setError(err instanceof Error ? err.message : '获取播放源失败');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="maker-video">
      <button type="button" className="maker-video__trigger" onClick={openPlayer}>
        <span className="maker-video__play" aria-hidden>
          <Play size={22} strokeWidth={2} fill="currentColor" />
        </span>
        在线播放
      </button>
      <StreamPlayModal
        open={open}
        title={[number, title].filter(Boolean).join(' · ') || '在线播放'}
        streams={streams}
        total={streams.length}
        reason={reason}
        loading={loading}
        error={error}
        onClose={() => setOpen(false)}
      />
    </div>
  );
}
