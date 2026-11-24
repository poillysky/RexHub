import Foundation

// MARK: - MoviePilot 影视模型

/// 服务端已把 MoviePilot 的条目归一成统一 MediaItem 结构。
struct MpItem: Decodable, Identifiable, Hashable, Sendable {
    let source: String
    let id: String
    let mediaType: String
    let title: String
    let originalTitle: String?
    let aka: [String]
    let posterUrl: String?
    let year: String?
    let rating: Double?
    let overview: String?

    var uniqueID: String { "\(source):\(id)" }
    var isTV: Bool { mediaType == "tv" }

    /// 海报卡左上角类别字，对齐 PWA 的 `MEDIA_CATEGORY_MARK`。
    var categoryMark: String {
        switch mediaType {
        case "tv": "剧"
        case "anime", "animation": "漫"
        case "variety": "综"
        default: "影"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case source, id, mediaType, title, originalTitle, aka
        case posterUrl, year, rating, overview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = container.rexString(.source) ?? ""
        id = container.rexString(.id) ?? ""
        mediaType = container.rexString(.mediaType) ?? "movie"
        title = container.rexString(.title) ?? "未命名"
        originalTitle = container.rexString(.originalTitle)
        aka = container.rexArray(.aka, as: String.self)
        posterUrl = container.rexString(.posterUrl)
        year = container.rexString(.year)
        rating = container.rexDouble(.rating)
        overview = container.rexString(.overview)
    }
}

struct MpCast: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, avatarUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        name = container.rexString(.name) ?? ""
        avatarUrl = container.rexString(.avatarUrl)
    }
}

struct MpDetail: Decodable, Sendable {
    let source: String
    let id: String
    let mediaType: String
    let title: String
    let originalTitle: String?
    let aka: [String]
    let posterUrl: String?
    let year: String?
    let rating: Double?
    let overview: String?
    let cast: [MpCast]
    let genres: [String]
    let runtime: Int?
    let countries: [String]
    let imdbId: String?

    private enum CodingKeys: String, CodingKey {
        case source, id, mediaType, title, originalTitle, aka
        case posterUrl, year, rating, overview, cast, genres
        case runtime, countries, imdbId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = container.rexString(.source) ?? ""
        id = container.rexString(.id) ?? ""
        mediaType = container.rexString(.mediaType) ?? "movie"
        title = container.rexString(.title) ?? "未命名"
        originalTitle = container.rexString(.originalTitle)
        aka = container.rexArray(.aka, as: String.self)
        posterUrl = container.rexString(.posterUrl)
        year = container.rexString(.year)
        rating = container.rexDouble(.rating)
        overview = container.rexString(.overview)
        cast = container.rexArray(.cast, as: MpCast.self)
        genres = container.rexArray(.genres, as: String.self)
        runtime = container.rexInt(.runtime)
        countries = container.rexArray(.countries, as: String.self)
        imdbId = container.rexString(.imdbId)
    }
}

struct MpListResult: Decodable, Sendable {
    let path: String
    let items: [MpItem]
    let total: Int

    private enum CodingKeys: String, CodingKey {
        case path, items, total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = container.rexString(.path) ?? ""
        items = container.rexArray(.items, as: MpItem.self)
        total = container.rexInt(.total) ?? items.count
    }
}

struct MpRelated: Decodable, Sendable {
    let similar: [MpItem]
    let recommendations: [MpItem]

    private enum CodingKeys: String, CodingKey {
        case similar, recommendations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        similar = container.rexArray(.similar, as: MpItem.self)
        recommendations = container.rexArray(.recommendations, as: MpItem.self)
    }
}

struct MpSearchResult: Decodable, Sendable {
    let source: String
    let keyword: String
    let page: Int
    let items: [MpItem]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case source, keyword, page, items, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = container.rexString(.source) ?? ""
        keyword = container.rexString(.keyword) ?? ""
        page = container.rexInt(.page) ?? 1
        items = container.rexArray(.items, as: MpItem.self)
        hasMore = container.rexBool(.hasMore) ?? false
    }
}

// MARK: - 影人

/// 影视影人资料：`GET /moviepilot/person`。
struct MpPerson: Decodable, Sendable {
    let source: String
    let id: String
    let name: String
    let originalName: String?
    let avatarUrl: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let gender: String?
    let department: String?
    let aliases: [String]
    let biography: String?
    let imdbId: String?

