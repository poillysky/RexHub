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

/// 推荐演员：`GET /makers/actor-recommend`，新人 / 月榜 / FANZA 推荐三组。
struct MakerActorRecommend: Decodable, Sendable {
    let newActors: [MakerActor]
    let monthlyActors: [MakerActor]
    let recommendActors: [MakerActor]

    private enum CodingKeys: String, CodingKey {
        case newActors, monthlyActors, recommendActors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newActors = container.rexArray(.newActors, as: MakerActor.self)
        monthlyActors = container.rexArray(.monthlyActors, as: MakerActor.self)
        recommendActors = container.rexArray(.recommendActors, as: MakerActor.self)
    }
}

/// AVDB 站内搜索类型：片商 / 演员 / 片单 / 系列 / 导演 / 番号前缀。
enum MakerSearchType: String, CaseIterable, Sendable {
    case maker
    case actor
    case list
    case series
    case director
    case code
}

/// 站内搜索结果项，`kind` 决定点击后跳哪里。
struct MakerSearchItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    let count: Int
    let avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, count, avatarUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
        kind = container.rexString(.kind) ?? MakerSearchType.maker.rawValue
        count = container.rexInt(.count) ?? 0
        avatarUrl = container.rexString(.avatarUrl)
    }
}

struct MakerSearchResult: Decodable, Sendable {
    let items: [MakerSearchItem]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.rexArray(.items, as: MakerSearchItem.self)
    }
}

/// AVDB 自有种子库资源（`GET /makers/torrents`）。
struct MakerTorrent: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let number: String
    let site: String?
    let website: String?
    let title: String
    let sizeMb: Double
    let sizeBytes: Int64
    let postTime: String?
    let seeders: Int
    let downloadUrl: String
    let previewImage: String?
    let free: Bool
    let chinese: Bool
    let uncensored: Bool
    let hd: Bool
    let uhd: Bool
    let tags: [String]

    /// 站点名，依次退回网站 / 标题。
    var sourceLabel: String {
        [website, site, title]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "资源"
    }

    var isMagnet: Bool {
        downloadUrl.hasPrefix("magnet:")
    }

    /// 体积文案：优先字节数，其次 MB 字段。
    var sizeLabel: String {
        if sizeBytes > 0 {
            let gb = Double(sizeBytes) / 1_073_741_824
            if gb >= 1 { return String(format: "%.1f GB", gb) }
            return String(format: "%.0f MB", Double(sizeBytes) / 1_048_576)
        }
        guard sizeMb > 0 else { return "" }
        if sizeMb >= 1024 { return String(format: "%.1f GB", sizeMb / 1024) }
        return String(format: "%.0f MB", sizeMb)
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, site, website, title
        case sizeMb, sizeBytes, postTime, seeders, downloadUrl, previewImage
        case free, chinese, uncensored, hd, uhd, tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        number = container.rexString(.number) ?? ""
        site = container.rexString(.site)
        website = container.rexString(.website)
        title = container.rexString(.title) ?? ""
        sizeMb = container.rexDouble(.sizeMb) ?? 0
        sizeBytes = container.rexInt64(.sizeBytes) ?? 0
        postTime = container.rexString(.postTime)
        seeders = container.rexInt(.seeders) ?? 0
        downloadUrl = container.rexString(.downloadUrl) ?? ""
        previewImage = container.rexString(.previewImage)
        free = container.rexBool(.free) ?? false
        chinese = container.rexBool(.chinese) ?? false
        uncensored = container.rexBool(.uncensored) ?? false
        hd = container.rexBool(.hd) ?? false
        uhd = container.rexBool(.uhd) ?? false
        tags = container.rexArray(.tags, as: String.self)
    }
}

struct MakerTorrentPage: Decodable, Sendable {
    let keyword: String
    let exact: Bool
    let page: Int
    let total: Int
    let items: [MakerTorrent]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case keyword, exact, page, total, items, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyword = container.rexString(.keyword) ?? ""
        exact = container.rexBool(.exact) ?? false
        page = container.rexInt(.page) ?? 1
        total = container.rexInt(.total) ?? 0
        items = container.rexArray(.items, as: MakerTorrent.self)
        hasMore = container.rexBool(.hasMore) ?? false
    }
}

