import type { MediaCategoryId, MediaItem, MpListParams } from '@/lib/api';
import { SEARCH_KEYWORD_LENGTH_MIN } from '@/config/search';
import type { TabRoute } from '@/shell';
import { clearSaveSource, writeSaveSource } from '@/lib/p115Source';

export const MEDIA_CATEGORY_MARK: Record<MediaCategoryId, string> = {
  movie: '影',
  tv: '剧',
  anime: '漫',
  variety: '综',
};

export type MediaHubShelf = {
  /** 货架唯一键（同 tab 内） */
  key: string;
  /** 角标类别；缺省时按条目自身 movie/tv 显示 */
  category?: MediaCategoryId;
  title: string;
  /** MoviePilot 列表路径：recommend/* / anilist/* */
  path: string;
  params: MpListParams;
};

/** 影视 Hub 的内容维度，与 MoviePilot 推荐页分类一致 */
export type MediaHubTab = 'movie' | 'tv' | 'anime' | 'rank';

/**
 * MoviePilot 推荐页货架（按内容维度）。
 * 分组与命名对齐 MoviePilot 前端 recommend 模块清单：
 * categoryMovie / categoryTV / categoryAnime / categoryRankings。
 */
export function hubShelvesFor(tab: MediaHubTab): MediaHubShelf[] {
  if (tab === 'movie') {
    return [
      {
        key: 'showing',
        category: 'movie',
        title: '正在热映',
        path: 'recommend/douban_showing',
        params: { page: 1, count: 30 },
      },
      {
        key: 'tmdb_movies',
        category: 'movie',
        title: 'TMDB 热门电影',
        path: 'recommend/tmdb_movies',
        params: { page: 1, sort_by: 'popularity.desc' },
      },
      {
        key: 'movie_hot',
        category: 'movie',
        title: '豆瓣热门电影',
        path: 'recommend/douban_movie_hot',
        params: { page: 1, count: 30 },
      },
      {
        key: 'movie_new',
        category: 'movie',
        title: '豆瓣最新电影',
        path: 'recommend/douban_movies',
        params: { page: 1, count: 30, sort: 'R' },
      },
    ];
  }
  if (tab === 'tv') {
    return [
      {
        key: 'tmdb_tvs',
        category: 'tv',
        title: 'TMDB 热门电视剧',
        path: 'recommend/tmdb_tvs',
        params: {
          page: 1,
          sort_by: 'popularity.desc',
          with_original_language: 'zh|en|ja|ko',
        },
      },
      {
        key: 'tv_hot',
        category: 'tv',
        title: '豆瓣热门电视剧',
        path: 'recommend/douban_tv_hot',
        params: { page: 1, count: 30 },
      },
      {
        key: 'tv_new',
        category: 'tv',
        title: '豆瓣最新电视剧',
        path: 'recommend/douban_tvs',
        params: { page: 1, count: 30, sort: 'R' },
      },
    ];
  }
  if (tab === 'anime') {
    return [
      {
        key: 'calendar',
        category: 'anime',
        title: 'Bangumi 每日放送',
        path: 'recommend/bangumi_calendar',
        params: { page: 1, count: 30 },
      },
      {
        key: 'anilist_trending',
        category: 'anime',
        title: 'AniList 当前趋势',
        path: 'anilist/trending',
        params: { page: 1, count: 20 },
      },
      {
        key: 'anilist_season',
        category: 'anime',
        title: 'AniList 本季热门',
        path: 'anilist/popular-this-season',
        params: { page: 1, count: 20 },
      },
      {
        key: 'anime_hot',
        category: 'anime',
        title: '豆瓣热门动漫',
        path: 'recommend/douban_tv_animation',
        params: { page: 1, count: 30 },
      },
    ];
  }
  // 榜单：MoviePilot 把 TMDB 流行趋势与豆瓣三个榜单归为 categoryRankings
  return [
    {
      key: 'trending',
      title: '流行趋势',
      path: 'recommend/tmdb_trending',
      params: { page: 1 },
    },
    {
      key: 'top250',
      category: 'movie',
      title: '豆瓣电影 TOP250',
      path: 'recommend/douban_movie_top250',
      params: { page: 1, count: 30 },
    },
    {
      key: 'tv_cn',
      category: 'tv',
      title: '豆瓣国产剧集榜',
      path: 'recommend/douban_tv_weekly_chinese',
      params: { page: 1, count: 30 },
    },
    {
      key: 'tv_global',
      category: 'tv',
      title: '豆瓣全球剧集榜',
      path: 'recommend/douban_tv_weekly_global',
      params: { page: 1, count: 30 },
    },
  ];
}

export function hubTabLabel(tab: MediaHubTab): string {
  return tab === 'rank' ? '榜单' : mediaCategoryLabel(tab);
}

