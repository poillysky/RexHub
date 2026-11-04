/**
 * RexHub 自建豆瓣插件
 *
 * 目录（10 个）：热门电影、热门剧集、一周口碑榜（j/search_subjects 无此榜单，用 Top250 替代）、
 *              豆瓣 Top250（HTML 解析）、高分电影、国产剧、韩剧、日剧、欧美剧、动漫（日本动画）
 * 搜索：subject_suggest + search_subjects 合并去重
 * 详情：rexxar v2 subject + credits（移动端 UA / Referer / Origin），返回结构与 TMDB 插件同形
 */
WidgetMetadata = {
  id: "rexhub.douban",
  title: "豆瓣影视",
  version: "1.0.0",
  requiredVersion: "0.0.1",
  author: "RexHub",
  site: "https://movie.douban.com",
  detailCacheDuration: 600,
  description: "豆瓣榜单目录与详情：热门、Top250、高分、国产/韩/日/欧美剧、动漫，支持搜索与演职员",
  modules: [
    { id: "douban-movie-hot", title: "热门电影", mediaType: "movie", functionName: "loadMovieHot", cacheDuration: 600, params: [pageParam()] },
    { id: "douban-tv-hot", title: "热门剧集", mediaType: "series", functionName: "loadTvHot", cacheDuration: 600, params: [pageParam()] },
    { id: "douban-movie-weekly", title: "一周口碑榜", mediaType: "movie", functionName: "loadMovieWeekly", cacheDuration: 900, params: [pageParam()] },
    { id: "douban-top250", title: "豆瓣 Top250", mediaType: "movie", functionName: "loadTop250", cacheDuration: 900, params: [pageParam()] },
    { id: "douban-movie-top", title: "高分电影", mediaType: "movie", functionName: "loadMovieTop", cacheDuration: 900, params: [pageParam()] },
    { id: "douban-tv-cn", title: "国产剧", mediaType: "series", functionName: "loadTvCn", cacheDuration: 900, params: [pageParam()] },
    { id: "douban-tv-kr", title: "韩剧", mediaType: "series", functionName: "loadTvKr", cacheDuration: 900, params: [pageParam()] },
    { id: "douban-tv-jp", title: "日剧", mediaType: "series", functionName: "loadTvJp", cacheDuration: 900, params: [pageParam()] },
    { id: "douban-tv-us", title: "欧美剧", mediaType: "series", functionName: "loadTvUs", cacheDuration: 900, params: [pageParam()] },
    { id: "douban-animation", title: "动漫", mediaType: "series", functionName: "loadAnimation", cacheDuration: 900, params: [pageParam()] },
    { id: "meta", title: "详情", type: "meta", functionName: "loadDetail", cacheDuration: 600, params: [] }
  ],
  search: {
    title: "搜索豆瓣影视",
    functionName: "search",
    params: [{ name: "keyword", title: "关键词", type: "input" }]
  }
};

var DOUBAN_PC_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";
var DOUBAN_MOBILE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) " +
  "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 " +
  "Mobile/15E148 Safari/604.1";

function pageParam() {
  return { name: "page", title: "页码", type: "page" };
}

function textValue(value) {
  return value == null ? "" : String(value).trim();
}

function pageOf(value, maxPage) {
  var number = Number(value);
  if (!isFinite(number) || number < 1) number = 1;
  number = Math.floor(number);
  return number > maxPage ? maxPage : number;
}

function ratingText(value) {
  var number = Number(value);
  return isFinite(number) && number > 0 ? number.toFixed(1) : "";
}

function yearOf(value) {
  var text = textValue(value);
  return /^\d{4}/.test(text) ? text.slice(0, 4) : "";
}