/// 演员详情：`GET /makers/actor-detail`。
struct MakerActorDetail: Decodable, Sendable {
    let id: String
    let name: String
    let nameZht: String?
    let otherName: String?
    let avatarUrl: String?
    let birthday: String?
    let age: Int
    let constellation: String?
    let bloodType: String?
    let height: Int
    let bust: Int
    let cup: String?
    let waist: Int
    let hips: Int
    let birthplace: String?
    let videosCount: Int
    let shareUrl: String?
    let filterTags: [MakerTag]

    private enum CodingKeys: String, CodingKey {
        case id, name, nameZht, otherName, avatarUrl
        case birthday, age, constellation, bloodType
        case height, bust, cup, waist, hips, birthplace
        case videosCount, shareUrl, filterTags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
        nameZht = container.rexString(.nameZht)
        otherName = container.rexString(.otherName)
        avatarUrl = container.rexString(.avatarUrl)
        birthday = container.rexString(.birthday)
        age = container.rexInt(.age) ?? 0
        constellation = container.rexString(.constellation)
        bloodType = container.rexString(.bloodType)
        height = container.rexInt(.height) ?? 0
        bust = container.rexInt(.bust) ?? 0
        cup = container.rexString(.cup)
        waist = container.rexInt(.waist) ?? 0
        hips = container.rexInt(.hips) ?? 0
        birthplace = container.rexString(.birthplace)
        videosCount = container.rexInt(.videosCount) ?? 0
        shareUrl = container.rexString(.shareUrl)
        filterTags = container.rexArray(.filterTags, as: MakerTag.self)
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
    let hash: String?
    let hd: Bool
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, url, name, sizeBytes, sourceLabel, hash, hd, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        type = container.rexString(.type) ?? ""
        url = container.rexString(.url) ?? ""
        name = container.rexString(.name) ?? ""
        sizeBytes = container.rexInt64(.sizeBytes) ?? 0
        sourceLabel = container.rexString(.sourceLabel)
        hash = container.rexString(.hash)
        hd = container.rexBool(.hd) ?? false
        createdAt = container.rexString(.createdAt)
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
    let watchedCount: Int
    let makers: [MakerNamed]
    let publisher: String?
    let publisherId: String?
    let director: String?
    let directorId: String?
    let series: String?
    let seriesId: String?
    let actors: [MakerActor]
    let tags: [String]
    let magnets: [MakerMagnet]
    let resources: [MakerResource]
    let previews: [MakerPreview]
    let relativeMovies: [MakerMovie]
    let actorMovies: [MakerMovie]
    let topRankings: [MakerRankEntry]
    let avdbTorrents: [MakerTorrent]
    let shareUrl: String?
    let hasLocalSubtitle: Bool
    let previewVideoUrl: String?
    let canPlay: Bool

    private enum CodingKeys: String, CodingKey {
        case id, number, title, coverUrl, thumbUrl, previewUrl
        case releaseDate, duration, magnetsCount, hasCnsub
        case summary, score, reviewsCount, watchedCount, makers
        case publisher, publisherId, director, directorId, series, seriesId
        case actors, tags
        case magnets, resources, previews, relativeMovies, actorMovies
        case topRankings, avdbTorrents, shareUrl
        case hasLocalSubtitle, previewVideoUrl, canPlay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movie = try MakerMovie(from: decoder)
        summary = container.rexString(.summary)
        score = container.rexDouble(.score)
        reviewsCount = container.rexInt(.reviewsCount) ?? 0
        watchedCount = container.rexInt(.watchedCount) ?? 0
        makers = container.rexArray(.makers, as: MakerNamed.self)
        publisher = container.rexString(.publisher)
        publisherId = container.rexString(.publisherId)
        director = container.rexString(.director)
        directorId = container.rexString(.directorId)
        series = container.rexString(.series)
        seriesId = container.rexString(.seriesId)
        actors = container.rexArray(.actors, as: MakerActor.self)
        tags = container.rexArray(.tags, as: String.self)
        magnets = container.rexArray(.magnets, as: MakerMagnet.self)
        resources = container.rexArray(.resources, as: MakerResource.self)
        previews = container.rexArray(.previews, as: MakerPreview.self)
        relativeMovies = container.rexArray(.relativeMovies, as: MakerMovie.self)
        actorMovies = container.rexArray(.actorMovies, as: MakerMovie.self)
        topRankings = container.rexArray(.topRankings, as: MakerRankEntry.self)
        avdbTorrents = container.rexArray(.avdbTorrents, as: MakerTorrent.self)
        shareUrl = container.rexString(.shareUrl)
        hasLocalSubtitle = container.rexBool(.hasLocalSubtitle) ?? false
        previewVideoUrl = container.rexString(.previewVideoUrl)
        canPlay = container.rexBool(.canPlay) ?? false
    }
}

/// 影片在某榜单中的排名（PWA `topRankings`）。
struct MakerRankEntry: Decodable, Hashable, Sendable {
    let type: String
    let period: String
    let rank: Int
    let category: String?

