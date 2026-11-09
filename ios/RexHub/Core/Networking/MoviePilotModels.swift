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