/** 榜单页里条目的角标类别：维度明确时用维度，榜单混排时按条目自身类型 */
export function chartItemCategory(
  tab: MediaHubTab,
  item: MediaItem,
): MediaCategoryId {
  if (tab === 'movie' || tab === 'tv' || tab === 'anime') return tab;
  return item.mediaType === 'tv' ? 'tv' : 'movie';
}

export function mediaCategoryLabel(id: MediaCategoryId): string {
  const map: Record<MediaCategoryId, string> = {
    movie: '电影',
    tv: '电视剧',
    anime: '动漫',
    variety: '综艺',
  };
  return map[id] || id;
}

/** 是否适合进 BT 搜索：中文（汉字）或英文（拉丁），剔除日文假名 / 韩文等。 */
function isZhEnSearchable(s: string): boolean {
  if (/[\u3040-\u30ff\uac00-\ud7af]/.test(s)) return false;
  if (/[\u4e00-\u9fff]/.test(s)) return true;
  if (/[\u0590-\u05FF\u0600-\u06FF\u0E00-\u0E7F\u1780-\u17FF\u0400-\u04FF]/.test(s)) {
    return false;
  }
  return /[A-Za-z]/.test(s);
}

/** 影视跳 BT：主名保留；原名/别名仅中英，用顿号拼接；后端按词分别搜再 OR 合并。 */
export function buildMediaSearchTerms(
  item: Pick<MediaItem, 'title' | 'originalTitle' | 'aka'>,
  opts?: { maxTerms?: number; maxLen?: number },
): string[] {
  const maxTerms = opts?.maxTerms ?? 2;
  const maxLen = opts?.maxLen ?? 100;
  const seen = new Set<string>();
  const parts: string[] = [];
  const candidates = [item.title, item.originalTitle, ...(item.aka || [])];
  for (let i = 0; i < candidates.length; i++) {
    let s = String(candidates[i] || '').trim();
    if (!s) continue;
    // 过长别名截断，避免整串超限
    if (s.length > 60) s = s.slice(0, 60).trim();
    if (s.length < SEARCH_KEYWORD_LENGTH_MIN) continue;
    // 主名恒保留；originalTitle / aka 仅中英
    if (i > 0 && !isZhEnSearchable(s)) continue;
    const key = s.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    parts.push(s);
    if (parts.length >= maxTerms) break;
  }
  while (parts.length > 1 && parts.join('，').length > maxLen) {
    parts.pop();
  }
  return parts;
}

export function buildMediaSearchQuery(
  item: Pick<MediaItem, 'title' | 'originalTitle' | 'aka'>,
): string {
  return buildMediaSearchTerms(item).join('，');
}

/** 盘搜 / CloudSaver：优先中文词，其次主名。 */
export function pickCloudSearchKeyword(
  item: Pick<MediaItem, 'title' | 'originalTitle' | 'aka'>,
): string {
  const terms = buildMediaSearchTerms(item, { maxTerms: 4, maxLen: 80 });
  const zh = terms.find((t) => /[\u4e00-\u9fff]/.test(t));
  return (zh || terms[0] || String(item.title || '').trim()).trim();
}

/** 影视 / 片商跳转仓库：双库同搜 */
export function openHomeSearch(
  names: string[] | string,
  scrollToTab?: (tab: TabRoute) => void,
  opts?: {
    source?: 'sehua' | 'bitmagnet';
    /** 115 转存目录：影视 / 片商 */
    p115Source?: 'media' | 'maker';
  },
): boolean {
  const list = Array.isArray(names) ? names : [names];
  const q = buildMediaSearchQuery({
    title: list[0] || '',
    originalTitle: list[1] || '',
    aka: list.slice(2),
  });
  if (q.trim().length < SEARCH_KEYWORD_LENGTH_MIN) return false;
  const source = opts?.source ?? 'bitmagnet';
  try {
    sessionStorage.setItem('nextweb:home-search', q.trim());
    sessionStorage.setItem('nextweb:home-search-source', source);
    sessionStorage.removeItem('nextweb:home-prefix-region');
    if (opts?.p115Source) {
      writeSaveSource(opts.p115Source);
    } else {
      // 搜索入口：清掉上次继承的影视/片商落点
      clearSaveSource();
    }
    window.dispatchEvent(new Event('nextweb:home-search'));
  } catch {
    return false;
  }
  scrollToTab?.('/');
  return true;
}

export function openHomeSearchFromItem(
  item: MediaItem,
  scrollToTab?: (tab: TabRoute) => void,
): boolean {
  return openHomeSearch(
    [item.title, item.originalTitle || '', ...(item.aka || [])],
    scrollToTab,
    { p115Source: 'media', source: 'bitmagnet' },
  );
}

/** 榜单页 Tab 直接复用推荐货架（同一份 MoviePilot 数据） */
export function chartsForTab(
  tab: MediaHubTab,
): Array<{ id: string; label: string; path: string; params: MpListParams }> {
  return hubShelvesFor(tab).map((s) => ({
    id: s.key,
    label: s.title,
    path: s.path,
    params: s.params,
  }));
}
