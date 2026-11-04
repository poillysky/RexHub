/**
 * RexHub 自建 TMDB 插件
 *
 * 目录：热门/正在上映/即将上映/高分/分类榜、剧集榜、国别剧、动漫，共 18 个目录
 * 搜索：多类型搜索（电影 / 剧集）
 * 详情：完整简介、海报、背景、Logo、评分、类型、片长、演职员、预告片、
 *       剧集全部分季分集（含封面、简介、播出日期、单集评分）
 *
 * 需要 TMDB API Key。在管理台「插件管理 → 编辑插件 → API Key / Token」里填写：
 *   1. TMDB v3 API Key（32 位字母数字）；
 *   2. 或 TMDB v4 Read Access Token（以 eyJ 开头，会自动走 Bearer 头）。
 * 如果使用自建 TMDB 代理（代理自行注入 Key），把代理地址填到「接口地址」即可。
 */

// 注意：discoverParams() 在 WidgetMetadata 赋值时立即执行，类型表必须先于它初始化
var MOVIE_GENRES = [
  { id: "28", name: "动作" },
  { id: "12", name: "冒险" },
  { id: "16", name: "动画" },
  { id: "35", name: "喜剧" },
  { id: "80", name: "犯罪" },
  { id: "99", name: "纪录" },
  { id: "18", name: "剧情" },
  { id: "10751", name: "家庭" },
  { id: "14", name: "奇幻" },
  { id: "36", name: "历史" },
  { id: "27", name: "恐怖" },
  { id: "10402", name: "音乐" },
  { id: "9648", name: "悬疑" },
  { id: "10749", name: "爱情" },
  { id: "878", name: "科幻" },
  { id: "10770", name: "电视电影" },
  { id: "53", name: "惊悚" },
  { id: "10752", name: "战争" },
  { id: "37", name: "西部" }
];

var SERIES_GENRES = [
  { id: "10759", name: "动作冒险" },
  { id: "16", name: "动画" },
  { id: "35", name: "喜剧" },
  { id: "80", name: "犯罪" },
  { id: "99", name: "纪录" },
  { id: "18", name: "剧情" },
  { id: "10751", name: "家庭" },
  { id: "10762", name: "儿童" },
  { id: "9648", name: "悬疑" },
  { id: "10763", name: "新闻" },
  { id: "10764", name: "真人秀" },
  { id: "10765", name: "科幻奇幻" },
  { id: "10766", name: "肥皂剧" },
  { id: "10767", name: "脱口秀" },
  { id: "10768", name: "战争政治" },
  { id: "37", name: "西部" }
];

