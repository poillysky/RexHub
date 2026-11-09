import Foundation

// MARK: - 片商（AVDB）领域模型

/// AVDB 榜单类别：0 有码 / 1 无码 / 2 欧美 / 3 FC2 / 4 动漫。
enum MakerCategory: String, CaseIterable, Identifiable, Sendable {
    case censored = "0"
    case uncensored = "1"
    case western = "2"
    case fc2 = "3"
    case anime = "4"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .censored: "有码"
        case .uncensored: "无码"
        case .western: "欧美"
        case .fc2: "FC2"
        case .anime: "动漫"
        }
    }

    /// AVDB 只为前四类提供独立榜单。
    var hasRank: Bool { self != .anime }
}

enum MakerPeriod: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "日榜"
        case .weekly: "周榜"
        case .monthly: "月榜"
        }
    }

    /// 热播页的口径：今日 / 本周 / 本月。
    var playbackTitle: String {
        switch self {
        case .daily: "今日"
        case .weekly: "本周"
        case .monthly: "本月"
        }
    }
}

enum MakerLatestSort: String, Sendable {
    case update
    case release
}

enum MakerLatestFilter: String, Sendable {
    case all
    case magnets
    case subtitle
}

/// 影片卡片。字段全部按需容错：AVDB 偶尔会缺标题或封面。
struct MakerMovie: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let number: String
    let title: String
    let coverUrl: String?
    let thumbUrl: String?
    let previewUrl: String?
    let releaseDate: String?
    let duration: Double?
    let magnetsCount: Int
    let hasCnsub: Bool

    /// 卡片优先用竖版封面，其次缩略图，最后才是横版预览图。
    var artworkURL: String? {
        let candidates = [coverUrl, thumbUrl, previewUrl]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// 详情头部优先横版预览图，画面更宽，适合做背景。
    var heroURL: String? {
        let candidates = [previewUrl, coverUrl, thumbUrl]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !number.isEmpty { return number }
        return "未命名影片"
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, title
        case coverUrl, thumbUrl, previewUrl
        case releaseDate, duration
        case magnetsCount, hasCnsub
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        number = container.rexString(.number) ?? ""
        title = container.rexString(.title) ?? ""
        coverUrl = container.rexString(.coverUrl)
        thumbUrl = container.rexString(.thumbUrl)
        previewUrl = container.rexString(.previewUrl)
        releaseDate = container.rexString(.releaseDate)
        duration = container.rexDouble(.duration)
        magnetsCount = container.rexInt(.magnetsCount) ?? 0
        hasCnsub = container.rexBool(.hasCnsub) ?? false
    }
}

struct MakerRankPage: Decodable, Sendable {
    let category: String
    let categoryLabel: String
    let period: String
    let periodLabel: String
    let supported: Bool
    let items: [MakerMovie]

    private enum CodingKeys: String, CodingKey {
        case category, categoryLabel, period, periodLabel, supported, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = container.rexString(.category) ?? ""
        categoryLabel = container.rexString(.categoryLabel) ?? ""
        period = container.rexString(.period) ?? ""
        periodLabel = container.rexString(.periodLabel) ?? ""
        supported = container.rexBool(.supported) ?? true
        items = container.rexArray(.items, as: MakerMovie.self)
    }
}

struct MakerMoviePage: Decodable, Sendable {
    let page: Int
    let items: [MakerMovie]
    let hasMore: Bool
    let filterLabel: String?
    let categoryLabel: String?

    init(
        page: Int,
        items: [MakerMovie],
        hasMore: Bool,
        filterLabel: String? = nil,
        categoryLabel: String? = nil
    ) {
        self.page = page
        self.items = items
        self.hasMore = hasMore
        self.filterLabel = filterLabel
        self.categoryLabel = categoryLabel
    }

    private enum CodingKeys: String, CodingKey {
        case page, items, hasMore, filterLabel, categoryLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = container.rexInt(.page) ?? 1
        items = container.rexArray(.items, as: MakerMovie.self)
        hasMore = container.rexBool(.hasMore) ?? false
        filterLabel = container.rexString(.filterLabel)
        categoryLabel = container.rexString(.categoryLabel)
    }
}

struct MakerActorPage: Decodable, Sendable {
    let items: [MakerActor]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case items, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.rexArray(.items, as: MakerActor.self)
        hasMore = container.rexBool(.hasMore) ?? false
    }
}

struct MakerRecentViewed: Decodable, Sendable {
    let items: [MakerMovie]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.rexArray(.items, as: MakerMovie.self)
    }
}

struct MakerTag: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case id, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
    }
}

struct MakerTagGroup: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let tags: [MakerTag]

    private enum CodingKeys: String, CodingKey {
        case id, name, tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
        tags = container.rexArray(.tags, as: MakerTag.self)
    }
}

struct MakerTagsPage: Decodable, Sendable {
    let category: String
    let categoryLabel: String
    let categories: [MakerTagGroup]

    private enum CodingKeys: String, CodingKey {
        case category, categoryLabel, categories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = container.rexString(.category) ?? ""
        categoryLabel = container.rexString(.categoryLabel) ?? ""
        categories = container.rexArray(.categories, as: MakerTagGroup.self)
    }
}