    private enum CodingKeys: String, CodingKey {
        case source, id, name, originalName, avatarUrl
        case birthday, deathday, placeOfBirth, gender, department
        case aliases, biography, imdbId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = container.rexString(.source) ?? ""
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
        originalName = container.rexString(.originalName)
        avatarUrl = container.rexString(.avatarUrl)
        birthday = container.rexString(.birthday)
        deathday = container.rexString(.deathday)
        placeOfBirth = container.rexString(.placeOfBirth)
        gender = container.rexString(.gender)
        department = container.rexString(.department)
        aliases = container.rexArray(.aliases, as: String.self)
        biography = container.rexString(.biography)
        imdbId = container.rexString(.imdbId)
    }
}

/// 影人作品分页：`GET /moviepilot/person/credits`。
struct MpPersonWorksPage: Decodable, Sendable {
    let personId: String
    let page: Int
    let items: [MpItem]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case personId, page, items, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        personId = container.rexString(.personId) ?? ""
        page = container.rexInt(.page) ?? 1
        items = container.rexArray(.items, as: MpItem.self)
        hasMore = container.rexBool(.hasMore) ?? false
    }
}

// MARK: - 影视片源

struct MediaStreamItem: Decodable, Identifiable, Hashable, Sendable {
    let addon: String
    let name: String
    let title: String
    let url: String
    let externalUrl: String
    let infoHash: String
    let filename: String
    let kind: String
    let playable: Bool

    var id: String { url + infoHash + title }

    var displayTitle: String {
        let value = name.isEmpty ? title : name
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? "片源" : value
    }

    var provider: String {
        addon.trimmingCharacters(in: .whitespaces).isEmpty ? "片源" : addon
    }

    private enum CodingKeys: String, CodingKey {
        case addon, name, title, url, externalUrl, infoHash
        case filename, kind, playable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addon = container.rexString(.addon) ?? ""
        name = container.rexString(.name) ?? ""
        title = container.rexString(.title) ?? ""
        url = container.rexString(.url) ?? ""
        externalUrl = container.rexString(.externalUrl) ?? ""
        infoHash = container.rexString(.infoHash) ?? ""
        filename = container.rexString(.filename) ?? ""
        kind = container.rexString(.kind) ?? ""
        playable = container.rexBool(.playable) ?? false
    }
}

struct MediaStreamsResult: Decodable, Sendable {
    let streams: [MediaStreamItem]
    let total: Int
    let addons: Int
    let reason: String

    private enum CodingKeys: String, CodingKey {
        case streams, total, addons, reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = container.rexArray(.streams, as: MediaStreamItem.self)
        total = container.rexInt(.total) ?? streams.count
        addons = container.rexInt(.addons) ?? 0
        reason = container.rexString(.reason) ?? ""
    }
}

/// 流式片源的 NDJSON 事件：命中一个站点下发一批线路，最后 `done` 带上结束原因。
enum MediaStreamsLiveEvent: Decodable, Sendable {
    case site([MediaStreamItem])
    case done(reason: String)

    private enum CodingKeys: String, CodingKey {
        case type, reason, streams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "site":
            let items = (try? container.decode([MediaStreamItem].self, forKey: .streams)) ?? []
            self = .site(items)
        case "done":
            self = .done(reason: (try? container.decode(String.self, forKey: .reason)) ?? "")
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "unknown event \(type)")
            )
        }
    }
}

// MARK: - PT 资源搜索

/// 合并资源下的单个站点来源：支持查看各站体积/做种，并从指定站点单独下载。
struct MpTorrentSource: Decodable, Identifiable, Sendable {
    let site: String
    let size: Double?
    let seeders: Int
    let peers: Int
    let volumeFactor: String?
    let downloadVolumeFactor: Double?
    let hitAndRun: Bool
    let pageUrl: String?
    let downloadKey: String?

    var id: String {
        if let downloadKey, !downloadKey.isEmpty { return downloadKey }
        return "\(site)|\(size ?? 0)"
    }

