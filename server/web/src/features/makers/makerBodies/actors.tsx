'use client';

import { useState } from 'react';
import type { MakerCategoryId } from '@/lib/api/makers';
import { useMakerActors, useMakerActorRecommend } from '../useMakerQueries';
import { ActorGrid, Pager, type OpenActorHandler } from './shared';

type ActorRecommendGroup = 'new' | 'monthly' | 'fanza';

const ACTOR_RECOMMEND_TABS: Array<{ id: ActorRecommendGroup; label: string }> = [
  { id: 'new', label: '新人' },
  { id: 'monthly', label: '月榜' },
  { id: 'fanza', label: 'FANZA(DMM)推荐' },
];

export function MakerActorsRecommendBody({
  onOpenActor,
}: {
  onOpenActor: OpenActorHandler;
}) {
  const { data, isPending, error } = useMakerActorRecommend();
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const groups = ACTOR_RECOMMEND_TABS.map((tab) => ({
    ...tab,
    actors: data
      ? tab.id === 'new'
        ? data.newActors
        : tab.id === 'monthly'
          ? data.monthlyActors
          : data.recommendActors
      : [],
  }));
  const empty = groups.every((g) => g.actors.length === 0);

  return (
    <>
      {isPending ? (
        <div className="maker-actors" aria-hidden>
          {Array.from({ length: 8 }).map((_, i) => (
            <span key={i} className="maker-actor maker-actor--skel" />
          ))}
        </div>
      ) : null}
      {!isPending && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!isPending && !err && empty ? (
        <p className="media-empty">暂无演员</p>
      ) : null}
      {!isPending && !err
        ? groups.map((group) =>
            group.actors.length > 0 ? (
              <section key={group.id} className="media-detail__section">
                <h3 className="media-detail__h">
                  {group.label}
                  <span className="maker-actors__badge">{group.actors.length}</span>
                </h3>
                <ActorGrid actors={group.actors} onOpenActor={onOpenActor} />
              </section>
            ) : null,
          )
        : null}
    </>
  );
}

/** 演员总入口：推荐（新人 / 月榜 / FANZA 推荐）+ 有码 / 无码 / 欧美 */
export function MakerActorsHubBody({
  category,
  recommend,
  onSelectTab,
  onOpenActor,
}: {
  category: MakerCategoryId;
  recommend: boolean;
  onSelectTab: (next: { category: MakerCategoryId; recommend: boolean }) => void;
  onOpenActor: OpenActorHandler;
}) {
  const tabs: Array<{ id: string; label: string }> = [
    { id: 'recommend', label: '推荐' },
    { id: '0', label: '有码' },
    { id: '1', label: '无码' },
    { id: '2', label: '欧美' },
  ];

  return (
    <div className="maker-actors-page">
      <div className="media-source-switch" role="tablist" aria-label="演员分类">
        {tabs.map((tab) => {
          const active =
            tab.id === 'recommend' ? recommend : !recommend && tab.id === category;
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={active}
              className={
                active
                  ? 'media-source-switch__btn is-active'
                  : 'media-source-switch__btn'
              }
              onClick={() =>
                onSelectTab(
                  tab.id === 'recommend'
                    ? { category, recommend: true }
                    : { category: tab.id as MakerCategoryId, recommend: false },
                )
              }
            >
              {tab.label}
            </button>
          );
        })}
      </div>
      {recommend ? (
        <MakerActorsRecommendBody onOpenActor={onOpenActor} />
      ) : (
        <MakerActorsBody key={category} category={category} onOpenActor={onOpenActor} />
      )}
    </div>
  );
}

export function MakerActorsBody({
  category,
  onOpenActor,
}: {
  category: MakerCategoryId;
  onOpenActor: OpenActorHandler;
}) {
  const [page, setPage] = useState(1);
  const { data, isLoading, isFetching, error } = useMakerActors(category, page);
  const items = data?.items || [];
  const hasMore = !!data?.hasMore;
  const err = error instanceof Error ? error.message : error ? '加载失败' : '';
  const loading = isLoading || (isFetching && items.length === 0);

  return (
    <div className="maker-movies">
      {loading ? (
        <div className="maker-actors" aria-hidden>
          {Array.from({ length: 8 }).map((_, i) => (
            <span key={i} className="maker-actor maker-actor--skel" />
          ))}
        </div>
      ) : null}
      {!loading && err ? <p className="media-empty allow-select">{err}</p> : null}
      {!loading && !err && items.length === 0 ? (
        <p className="media-empty">暂无演员</p>
      ) : null}
      {items.length > 0 ? (
        <ActorGrid actors={items} onOpenActor={onOpenActor} />
      ) : null}
      {items.length > 0 ? (
        <Pager
          page={page}
          hasMore={hasMore}
          isFetching={isFetching}
          onChange={setPage}
          count={items.length}
        />
      ) : null}
    </div>
  );
}