    private enum CodingKeys: String, CodingKey {
        case type, period, rank, category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.rexString(.type) ?? ""
        period = container.rexString(.period) ?? ""
        rank = container.rexInt(.rank) ?? 0
        category = container.rexString(.category)
    }

    var label: String {
        [type, period].filter { !$0.isEmpty }.joined(separator: " ") + " 第 \(rank) 名"
    }
}

/// 影片评论（`GET /makers/reviews`）。
struct MakerReview: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let username: String
    let content: String
    let score: Double?
    let likesCount: Int
    let createdAt: String?
    let statusTitle: String?

    private enum CodingKeys: String, CodingKey {
        case id, username, content, score, likesCount, createdAt, statusTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        username = container.rexString(.username) ?? "匿名用户"
        content = container.rexString(.content) ?? ""
        score = container.rexDouble(.score)
        likesCount = container.rexInt(.likesCount) ?? 0
        createdAt = container.rexString(.createdAt)
        statusTitle = container.rexString(.statusTitle)
    }
}

struct MakerReviewPage: Decodable, Sendable {
    let movieId: String
    let page: Int
    let items: [MakerReview]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case movieId, page, items, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movieId = container.rexString(.movieId) ?? ""
        page = container.rexInt(.page) ?? 1
        items = container.rexArray(.items, as: MakerReview.self)
        hasMore = container.rexBool(.hasMore) ?? false
    }
}

/// 相关片单（`GET /makers/lists/related`）。
struct MakerRelatedList: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let moviesCount: Int
    let collectionsCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, moviesCount, collectionsCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? ""
        moviesCount = container.rexInt(.moviesCount) ?? 0
        collectionsCount = container.rexInt(.collectionsCount) ?? 0
    }
}

struct MakerRelatedListPage: Decodable, Sendable {
    let items: [MakerRelatedList]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.rexArray(.items, as: MakerRelatedList.self)
    }
}

/// 片商 / 导演 / 系列实体类型，rawValue 即 `GET /makers/entity` 的 kind。
enum MakerEntityKind: String, Hashable, CaseIterable, Sendable {
    case maker
    case director
    case series

    var title: String {
        switch self {
        case .maker: "片商"
        case .director: "导演"
        case .series: "系列"
        }
    }
}

/// TOP250 年份下拉选项（`GET /makers/years`）。
struct MakerYearOptions: Decodable, Sendable {
    let years: [String]
}

/// 片商 / 导演 / 系列实体详情（`GET /makers/entity`）。
struct MakerEntity: Decodable, Hashable, Sendable {
    let kind: String
    let id: String
    let type: Int?
    let name: String
    let videosCount: Int
    let shareUrl: String?

    private enum CodingKeys: String, CodingKey {
        case kind, id, type, name, videosCount, shareUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.rexString(.kind) ?? ""
        id = container.rexString(.id) ?? ""
        type = container.rexInt(.type)
        name = container.rexString(.name) ?? ""
        videosCount = container.rexInt(.videosCount) ?? 0
        shareUrl = container.rexString(.shareUrl)
    }
}

/// 在线播放源：后端已把 AVDB / 插件的片源统一成同一结构。
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
