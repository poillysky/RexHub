'use client';

/**
 * makers 各页面 body 的对外出口。
 * 具体实现按页面拆分在 ./makerBodies/*，此文件仅做统一 re-export，调用方无需改动。
 */

export { MakerMovieCard, ActorGrid } from './makerBodies/shared';

export {
  MakerMoviesBody,
  MakerListBody,
  MakerHotReviewsBody,
  MakerRecentViewedBody,
  MakerBrowseBody,
} from './makerBodies/movies';
export type { MakerListKind } from './makerBodies/movies';

export { MakerSearchBody } from './makerBodies/search';
export { MakerTagsBody } from './makerBodies/tags';

export {
  MakerActorsBody,
  MakerActorsRecommendBody,
  MakerActorsHubBody,
} from './makerBodies/actors';

export {
  MakerMovieBody,
  MakerMovieReviewsBody,
} from './makerBodies/movieDetail';

export {
  MakerEntityBody,
  MakerActorDetailBody,
} from './makerBodies/entity';

export {
  MakerListDetailBody,
  MakerRelatedLists,
} from './makerBodies/lists';
