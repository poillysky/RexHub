'use client';

import { useState } from 'react';
import { SoftImg } from '@/components/SoftImg';
import type { MakerEntityKind, MakerMovie } from '@/lib/api/makers';
import {
  useMakerActorDetail,
  useMakerBrowse,
  useMakerEntity,
} from '../useMakerQueries';
import { MakerMovieCard, Pager, WallSkeleton, makerImageUrl } from './shared';

/* ── 实体详情（片商 / 导演 / 系列） ─────────────────── */

const ENTITY_LABEL: Record<MakerEntityKind, string> = {
  maker: '片商',
  director: '导演',
  series: '系列',
};

export function MakerEntityBody({
  kind,
  id,
  onOpenMovie,
}: {
  kind: MakerEntityKind;
  id: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const entity = useMakerEntity(kind, id);
  const info = entity.data;
  const [page, setPage] = useState(1);
  // 系列详情需要 series_type（实体接口返回 type），否则默认按「系列」查询
  const seriesType = kind === 'series' && info?.type != null ? String(info.type) : '0';
  const dims =
    kind === 'maker'
      ? { makerId: id }
      : kind === 'director'
        ? { directorId: id }
        : { seriesId: id, seriesType };
  const browse = useMakerBrowse('0', '', '', '', page, undefined, dims);
  const items = browse.data?.items || [];
  const hasMore = !!browse.data?.hasMore;
  const err = entity.error instanceof Error ? entity.error.message : '';
  const browseErr =
    browse.error instanceof Error ? browse.error.message : browse.error ? '加载失败' : '';

  return (
    <div className="maker-movies">
      {!info && !err ? <p className="media-empty">加载中…</p> : null}
      {err ? <p className="media-empty allow-select">{err}</p> : null}
      {info ? (
        <div className="maker-entity">
          <p className="maker-entity__kind">{ENTITY_LABEL[kind]}</p>
          <h2 className="maker-entity__name allow-select">{info.name}</h2>
          <p className="maker-entity__meta">
            {info.videosCount ? `${info.videosCount} 部作品` : '暂无作品统计'}
          </p>
          {info.shareUrl ? (
            <a
              className="maker-link"
              href={info.shareUrl}
              target="_blank"
              rel="noreferrer"
            >
              在 AVDB 查看原始条目
            </a>
          ) : null}
        </div>
      ) : null}
      {browse.isPending ? <WallSkeleton /> : null}
      {!browse.isPending && browseErr ? (
        <p className="media-empty allow-select">{browseErr}</p>
      ) : null}
      {!browse.isPending && !browseErr && items.length === 0 ? (
        <p className="media-empty">暂无影片</p>
      ) : null}
      {items.length > 0 ? (
        <div className="media-wall">
          {items.map((movie) => (
            <MakerMovieCard
              key={movie.id || movie.number}
              movie={movie}
              onClick={() => onOpenMovie(movie)}
            />
          ))}
        </div>
      ) : null}
      {items.length > 0 ? (
        <Pager
          page={page}
          hasMore={hasMore}
          isFetching={browse.isFetching}
          onChange={setPage}
        />
      ) : null}
    </div>
  );
}

/* ── 演员详情 ────────────────────────────────────── */

export function MakerActorDetailBody({
  id,
  onOpenMovie,
}: {
  id: string;
  onOpenMovie: (movie: MakerMovie) => void;
}) {
  const actor = useMakerActorDetail(id);
  const [page, setPage] = useState(1);
  const browse = useMakerBrowse('0', '', '', id, page);
  const items = browse.data?.items || [];
  const hasMore = !!browse.data?.hasMore;
  const err = actor.error instanceof Error ? actor.error.message : '';
  const browseErr =
    browse.error instanceof Error ? browse.error.message : browse.error ? '加载失败' : '';
  const info = actor.data;

  const facts: Array<[string, string]> = info
    ? ([
        ['生日', info.birthday || ''],
        ['年龄', info.age ? `${info.age} 岁` : ''],
        ['星座', info.constellation || ''],
        ['血型', info.bloodType || ''],
        ['身高', info.height ? `${info.height} cm` : ''],
        ['胸围', info.bust ? `${info.bust} cm` : ''],
        ['腰围', info.waist ? `${info.waist} cm` : ''],
        ['臀围', info.hips ? `${info.hips} cm` : ''],
        ['罩杯', info.cup || ''],
        ['出生地', info.birthplace || ''],
      ] as Array<[string, string]>).filter(([, v]) => !!v)
    : [];

  return (
    <div className="maker-movies">
      {!info && !err ? <p className="media-empty">加载中…</p> : null}
      {err ? <p className="media-empty allow-select">{err}</p> : null}
      {info ? (
        <div className="maker-entity">
          {info.avatarUrl ? (
            <SoftImg
              className="maker-entity__avatar"
              src={makerImageUrl(info.avatarUrl, 240) || info.avatarUrl}
              alt=""
              loading="lazy"
              referrerPolicy="no-referrer"
            />
          ) : null}
          <h2 className="maker-entity__name allow-select">{info.name}</h2>
          {info.nameZht ? (
            <p className="maker-entity__meta">{info.nameZht}</p>
          ) : null}
          {info.otherName ? (
            <p className="maker-entity__meta">曾用名：{info.otherName}</p>
          ) : null}
          <p className="maker-entity__meta">
            {info.videosCount ? `${info.videosCount} 部作品` : '暂无作品统计'}
          </p>
          {facts.length > 0 ? (
            <dl className="maker-facts">
              {facts.map(([k, v]) => (
                <div key={k} className="maker-facts__row">
                  <dt className="maker-facts__k">{k}</dt>
                  <dd className="maker-facts__v allow-select">{v}</dd>
                </div>
              ))}
            </dl>
          ) : null}
          {info.filterTags.length > 0 ? (
            <div className="maker-tags__cat">
              <span className="maker-tags__label">特色标签</span>
              <div className="maker-chip-row">
                {info.filterTags.map((t) => (
                  <span key={t.id} className="maker-chip">
                    {t.name}
                  </span>
                ))}
              </div>
            </div>
          ) : null}
          {info.shareUrl ? (
            <a
              className="maker-link"
              href={info.shareUrl}
              target="_blank"
              rel="noreferrer"
            >
              在 AVDB 查看原始条目
            </a>
          ) : null}
        </div>
      ) : null}
      {browse.isPending ? <WallSkeleton /> : null}
      {!browse.isPending && browseErr ? (
        <p className="media-empty allow-select">{browseErr}</p>
      ) : null}
      {!browse.isPending && !browseErr && items.length === 0 ? (
        <p className="media-empty">暂无影片</p>
      ) : null}
      {items.length > 0 ? (
        <div className="media-wall">
          {items.map((movie) => (
            <MakerMovieCard
              key={movie.id || movie.number}
              movie={movie}
              onClick={() => onOpenMovie(movie)}
            />
          ))}
        </div>
      ) : null}
      {items.length > 0 ? (
        <Pager
          page={page}
          hasMore={hasMore}
          isFetching={browse.isFetching}
          onChange={setPage}
        />
      ) : null}
    </div>
  );
}