    private enum CodingKeys: String, CodingKey {
        case site, size, seeders, peers, volumeFactor
        case downloadVolumeFactor, hitAndRun, pageUrl, downloadKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = container.rexString(.site) ?? ""
        size = container.rexDouble(.size)
        seeders = container.rexInt(.seeders) ?? 0
        peers = container.rexInt(.peers) ?? 0
        volumeFactor = container.rexString(.volumeFactor)
        downloadVolumeFactor = container.rexDouble(.downloadVolumeFactor)
        hitAndRun = container.rexBool(.hitAndRun) ?? false
        pageUrl = container.rexString(.pageUrl)
        downloadKey = container.rexString(.downloadKey)
    }
}

/// PT 站点返回的单条资源：`GET /moviepilot/search`。
struct MpTorrentItem: Decodable, Identifiable, Sendable {
    let site: String
    let sites: [String]
    let variants: [MpTorrentSource]
    let title: String
    let description: String?
    let category: String?
    let size: Double?
    let seeders: Int
    let peers: Int
    let grabs: Int
    let pubdate: String?
    let dateElapsed: String?
    let volumeFactor: String?
    let seasonEpisode: String?
    let releaseGroup: String?
    let webSource: String?
    let edition: String?
    let resolution: String?
    let videoCode: String?
    let downloadVolumeFactor: Double?
    let hitAndRun: Bool
    let labels: [String]
    let pageUrl: String?
    let downloadUrl: String?
    let downloadKey: String?

    /// 跨站合并后的站点列表：优先 `sites`，回退 `site`。
    var siteNames: [String] {
        let merged = sites.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !merged.isEmpty { return merged }
        return site.isEmpty ? [] : [site]
    }

    var id: String {
        if let downloadKey, !downloadKey.isEmpty { return downloadKey }
        return "\(site)|\(title)|\(size ?? 0)"
    }

    private enum CodingKeys: String, CodingKey {
        case site, sites, variants, title, description, category, size
        case seeders, peers, grabs, pubdate, dateElapsed, volumeFactor
        case seasonEpisode, releaseGroup, webSource, edition
        case resolution, videoCode, downloadVolumeFactor
        case hitAndRun, labels, pageUrl, downloadUrl, downloadKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = container.rexString(.site) ?? ""
        sites = container.rexArray(.sites, as: String.self)
        variants = container.rexArray(.variants, as: MpTorrentSource.self)
        title = container.rexString(.title) ?? ""
        description = container.rexString(.description)
        category = container.rexString(.category)
        size = container.rexDouble(.size)
        seeders = container.rexInt(.seeders) ?? 0
        peers = container.rexInt(.peers) ?? 0
        grabs = container.rexInt(.grabs) ?? 0
        pubdate = container.rexString(.pubdate)
        dateElapsed = container.rexString(.dateElapsed)
        volumeFactor = container.rexString(.volumeFactor)
        seasonEpisode = container.rexString(.seasonEpisode)
        releaseGroup = container.rexString(.releaseGroup)
        webSource = container.rexString(.webSource)
        edition = container.rexString(.edition)
        resolution = container.rexString(.resolution)
        videoCode = container.rexString(.videoCode)
        downloadVolumeFactor = container.rexDouble(.downloadVolumeFactor)
        hitAndRun = container.rexBool(.hitAndRun) ?? false
        labels = container.rexArray(.labels, as: String.self)
        pageUrl = container.rexString(.pageUrl)
        downloadUrl = container.rexString(.downloadUrl)
        downloadKey = container.rexString(.downloadKey)
    }
}

/// PT 搜索结果：`GET /moviepilot/search`。
struct MpTorrentSearchResult: Decodable, Sendable {
    let keyword: String
    let mode: String
    let page: Int
    let items: [MpTorrentItem]
    let total: Int

    private enum CodingKeys: String, CodingKey {
        case keyword, mode, page, items, total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyword = container.rexString(.keyword) ?? ""
        mode = container.rexString(.mode) ?? ""
        page = container.rexInt(.page) ?? 1
        items = container.rexArray(.items, as: MpTorrentItem.self)
        total = container.rexInt(.total) ?? items.count
    }
}

/// 提交下载结果：`POST /moviepilot/download`。
struct MpDownloadTask: Decodable, Sendable {
    let downloadId: String
    let title: String
    let site: String

    private enum CodingKeys: String, CodingKey {
        case downloadId, title, site
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadId = container.rexString(.downloadId) ?? ""
        title = container.rexString(.title) ?? ""
        site = container.rexString(.site) ?? ""
    }
}