WidgetMetadata = {
  id: "rexhub.tmdb",
  title: "TMDB 影视资料",
  version: "1.0.0",
  requiredVersion: "0.0.1",
  author: "RexHub",
  site: "https://www.themoviedb.org",
  detailCacheDuration: 600,
  description: "TMDB 目录与详情：热门、正在上映、高分榜、分类片单、国别剧、动漫，支持搜索、完整演职员与全部分集",
  globalParams: [
    { name: "apiKey", title: "TMDB API Key", type: "input", value: "" },
    { name: "apiBase", title: "接口地址", type: "input", value: "https://api.themoviedb.org/3" },
    { name: "language", title: "语言", type: "input", value: "zh-CN" },
    { name: "region", title: "地区", type: "input", value: "CN" },
    { name: "imageBase", title: "图片地址", type: "input", value: "https://image.tmdb.org/t/p" }
  ],
  modules: [
    { id: "movie-trending", title: "热门电影", mediaType: "movie", functionName: "loadMovieTrending", cacheDuration: 300, params: [pageParam()] },
    { id: "movie-theaters", title: "正在上映", mediaType: "movie", functionName: "loadMovieTheaters", cacheDuration: 300, params: [pageParam()] },
    { id: "movie-upcoming", title: "即将上映", mediaType: "movie", functionName: "loadMovieUpcoming", cacheDuration: 600, params: [pageParam()] },
    { id: "movie-top", title: "高分电影", mediaType: "movie", functionName: "loadMovieTop", cacheDuration: 900, params: [pageParam()] },
    { id: "movie-animation", title: "动画电影", mediaType: "movie", functionName: "loadMovieAnimation", cacheDuration: 900, params: [pageParam()] },
    { id: "movie-action", title: "动作片", mediaType: "movie", functionName: "loadMovieAction", cacheDuration: 900, params: [pageParam()] },
    { id: "movie-comedy", title: "喜剧片", mediaType: "movie", functionName: "loadMovieComedy", cacheDuration: 900, params: [pageParam()] },
    { id: "movie-scifi", title: "科幻片", mediaType: "movie", functionName: "loadMovieScifi", cacheDuration: 900, params: [pageParam()] },
    { id: "movie-horror", title: "恐怖片", mediaType: "movie", functionName: "loadMovieHorror", cacheDuration: 900, params: [pageParam()] },
    { id: "movie-romance", title: "爱情片", mediaType: "movie", functionName: "loadMovieRomance", cacheDuration: 900, params: [pageParam()] },
    { id: "movie-documentary", title: "纪录片", mediaType: "movie", functionName: "loadMovieDocumentary", cacheDuration: 900, params: [pageParam()] },
    { id: "tv-trending", title: "热门剧集", mediaType: "series", functionName: "loadTvTrending", cacheDuration: 300, params: [pageParam()] },
    { id: "tv-airing", title: "今日播出", mediaType: "series", functionName: "loadTvAiring", cacheDuration: 300, params: [pageParam()] },
    { id: "tv-top", title: "高分剧集", mediaType: "series", functionName: "loadTvTop", cacheDuration: 900, params: [pageParam()] },
    { id: "tv-animation", title: "动漫", mediaType: "series", functionName: "loadTvAnimation", cacheDuration: 900, params: [pageParam()] },
    { id: "tv-cn", title: "国产剧", mediaType: "series", functionName: "loadTvCn", cacheDuration: 600, params: [pageParam()] },
    { id: "tv-kr", title: "韩剧", mediaType: "series", functionName: "loadTvKr", cacheDuration: 600, params: [pageParam()] },
    { id: "tv-jp", title: "日剧", mediaType: "series", functionName: "loadTvJp", cacheDuration: 600, params: [pageParam()] },
    { id: "discover", title: "分类筛选", mediaType: "movie", functionName: "loadDiscover", cacheDuration: 600, params: discoverParams() },
    { id: "person-works", title: "影人作品", type: "meta", functionName: "loadPersonWorks", cacheDuration: 600, params: [] },
    { id: "meta", title: "详情", type: "meta", functionName: "loadDetail", cacheDuration: 600, params: [] }
  ],
  search: {
    title: "搜索影视",
    functionName: "search",
    params: [{ name: "keyword", title: "关键词", type: "input" }, pageParam()]
  }
};

var DEFAULT_BASE = "https://api.themoviedb.org/3";
var DEFAULT_IMAGE = "https://image.tmdb.org/t/p";
var IMAGE_SIZES = { poster: "w500", backdrop: "w1280", logo: "w300", still: "w300" };

function pageParam() {
  return { name: "page", title: "页码", type: "page" };
}

function textValue(value) {
  return value == null ? "" : String(value).trim();
}

function positivePage(value) {
  var number = Number(value);
  if (!isFinite(number) || number < 1) return 1;
  number = Math.floor(number);
  return number > 500 ? 500 : number;
}

