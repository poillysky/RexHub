/**
 * RexHub 自建番剧插件（bgm.tv + Anilist）
 *
 * 目录（5 个）：bgm 新番时间表（/calendar）、bgm 番剧排行（/v0/subjects?sort=rank 不可用，
 *              按 Anilist SCORE_DESC 替代）、Anilist 热门 / 高分 / 本季新番
 * 详情：bgm:<id> 走 /v0/subjects/{id}；anilist:<id> 走 GraphQL Media(id:)
 * 返回条目形状与 TMDB 插件保持一致
 */
WidgetMetadata = {
  id: "rexhub.bangumi",
  title: "番剧放送",
  version: "1.0.0",
  requiredVersion: "0.0.1",
  author: "RexHub",
  site: "https://bgm.tv",
  detailCacheDuration: 600,
  description: "bgm.tv 新番时间表与详情 + Anilist 热门/高分/当季番剧目录与详情",
  modules: [
    { id: "bgm-tv-ongoing", title: "新番时间表", mediaType: "series", functionName: "loadBgmOngoing", cacheDuration: 600, params: [] },
    { id: "bgm-tv-top", title: "番剧排行", mediaType: "series", functionName: "loadBgmTop", cacheDuration: 900, params: [pageParam()] },
    { id: "anilist-trending", title: "Anilist 热门", mediaType: "series", functionName: "loadAnilistTrending", cacheDuration: 600, params: [pageParam()] },
    { id: "anilist-top", title: "Anilist 高分", mediaType: "series", functionName: "loadAnilistTop", cacheDuration: 900, params: [pageParam()] },
    { id: "anilist-season", title: "Anilist 本季", mediaType: "series", functionName: "loadAnilistSeason", cacheDuration: 600, params: [pageParam()] },
    { id: "meta", title: "详情", type: "meta", functionName: "loadDetail", cacheDuration: 600, params: [] }
  ]
};

var BGM_BASE = "https://api.bgm.tv";
var ANILIST_URL = "https://graphql.anilist.co";
// bgm.tv 要求能识别应用身份的 UA（含名称/版本与联系方式）
var BGM_UA = "RexHub/1.0 (rexhub@example.com)";
var ANILIST_FIELDS =
  "id title { romaji english native } coverImage { large } bannerImage " +
  "averageScore startDate { year } episodes genres description format status";

function pageParam() {
  return { name: "page", title: "页码", type: "page" };
}

function textValue(value) {
  return value == null ? "" : String(value).trim();
}

function pageOf(value) {
  var number = Number(value);
  if (!isFinite(number) || number < 1) return 1;
  number = Math.floor(number);
  return number > 50 ? 50 : number;
}

function ratingText(value) {
  var number = Number(value);
  return isFinite(number) && number > 0 ? number.toFixed(1) : "";
}

function yearOf(value) {
  var text = textValue(value);
  return /^\d{4}/.test(text) ? text.slice(0, 4) : "";
}

function stripHtml(value) {
  return textValue(value)
    .replace(/<[^>]*>/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

async function bgmGet(url) {
  var response = await Widget.http.get(url, {
    headers: { "User-Agent": BGM_UA, Accept: "application/json" }
  });
  var status = Number(response && (response.status || response.statusCode));
  if (status && (status < 200 || status >= 300)) {
    throw new Error("bgm.tv 返回 HTTP " + status);
  }
  var data = response && response.data;
  if (typeof data === "string") {
    try {
      data = JSON.parse(data);
    } catch (error) {
      throw new Error("bgm.tv 响应不是 JSON");
    }
  }
  if (!data) throw new Error("bgm.tv 未返回有效数据");
  return data;
}

function bgmItem(row) {
  if (!row || !row.id) return null;
  var title = textValue(row.name_cn) || textValue(row.name);
  if (!title) return null;
  var images = row.images || {};
  var rating = row.rating || {};
  return {
    id: "bgm:" + row.id,
    mediaType: "series",
    title: title,
    coverUrl: textValue(images.large || images.common || images.medium || images.small),
    background: "",
    description: stripHtml(row.summary),
    releaseInfo: yearOf(row.date || row.air_date),
    imdbRating: ratingText(rating.score)
  };
}

async function loadBgmOngoing() {
  // 每日放送时间表在旧版 API：GET /calendar（/v0 无此端点）。
  // bgm.tv 不可达时回退 Anilist「当季放送中」。
  try {
    var rows = await bgmGet(BGM_BASE + "/calendar");
    var items = [];
    (rows || []).forEach(function (day) {
      ((day && day.items) || []).forEach(function (row) {
        var item = bgmItem(row);
        if (item) items.push(item);
      });
    });
    if (items.length) return items;
  } catch (error) {
    console.warn("bgm /calendar 不可用，回退 Anilist：" + error);
  }
  var season = currentSeason();
  return anilistList(
    "POPULARITY_DESC",
    1,
    ", season: " + season.season + ", seasonYear: " + season.year +
      ", status: RELEASING"
  );
}

async function loadBgmTop(params) {
  var page = pageOf(params.page);
  // /v0/subjects?sort=rank 需要关键词才返回数据（无关键词为空），按规划回退 Anilist 高分
  try {
    var rows = await bgmGet(
      BGM_BASE + "/v0/subjects?sort=rank&limit=20&offset=" + (page - 1) * 20
    );
    if (Array.isArray(rows) && rows.length) {
      var items = rows.map(bgmItem).filter(function (item) { return item !== null; });
      if (items.length) return items;
    }
  } catch (error) {
    console.warn("bgm /v0/subjects?sort=rank 不可用：" + error);
  }
  return anilistList("SCORE_DESC", page, "");
}

async function anilistQuery(query, variables) {
  var response = await Widget.http.post(ANILIST_URL, {
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ query: query, variables: variables || {} })
  });
  var status = Number(response && (response.status || response.statusCode));
  if (status && (status < 200 || status >= 300)) {
    throw new Error("Anilist 返回 HTTP " + status);
  }
  var data = response && response.data;
  if (typeof data === "string") {
    try {
      data = JSON.parse(data);
    } catch (error) {
      throw new Error("Anilist 响应不是 JSON");
    }
  }
  if (data && data.errors && data.errors.length) {
    throw new Error("Anilist 错误：" + (data.errors[0] && data.errors[0].message));
  }
  if (!data || !data.data) throw new Error("Anilist 未返回有效数据");
  return data.data;
}