/// 下载任务状态：`GET /moviepilot/download/status`。
struct MpDownloadStatus: Decodable, Sendable {
    let found: Bool
    let hash: String?
    let title: String?
    let state: String?
    let progress: Double?
    let size: Double?
    let downloader: String?
    let dlspeed: String?
    let leftTime: String?

    private enum CodingKeys: String, CodingKey {
        case found, hash, title, state, progress, size
        case downloader, dlspeed, leftTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = container.rexBool(.found) ?? false
        hash = container.rexString(.hash)
        title = container.rexString(.title)
        state = container.rexString(.state)
        progress = container.rexDouble(.progress)
        size = container.rexDouble(.size)
        downloader = container.rexString(.downloader)
        dlspeed = container.rexString(.dlspeed)
        leftTime = container.rexString(.leftTime)
    }
}

// MARK: - 影视分区数据源

/// 与 PWA 的 `hubShelvesFor` 对齐：电影 / 剧集 / 动漫三组推荐栏目。
struct MoviePilotShelf: Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
    let params: [String: String]
}

enum MoviePilotTab: String, CaseIterable, Identifiable {
    case movie
    case tv
    case anime
    case rank
    case explore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie: "电影"
        case .tv: "电视剧"
        case .anime: "动漫"
        case .rank: "榜单"
        case .explore: "探索"
        }
    }

    var shelves: [MoviePilotShelf] {
        switch self {
        case .movie:
            [
                MoviePilotShelf(id: "showing", title: "正在热映", path: "recommend/douban_showing", params: ["page": "1", "count": "30"]),
                MoviePilotShelf(id: "tmdb_movies", title: "TMDB 热门电影", path: "recommend/tmdb_movies", params: ["page": "1", "sort_by": "popularity.desc"]),
                MoviePilotShelf(id: "movie_hot", title: "豆瓣热门电影", path: "recommend/douban_movie_hot", params: ["page": "1", "count": "30"]),
                MoviePilotShelf(id: "movie_new", title: "豆瓣最新电影", path: "recommend/douban_movies", params: ["page": "1", "count": "30", "sort": "R"])
            ]
        case .tv:
            [
                MoviePilotShelf(id: "tmdb_tvs", title: "TMDB 热门电视剧", path: "recommend/tmdb_tvs", params: ["page": "1", "sort_by": "popularity.desc", "with_original_language": "zh|en|ja|ko"]),
                MoviePilotShelf(id: "tv_hot", title: "豆瓣热门电视剧", path: "recommend/douban_tv_hot", params: ["page": "1", "count": "30"]),
                MoviePilotShelf(id: "tv_new", title: "豆瓣最新电视剧", path: "recommend/douban_tvs", params: ["page": "1", "count": "30", "sort": "R"])
            ]
        case .anime:
            [
                MoviePilotShelf(id: "calendar", title: "Bangumi 每日放送", path: "recommend/bangumi_calendar", params: ["page": "1", "count": "30"]),
                MoviePilotShelf(id: "anilist_trending", title: "AniList 当前趋势", path: "anilist/trending", params: ["page": "1", "count": "20"]),
                MoviePilotShelf(id: "anilist_season", title: "AniList 本季热门", path: "anilist/popular-this-season", params: ["page": "1", "count": "20"]),
                MoviePilotShelf(id: "anime_hot", title: "豆瓣热门动漫", path: "recommend/douban_tv_animation", params: ["page": "1", "count": "30"])
            ]
        case .rank:
            [
                MoviePilotShelf(id: "trending", title: "流行趋势", path: "recommend/tmdb_trending", params: ["page": "1"]),
                MoviePilotShelf(id: "top250", title: "豆瓣电影 TOP250", path: "recommend/douban_movie_top250", params: ["page": "1", "count": "30"]),
                MoviePilotShelf(id: "tv_cn", title: "豆瓣国产剧集榜", path: "recommend/douban_tv_weekly_chinese", params: ["page": "1", "count": "30"]),
                MoviePilotShelf(id: "tv_global", title: "豆瓣全球剧集榜", path: "recommend/douban_tv_weekly_global", params: ["page": "1", "count": "30"])
            ]
        case .explore:
            []
        }
    }
}