function settings(params) {
  params = params || {};
  var base = textValue(params.apiBase) || DEFAULT_BASE;
  var key = textValue(params.apiKey);
  if (base && !/^https?:\/\//i.test(base)) {
    if (!key) key = base;
    base = DEFAULT_BASE;
  }
  base = base.replace(/\/+$/, "");
  if (!/^https?:\/\//i.test(base)) throw new Error("接口地址需以 http(s):// 开头");
  if (!key && base === DEFAULT_BASE) {
    throw new Error("请填写 TMDB API Key：管理台 → 插件管理 → 编辑插件 → API Key / Token");
  }
  return {
    base: base,
    key: key,
    language: textValue(params.language) || "zh-CN",
    region: textValue(params.region) || "CN",
    imageBase: (textValue(params.imageBase) || DEFAULT_IMAGE).replace(/\/+$/, "")
  };
}

function imageUrl(ctx, path, kind) {
  var value = textValue(path);
  if (!value) return "";
  var size = IMAGE_SIZES[kind] || IMAGE_SIZES.poster;
  return ctx.imageBase + "/" + size + value;
}

function joinQuery(parts) {
  return parts.filter(function (item) { return item; }).join("&");
}

async function apiGet(ctx, path, query) {
  var url = ctx.base + path + "?" + joinQuery([
    "language=" + encodeURIComponent(ctx.language),
    query
  ]);
  var headers = { Accept: "application/json" };
  if (/^eyJ/.test(ctx.key)) {
    headers.Authorization = "Bearer " + ctx.key;
  } else if (ctx.key) {
    url += "&api_key=" + encodeURIComponent(ctx.key);
  }
  var response = await Widget.http.get(url, { headers: headers });
  var status = Number(response && (response.status || response.statusCode));
  var data = response && response.data;
  if (typeof data === "string") {
    try {
      data = JSON.parse(data);
    } catch (error) {
      throw new Error("TMDB 返回内容不是 JSON（HTTP " + status + "）");
    }
  }
  if (status && (status < 200 || status >= 300)) {
    var message = data && data.status_message ? "：" + data.status_message : "";
    throw new Error("TMDB HTTP " + status + message);
  }
  if (!data || typeof data !== "object") throw new Error("TMDB 未返回有效数据");
  return data;
}

function rating(value) {
  var number = Number(value);
  return isFinite(number) && number > 0 ? number.toFixed(1) : "";
}

function yearOf(value) {
  var text = textValue(value);
  return /^\d{4}/.test(text) ? text.slice(0, 4) : "";
}

function catalogItem(ctx, kind, data) {
  if (!data || !data.id) return null;
  var isMovie = kind === "movie";
  var title = textValue(isMovie ? data.title : data.name) ||
    textValue(isMovie ? data.original_title : data.original_name);
  if (!title) return null;
  return {
    id: "tmdb:" + kind + ":" + data.id,
    mediaType: isMovie ? "movie" : "series",
    title: title,
    coverUrl: imageUrl(ctx, data.poster_path, "poster"),
    background: imageUrl(ctx, data.backdrop_path, "backdrop"),
    description: textValue(data.overview),
    releaseInfo: yearOf(isMovie ? data.release_date : data.first_air_date),
    imdbRating: rating(data.vote_average)
  };
}

async function catalogList(params, path, kind, extra) {
  var ctx = settings(params);
  var page = positivePage(params.page);
  var data = await apiGet(ctx, path, joinQuery(["page=" + page, extra]));
  return (data.results || [])
    .map(function (entry) { return catalogItem(ctx, kind, entry); })
    .filter(function (item) { return item !== null; });
}

async function loadMovieTrending(params) {
  return catalogList(params, "/trending/movie/week", "movie", "");
}

async function loadMovieTheaters(params) {
  var ctx = settings(params);
  return catalogList(params, "/movie/now_playing", "movie", "region=" + encodeURIComponent(ctx.region));
}

async function loadMovieUpcoming(params) {
  var ctx = settings(params);
  return catalogList(params, "/movie/upcoming", "movie", "region=" + encodeURIComponent(ctx.region));
}

async function loadMovieTop(params) {
  return catalogList(params, "/movie/top_rated", "movie", "");
}

function discoverMovie(params, genre) {
  return catalogList(
    params,
    "/discover/movie",
    "movie",
    "with_genres=" + genre + "&sort_by=popularity.desc&vote_count.gte=50&include_adult=false"
  );
}

async function loadMovieAnimation(params) {
  return discoverMovie(params, "16");
}

async function loadMovieAction(params) {
  return discoverMovie(params, "28");
}

async function loadMovieComedy(params) {
  return discoverMovie(params, "35");
}

async function loadMovieScifi(params) {
  return discoverMovie(params, "878");
}

async function loadMovieHorror(params) {
  return discoverMovie(params, "27");
}

async function loadMovieRomance(params) {
  return discoverMovie(params, "10749");
}

async function loadMovieDocumentary(params) {
  return discoverMovie(params, "99");
}

async function loadTvTrending(params) {
  return catalogList(params, "/trending/tv/week", "tv", "");
}

async function loadTvAiring(params) {
  return catalogList(params, "/tv/on_the_air", "tv", "");
}

async function loadTvTop(params) {
  return catalogList(params, "/tv/top_rated", "tv", "");
}

async function loadTvAnimation(params) {
  return catalogList(
    params,
    "/discover/tv",
    "tv",
    "with_genres=16&sort_by=popularity.desc&vote_count.gte=30&include_adult=false"
  );
}

function discoverTv(params, country) {
  return catalogList(
    params,
    "/discover/tv",
    "tv",
    "with_origin_country=" + country + "&sort_by=popularity.desc&vote_count.gte=20&include_adult=false"
  );
}

async function loadTvCn(params) {
  return discoverTv(params, "CN");
}

async function loadTvKr(params) {
  return discoverTv(params, "KR");
}

async function loadTvJp(params) {
  return discoverTv(params, "JP");
}

async function search(params) {
  var keyword = textValue(params.keyword || params.search || params.q);
  if (!keyword) return [];
  var ctx = settings(params);
  var page = positivePage(params.page);
  var wanted = textValue(params.mediaType).toLowerCase();
  var data = await apiGet(
    ctx,
    "/search/multi",
    joinQuery(["query=" + encodeURIComponent(keyword), "page=" + page, "include_adult=false"])
  );
  return (data.results || [])
    .filter(function (entry) { return entry && (entry.media_type === "movie" || entry.media_type === "tv"); })
    .filter(function (entry) {
      if (wanted === "movie") return entry.media_type === "movie";
      if (wanted === "series" || wanted === "tv") return entry.media_type === "tv";
      return true;
    })
    .map(function (entry) { return catalogItem(ctx, entry.media_type, entry); })
    .filter(function (item) { return item !== null; });
}

function parseMediaId(value) {
  var text = textValue(value);
  // 兼容 tmdb:movie/123 与 tmdb:movie:123（旧分集格式 tmdb:tv:123:s:1:e:1）
  var matched = /^tmdb:(movie|tv)[/:](\d+)(?::\d+:\d+)?$/.exec(text);
  if (matched) return { kind: matched[1], id: matched[2] };
  var bare = /^(movie|tv)\/(\d+)$/.exec(text);
  if (bare) return { kind: bare[1], id: bare[2] };
  if (/^tt\d+$/.test(text)) return { kind: "", id: "", imdb: text };
  if (/^\d+$/.test(text)) return { kind: "movie", id: text };
  throw new Error("无法识别的内容 ID：" + text);
}

function pickLogo(ctx, images) {
  var logos = (images && images.logos) || [];
  var picked = logos.filter(function (item) { return item && item.file_path; })[0];
  return picked ? imageUrl(ctx, picked.file_path, "logo") : "";
}

function trailerList(videos) {
  return ((videos && videos.results) || [])
    .filter(function (item) {
      return item && item.site === "YouTube" && item.type === "Trailer" && item.key;
    })
    .slice(0, 3)
    .map(function (item) { return { source: item.key, type: "Trailer" }; });
}

function runtimeText(minutes) {
  var total = Number(minutes);
  if (!isFinite(total) || total <= 0) return "";
  var hours = Math.floor(total / 60);
  var rest = total % 60;
  if (!hours) return rest + " 分钟";
  return hours + " 小时" + (rest ? " " + rest + " 分钟" : "");
}

function movieMeta(ctx, data) {
  var credits = data.credits || {};
  var crew = credits.crew || [];
  var directors = crew
    .filter(function (person) { return person.job === "Director"; })
    .map(function (person) { return person.name; });
  var writers = crew
    .filter(function (person) { return person.job === "Screenplay" || person.job === "Writer"; })
    .slice(0, 3)
    .map(function (person) { return person.name; });
  var countries = (data.production_countries || []).map(function (item) { return item.name; });
  return {
    id: "tmdb:movie:" + data.id,
    mediaType: "movie",
    title: textValue(data.title) || textValue(data.original_title),
    description: textValue(data.overview) || "暂无简介",
    poster: imageUrl(ctx, data.poster_path, "poster"),
    background: imageUrl(ctx, data.backdrop_path, "backdrop"),
    logo: pickLogo(ctx, data.images),
    releaseInfo: yearOf(data.release_date),
    released: data.release_date ? data.release_date + "T00:00:00.000Z" : undefined,
    imdbRating: rating(data.vote_average),
    genres: (data.genres || []).map(function (item) { return item.name; }),
    runtime: runtimeText(data.runtime),
    cast: (credits.cast || []).slice(0, 12).map(function (person) { return person.name; }),
    director: directors,
    writer: writers,
    country: countries.join(" / "),
    trailers: trailerList(data.videos),
    tagline: textValue(data.tagline)
  };
}

function tvMeta(ctx, data) {
  var credits = data.aggregate_credits || data.credits || {};
  var cast = (credits.cast || []).slice(0, 12).map(function (person) { return person.name; });
  var crew = (credits.crew || []).filter(function (person) {
    return person.job === "Director" || person.job === "Executive Producer";
  });
  var first = yearOf(data.first_air_date);
  var last = yearOf(data.last_air_date);
  var years = first ? (last && last !== first ? first + "–" + last : first + "–") : "";
  var runtime = (data.episode_run_time || [])[0];
  return {
    id: "tmdb:tv:" + data.id,
    mediaType: "series",
    title: textValue(data.name) || textValue(data.original_name),
    description: textValue(data.overview) || "暂无简介",
    poster: imageUrl(ctx, data.poster_path, "poster"),
    background: imageUrl(ctx, data.backdrop_path, "backdrop"),
    logo: pickLogo(ctx, data.images),
    releaseInfo: years,
    released: data.first_air_date ? data.first_air_date + "T00:00:00.000Z" : undefined,
    imdbRating: rating(data.vote_average),
    genres: (data.genres || []).map(function (item) { return item.name; }),
    runtime: runtimeText(runtime),
    cast: cast,
    director: crew.slice(0, 4).map(function (person) { return person.name; }),
    country: (data.origin_country || []).join(" / "),
    trailers: trailerList(data.videos),
    tagline: textValue(data.tagline),
    status: textValue(data.status)
  };
}

function episodeMeta(ctx, showId, episode) {
  var id = "tmdb:tv:" + showId + ":" + episode.season_number + ":" + episode.episode_number;
  return {
    id: id,
    title: textValue(episode.name) || ("第 " + episode.episode_number + " 集"),
    season: episode.season_number,
    episode: episode.episode_number,
    released: episode.air_date ? episode.air_date + "T00:00:00.000Z" : undefined,
    overview: textValue(episode.overview),
    thumbnail: imageUrl(ctx, episode.still_path, "still"),
    rating: rating(episode.vote_average)
  };
}

async function seasonMeta(ctx, show) {
  var seasons = (show.seasons || [])
    .filter(function (item) {
      return item && item.season_number >= 0 && item.episode_count > 0;
    })
    .slice(0, 15);
  var videos = [];
  for (var index = 0; index < seasons.length; index += 1) {
    var season = seasons[index];
    try {
      var data = await apiGet(
        ctx,
        "/tv/" + show.id + "/season/" + season.season_number,
        ""
      );
      (data.episodes || []).forEach(function (episode) {
        if (episode && episode.episode_number) videos.push(episodeMeta(ctx, show.id, episode));
      });
    } catch (error) {
      console.warn("季信息获取失败：" + season.season_number + " " + error);
    }
  }
  return videos;
}

async function loadDetail(params) {
  var ctx = settings(params);
  var target = parseMediaId(params.id);
  var kind = target.kind;
  var contentId = target.id;
  if (target.imdb) {
    var found = await apiGet(ctx, "/find/" + encodeURIComponent(target.imdb), "external_source=imdb_id");
    var movie = (found.movie_results || [])[0];
    var show = (found.tv_results || [])[0];
    if (movie) {
      kind = "movie";
      contentId = movie.id;
    } else if (show) {
      kind = "tv";
      contentId = show.id;
    } else {
      throw new Error("TMDB 未找到该 IMDb 条目");
    }
  }
  if (kind === "tv") {
    var detail = await apiGet(
      ctx,
      "/tv/" + contentId,
      "append_to_response=credits,aggregate_credits,videos,images,external_ids,content_ratings&include_image_language=" +
        encodeURIComponent(ctx.language + ",en,null")
    );
    var meta = tvMeta(ctx, detail);
    meta.videos = await seasonMeta(ctx, detail);
    return meta;
  }
  var movieData = await apiGet(
    ctx,
    "/movie/" + contentId,
    "append_to_response=credits,videos,images,external_ids&include_image_language=" +
      encodeURIComponent(ctx.language + ",en,null")
  );
  return movieMeta(ctx, movieData);
}

function selectParam(name, title, options, defaultValue) {
  return { name: name, title: title, type: "select", options: options, value: defaultValue };
}

function genreOptions() {
  return MOVIE_GENRES.concat(SERIES_GENRES).map(function (item) {
    return { name: item.name, value: item.id };
  });
}

function discoverParams() {
  return [
    selectParam(
      "mediaType",
      "类型",
      [
        { name: "电影", value: "movie" },
        { name: "剧集", value: "series" }
      ],
      "movie"
    ),
    selectParam("genre", "片种", genreOptions(), ""),
    { name: "year", title: "年份", type: "input" },
    selectParam(
      "sortBy",
      "排序",
      [
        { name: "最受欢迎", value: "popular" },
        { name: "评分最高", value: "rating" },
        { name: "最新上映", value: "release" }
      ],
      "popular"
    ),
    pageParam()
  ];
}

async function loadDiscover(params) {
  var mediaType = textValue(params.mediaType).toLowerCase() === "series" ? "tv" : "movie";
  var sort = textValue(params.sortBy) || "popular";
  var sortBy;
  if (sort === "rating") {
    sortBy = "vote_average.desc";
  } else if (sort === "release") {
    sortBy = mediaType === "tv" ? "first_air_date.desc" : "primary_release_date.desc";
  } else {
    sortBy = "popularity.desc";
  }
  var extra = ["include_adult=false", "sort_by=" + sortBy];
  var genre = textValue(params.genre);
  if (genre) extra.push("with_genres=" + encodeURIComponent(genre));
  var year = textValue(params.year);
  if (/^\d{4}$/.test(year)) {
    extra.push((mediaType === "tv" ? "first_air_date_year=" : "primary_release_year=") + year);
  }
  if (sort === "rating") extra.push(mediaType === "tv" ? "vote_count.gte=200" : "vote_count.gte=300");
  if (sort === "release") extra.push("vote_count.gte=10");
  return catalogList(params, "/discover/" + mediaType, mediaType, extra.join("&"));
}

async function loadPersonWorks(params) {
  var ctx = settings(params);
  var text = textValue(params.id);
  var matched = /^tmdb:person\/(\d+)$/.exec(text) || /^(\d+)$/.exec(text);
  if (!matched) throw new Error("无法识别的影人 ID：" + text);
  var data = await apiGet(ctx, "/person/" + matched[1] + "/combined_credits", "");
  var rows = [].concat(data.cast || [], data.crew || []);
  rows.sort(function (a, b) {
    return (Number(b && b.popularity) || 0) - (Number(a && a.popularity) || 0);
  });
  var seen = {};
  var items = [];
  rows.forEach(function (entry) {
    if (!entry || !entry.id) return;
    var kind = entry.media_type === "tv" ? "tv" : "movie";
    var key = kind + ":" + entry.id;
    if (seen[key]) return;
    var item = catalogItem(ctx, kind, entry);
    if (!item) return;
    seen[key] = true;
    items.push(item);
  });
  return items;
}

function loadGenres() {
  return { movie: MOVIE_GENRES.slice(), series: SERIES_GENRES.slice() };
}