struct MakerNamed: Decodable, Hashable, Sendable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case id, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
    }
}

struct MakerActor: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let avatarUrl: String?
    let videosCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, avatarUrl, videosCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
        avatarUrl = container.rexString(.avatarUrl)
        videosCount = container.rexInt(.videosCount) ?? 0
    }
}

struct MakerMagnet: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let url: String
    let size: String?
    let sizeBytes: Int64
    let createdAt: String?
    let filesCount: Int

    var id: String { url }

    private enum CodingKeys: String, CodingKey {
        case name, url, size, sizeBytes, createdAt, filesCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.rexString(.name) ?? "磁力链接"
        url = container.rexString(.url) ?? ""
        size = container.rexString(.size)
        sizeBytes = container.rexInt64(.sizeBytes) ?? 0
        createdAt = container.rexString(.createdAt)
        filesCount = container.rexInt(.filesCount) ?? 0
    }
}

struct MakerResource: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let url: String
    let name: String
    let sizeBytes: Int64
    let sourceLabel: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, url, name, sizeBytes, sourceLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        type = container.rexString(.type) ?? ""
        url = container.rexString(.url) ?? ""
        name = container.rexString(.name) ?? ""
        sizeBytes = container.rexInt64(.sizeBytes) ?? 0
        sourceLabel = container.rexString(.sourceLabel)
    }
}

struct MakerPreview: Decodable, Hashable, Sendable {
    let thumb: String
    let large: String

    private enum CodingKeys: String, CodingKey {
        case thumb, large
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thumb = container.rexString(.thumb) ?? ""
        large = container.rexString(.large) ?? ""
    }
}

struct MakerMovieDetail: Decodable, Sendable {
    let movie: MakerMovie
    let summary: String?
    let score: Double?
    let reviewsCount: Int
    let makers: [MakerNamed]
    let director: String?
    let series: String?
    let actors: [MakerActor]
    let tags: [String]
    let magnets: [MakerMagnet]
    let resources: [MakerResource]
    let previews: [MakerPreview]
    let relativeMovies: [MakerMovie]
    let hasLocalSubtitle: Bool
    let previewVideoUrl: String?
    let canPlay: Bool

    private enum CodingKeys: String, CodingKey {
        case id, number, title, coverUrl, thumbUrl, previewUrl
        case releaseDate, duration, magnetsCount, hasCnsub
        case summary, score, reviewsCount, makers, director, series, actors, tags
        case magnets, resources, previews, relativeMovies
        case hasLocalSubtitle, previewVideoUrl, canPlay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movie = try MakerMovie(from: decoder)
        summary = container.rexString(.summary)
        score = container.rexDouble(.score)
        reviewsCount = container.rexInt(.reviewsCount) ?? 0
        makers = container.rexArray(.makers, as: MakerNamed.self)
        director = container.rexString(.director)
        series = container.rexString(.series)
        actors = container.rexArray(.actors, as: MakerActor.self)
        tags = container.rexArray(.tags, as: String.self)
        magnets = container.rexArray(.magnets, as: MakerMagnet.self)
        resources = container.rexArray(.resources, as: MakerResource.self)
        previews = container.rexArray(.previews, as: MakerPreview.self)
        relativeMovies = container.rexArray(.relativeMovies, as: MakerMovie.self)
        hasLocalSubtitle = container.rexBool(.hasLocalSubtitle) ?? false
        previewVideoUrl = container.rexString(.previewVideoUrl)
        canPlay = container.rexBool(.canPlay) ?? false
    }
}

/// 在线播放源：后端已把 AVDB / 插件 / Stremio 的片源统一成同一结构。
struct MakerStream: Decodable, Identifiable, Hashable, Sendable {
    let addon: String
    let name: String
    let url: String
    let externalUrl: String
    let kind: String

    var id: String { url + name }

    var playable: Bool { kind == "direct" && !url.isEmpty }

    var displayTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "播放源" : trimmed
    }

    var provider: String {
        let trimmed = addon.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "片源" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case addon, name, url, externalUrl, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addon = container.rexString(.addon) ?? ""
        name = container.rexString(.name) ?? ""
        url = container.rexString(.url) ?? ""
        externalUrl = container.rexString(.externalUrl) ?? ""
        kind = container.rexString(.kind) ?? "direct"
    }
}

struct MakerPlaySources: Decodable, Sendable {
    let streams: [MakerStream]
    let total: Int
    let reason: String

    private enum CodingKeys: String, CodingKey {
        case streams, total, reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = container.rexArray(.streams, as: MakerStream.self)
        total = container.rexInt(.total) ?? streams.count
        reason = container.rexString(.reason) ?? ""
    }
}

// MARK: - 容错解码

/// AVDB 的数值字段既可能是数字也可能是字符串，统一在这里收敛，避免一处异常拖垮整页。
extension KeyedDecodingContainer {
    func rexString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func rexInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func rexInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    func rexDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    func rexBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        return nil
    }

    func rexArray<T: Decodable>(_ key: Key, as type: T.Type) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? []
    }
}