function normalizeCover(url) {
  var text = textValue(url);
  if (!text) return "";
  if (/^\/\//.test(text)) text = "https:" + text;
  // 豆瓣图床 img9 等常对桌面 Referer 返回挑战页；统一到较稳的 img3
  return text.replace(/^https?:\/\/img\d+\.doubanio\.com/i, "https://img3.doubanio.com");
}

function pcHeaders() {
  return {
    "User-Agent": DOUBAN_PC_UA,
    Referer: "https://movie.douban.com/",
    Accept: "application/json, text/plain, */*"
  };
}

function mobileHeaders(sid, kind) {
  return {
    "User-Agent": DOUBAN_MOBILE_UA,
    Referer: "https://m.douban.com/" + kind + "/subject/" + sid + "/",
    Origin: "https://m.douban.com",
    Accept: "application/json, text/plain, */*"
  };
}

async function httpGetJson(url, headers) {
  var response = await Widget.http.get(url, { headers: headers });
  var status = Number(response && (response.status || response.statusCode));
  if (status === 403 || status === 418 || status === 429) {
    throw new Error("豆瓣暂时拒绝访问（风控），请稍后再试");
  }
  if (status && (status < 200 || status >= 300)) {
    throw new Error("豆瓣返回 HTTP " + status);
  }
  var data = response && response.data;
  if (typeof data === "string") {
    try {
      data = JSON.parse(data);
    } catch (error) {
      throw new Error("豆瓣响应不是 JSON");
    }
  }
  if (!data) throw new Error("豆瓣未返回有效数据");
  return data;
}

function listItem(sid, mediaType, title, cover, year, rate) {
  var id = textValue(sid);
  if (!/^\d+$/.test(id)) return null;
  title = textValue(title);
  if (!title) return null;
  return {
    id: "douban:" + id,
    mediaType: mediaType,
    title: title,
    coverUrl: normalizeCover(cover),
    background: "",
    description: "",
    releaseInfo: yearOf(year),
    imdbRating: ratingText(rate)
  };
}

function subjectItem(row, mediaType) {
  if (!row || typeof row !== "object") return null;
  var rate = row.rate || row.rating || row.score;
  return listItem(row.id, mediaType, row.title, row.cover || row.cover_url, "", rate);
}

function suggestItem(row) {
  if (!row || typeof row !== "object") return null;
  var kind = textValue(row.type).toLowerCase();
  var mediaType = kind === "tv" || kind === "drama" || kind === "show" ? "series" : "movie";
  return listItem(row.id, mediaType, row.title, row.img || row.cover, row.year, "");
}

async function tagChart(params, typ, tag) {
  var page = pageOf(params.page, 50);
  var url =
    "https://movie.douban.com/j/search_subjects?type=" + typ +
    "&tag=" + encodeURIComponent(tag) +
    "&sort=recommend&page_limit=20&page_start=" + (page - 1) * 20;
  var data = await httpGetJson(url, pcHeaders());
  var mediaType = typ === "movie" ? "movie" : "series";
  var rows = (data && data.subjects) || [];
  return rows
    .map(function (row) { return subjectItem(row, mediaType); })
    .filter(function (item) { return item !== null; });
}

async function loadMovieHot(params) {
  return tagChart(params, "movie", "热门");
}

async function loadTvHot(params) {
  return tagChart(params, "tv", "热门");
}

async function loadMovieTop(params) {
  return tagChart(params, "movie", "豆瓣高分");
}

async function loadTvCn(params) {
  return tagChart(params, "tv", "国产剧");
}

async function loadTvKr(params) {
  return tagChart(params, "tv", "韩剧");
}

async function loadTvJp(params) {
  return tagChart(params, "tv", "日剧");
}

async function loadTvUs(params) {
  return tagChart(params, "tv", "欧美剧");
}

async function loadAnimation(params) {
  // 「动漫」标签已空；官网 TV 标签为「日本动画」
  return tagChart(params, "tv", "日本动画");
}

async function top250List(params) {
  var page = pageOf(params.page, 10);
  var url = "https://movie.douban.com/top250?start=" + (page - 1) * 25;
  var response = await Widget.http.get(url, {
    headers: { "User-Agent": DOUBAN_PC_UA, Referer: "https://movie.douban.com/" }
  });
  var status = Number(response && (response.status || response.statusCode));
  if (status === 403 || status === 418 || status === 429) {
    throw new Error("豆瓣暂时拒绝访问（风控），请稍后再试");
  }
  if (status && (status < 200 || status >= 300)) {
    throw new Error("豆瓣 Top250 返回 HTTP " + status);
  }
  var html = typeof (response && response.data) === "string" ? response.data : "";
  var items = [];
  var entry =
    /href="https:\/\/movie\.douban\.com\/subject\/(\d+)\/"[^>]*>\s*<img[^>]+alt="([^"]+)"[^>]+src="([^"]+)"/g;
  var match;
  while ((match = entry.exec(html)) !== null) {
    var chunk = html.slice(match.index, match.index + 2000);
    var rate = "";
    var rateMatch = /property="v:average">([\d.]+)</.exec(chunk);
    if (rateMatch) rate = rateMatch[1];
    var item = listItem(match[1], "movie", match[2], match[3], "", rate);
    if (item) items.push(item);
  }
  return items;
}

async function loadTop250(params) {
  return top250List(params);
}

// j/search_subjects 不提供一周口碑榜，按规划用 Top250 替代
async function loadMovieWeekly(params) {
  return top250List(params);
}

function parseSubjectId(value) {
  var text = textValue(value);
  var matched = /^douban:(\d+)$/.exec(text);
  if (matched) return matched[1];
  if (/^\d+$/.test(text)) return text;
  throw new Error("无法识别的内容 ID：" + text);
}

function nameOf(row) {
  if (row == null) return "";
  if (typeof row === "string") return textValue(row);
  return textValue(row && row.name);
}

function mergeNames(rows, into, limit) {
  (rows || []).forEach(function (row) {
    var name = nameOf(row);
    if (!name || into.indexOf(name) >= 0 || into.length >= limit) return;
    into.push(name);
  });
}

async function search(params) {
  var keyword = textValue(params.keyword || params.search || params.q);
  if (!keyword) return [];
  var items = [];
  var seen = {};
  function push(item) {
    if (!item || seen[item.id]) return;
    seen[item.id] = true;
    items.push(item);
  }
  try {
    var url = "https://movie.douban.com/j/subject_suggest?q=" + encodeURIComponent(keyword);
    var rows = await httpGetJson(url, pcHeaders());
    (rows || []).forEach(function (row) { push(suggestItem(row)); });
  } catch (error) {
    console.warn("subject_suggest 失败：" + error);
  }
  try {
    (await tagChart({ page: 1 }, "movie", keyword)).forEach(push);
  } catch (error) {
    console.warn("search_subjects movie 失败：" + error);
  }
  try {
    (await tagChart({ page: 1 }, "tv", keyword)).forEach(push);
  } catch (error) {
    console.warn("search_subjects tv 失败：" + error);
  }
  return items;
}

async function loadDetail(params) {
  var sid = parseSubjectId(params.id);
  var subject = await httpGetJson(
    "https://m.douban.com/rexxar/api/v2/subject/" + sid,
    mobileHeaders(sid, "movie")
  );
  if (!subject || !subject.id) throw new Error("豆瓣详情无效");

  var type = textValue(subject.type || subject.subtype).toLowerCase();
  var isTv = subject.is_tv === true || type === "tv" || type === "show";
  var kind = isTv ? "tv" : "movie";

  var cast = [];
  try {
    var credits = await httpGetJson(
      "https://m.douban.com/rexxar/api/v2/" + kind + "/" + sid + "/credits",
      mobileHeaders(sid, kind)
    );
    mergeNames((credits && credits.items) || [], cast, 12);
  } catch (error) {
    console.warn("豆瓣 credits 失败：" + error);
  }
  if (cast.length < 12) {
    mergeNames(subject.actors || [], cast, 12);
    mergeNames(subject.directors || [], cast, 12);
  }
  var director = [];
  mergeNames(subject.directors || [], director, 4);

  var pic = subject.pic || {};
  var poster = normalizeCover(pic.large || pic.normal || subject.cover_url || subject.cover);
  var episodesCount = Number(subject.episodes_count || subject.eps_count || subject.eps || 0);
  var year = yearOf(subject.year);
  return {
    id: "douban:" + sid,
    mediaType: isTv ? "series" : "movie",
    title: textValue(subject.title) || sid,
    description: textValue(subject.intro) || "暂无简介",
    poster: poster,
    background: poster,
    releaseInfo: year + (isTv && episodesCount > 0 ? " · 共 " + episodesCount + " 集" : ""),
    imdbRating: ratingText(subject.rating && subject.rating.value),
    genres: (subject.genres || []).map(textValue).filter(function (item) { return item; }).slice(0, 12),
    runtime: textValue((subject.durations || [])[0]),
    cast: cast,
    director: director,
    country: (subject.countries || []).map(textValue).filter(function (item) { return item; }).slice(0, 8).join(" / ")
  };
}