function anilistItem(row) {
  if (!row || !row.id) return null;
  var title = row.title || {};
  var name = textValue(title.romaji) || textValue(title.native) || textValue(title.english);
  if (!name) return null;
  return {
    id: "anilist:" + row.id,
    mediaType: "series",
    title: name,
    coverUrl: textValue(row.coverImage && row.coverImage.large),
    background: textValue(row.bannerImage),
    description: stripHtml(row.description),
    releaseInfo: row.startDate ? yearOf(row.startDate.year) : "",
    imdbRating: ratingText(row.averageScore ? row.averageScore / 10 : 0)
  };
}

async function anilistList(sort, page, seasonArgs) {
  var query =
    "query ($page: Int) { Page(page: $page, perPage: 20) { media(type: ANIME, sort: " +
    sort + seasonArgs + ") { " + ANILIST_FIELDS + " } } }";
  var data = await anilistQuery(query, { page: page });
  var rows = ((data.Page || {}).media) || [];
  return rows.map(anilistItem).filter(function (item) { return item !== null; });
}

function currentSeason() {
  var now = new Date();
  var month = now.getUTCMonth() + 1;
  var year = now.getUTCFullYear();
  var names = ["WINTER", "SPRING", "SUMMER", "FALL"];
  var index = Math.floor((month - 1) / 3);
  if (month === 12) {
    index = 0;
    year += 1;
  }
  return { season: names[index], year: year };
}

async function loadAnilistTrending(params) {
  return anilistList("TRENDING_DESC", pageOf(params.page), "");
}

async function loadAnilistTop(params) {
  return anilistList("SCORE_DESC", pageOf(params.page), "");
}

async function loadAnilistSeason(params) {
  var season = currentSeason();
  return anilistList(
    "POPULARITY_DESC",
    pageOf(params.page),
    ", season: " + season.season + ", seasonYear: " + season.year
  );
}

async function bgmDetail(id) {
  var row = await bgmGet(BGM_BASE + "/v0/subjects/" + id);
  if (!row || !row.id) throw new Error("bgm.tv 详情无效");
  var tags = (row.tags || [])
    .map(function (tag) { return textValue(tag && tag.name); })
    .filter(function (item) { return item; })
    .slice(0, 8);
  var images = row.images || {};
  var rating = row.rating || {};
  var meta = {
    id: "bgm:" + id,
    mediaType: "series",
    title: textValue(row.name_cn) || textValue(row.name) || id,
    description: stripHtml(row.summary) || "暂无简介",
    poster: textValue(images.large || images.common || images.medium),
    background: "",
    releaseInfo: yearOf(row.date),
    imdbRating: ratingText(rating.score),
    genres: tags
  };
  var episodesCount = Number(row.eps || 0);
  if (episodesCount > 0) {
    meta.releaseInfo = meta.releaseInfo + " · 共 " + episodesCount + " 集";
  }
  return meta;
}

async function anilistDetail(id) {
  var query =
    "query ($id: Int) { Media(id: $id, type: ANIME) { " + ANILIST_FIELDS + " } }";
  var data = await anilistQuery(query, { id: Number(id) });
  var row = (data.Media || {});
  var title = row.title || {};
  var meta = anilistItem(row);
  if (!meta) throw new Error("Anilist 详情无效");
  meta.id = "anilist:" + id;
  meta.description = meta.description || "暂无简介";
  meta.title = textValue(title.romaji) || textValue(title.english) || textValue(title.native);
  return meta;
}

async function loadDetail(params) {
  var text = textValue(params.id);
  var bgm = /^bgm:(\d+)$/.exec(text);
  if (bgm) return bgmDetail(bgm[1]);
  var anilist = /^anilist:(\d+)$/.exec(text);
  if (anilist) return anilistDetail(anilist[1]);
  throw new Error("无法识别的内容 ID：" + text);
}
