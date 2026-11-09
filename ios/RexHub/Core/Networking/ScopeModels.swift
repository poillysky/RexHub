import Foundation

/// 范围搜索：影视（Bitmagnet + CloudSaver）/ 片商（AVDB + Bitmagnet + 色花堂）。
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case movie
    case maker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie: "影视"
        case .maker: "片商"
        }
    }

    var summary: String {
        switch self {
        case .movie: "Bitmagnet + CloudSaver"
        case .maker: "AVDB + Bitmagnet + 色花堂"
        }
    }

    var symbol: String {
        switch self {
        case .movie: "film.stack"
        case .maker: "person.2.crop.square.stack"
        }
    }

    /// 各范围固定的来源，用于筛选条。
    var sources: [(id: String, label: String)] {
        switch self {
        case .movie:
            [("bitmagnet", "Bitmagnet"), ("cloudsaver", "CloudSaver")]
        case .maker:
            [("avdb", "AVDB"), ("bitmagnet", "Bitmagnet"), ("sehuatang", "色花堂")]
        }
    }
}

struct ScopeLink: Decodable, Hashable, Sendable {
    let label: String
    let url: String
    let password: String

    private enum CodingKeys: String, CodingKey {
        case label, url, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? container.decode(String.self, forKey: .label)) ?? "链接"
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        password = (try? container.decode(String.self, forKey: .password)) ?? ""
    }
}

struct ScopeItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let hash: String?
    let source: String
    let sourceLabel: String
    let category: String
    let title: String
    let sizeBytes: Int64
    let sizeLabel: String
    let publishedAt: String?
    let magnet: String?
    let ed2k: String?
    let links: [ScopeLink]
    let thumbUrl: String?

    private enum CodingKeys: String, CodingKey {
        case id, hash, source, sourceLabel, category, title
        case sizeBytes, sizeLabel, publishedAt, magnet, ed2k, links, thumbUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        hash = container.rexString(.hash)
        source = container.rexString(.source) ?? ""
        sourceLabel = container.rexString(.sourceLabel) ?? source
        category = container.rexString(.category) ?? ""
        title = container.rexString(.title) ?? "未命名资源"
        sizeBytes = container.rexInt64(.sizeBytes) ?? 0
        sizeLabel = container.rexString(.sizeLabel) ?? ""
        publishedAt = container.rexString(.publishedAt)
        magnet = container.rexString(.magnet)
        ed2k = container.rexString(.ed2k)
        links = container.rexArray(.links, as: ScopeLink.self)
        thumbUrl = container.rexString(.thumbUrl)
    }

    /// 可转存/复制的候选链接：磁力、电驴、115 分享链接、普通直链。
    var actionableLinks: [(label: String, url: String, password: String)] {
        var out: [(String, String, String)] = []
        if let magnet, !magnet.isEmpty {
            out.append(("磁力", magnet, ""))
        }
        if let ed2k, !ed2k.isEmpty {
            out.append(("电驴", ed2k, ""))
        }
        for link in links where !link.url.isEmpty {
            out.append((link.label.isEmpty ? "链接" : link.label, link.url, link.password))
        }
        return out
    }
}

struct ScopeResponse: Decodable, Sendable {
    let scope: String
    let keyword: String
    let page: Int
    let sourceErrors: [String: String]
    let items: [ScopeItem]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case scope, keyword, page, sourceErrors, items, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = container.rexString(.scope) ?? "movie"
        keyword = container.rexString(.keyword) ?? ""
        page = container.rexInt(.page) ?? 1
        sourceErrors = (try? container.decodeIfPresent([String: String].self, forKey: .sourceErrors)) ?? [:]
        items = container.rexArray(.items, as: ScopeItem.self)
        hasMore = container.rexBool(.hasMore) ?? false
    }
}

/// 结果页的筛选条件。
struct ScopeSearchOptions: Hashable {
    var sort = "relevance"
    var filterTime = "all"
    var filterSize = "all"
    var source = "all"

    static let sortOptions: [(id: String, label: String)] = [
        ("relevance", "相关度"),
        ("date", "最新"),
        ("size", "大小")
    ]

    static let timeOptions: [(id: String, label: String)] = [
        ("all", "不限时间"),
        ("gt-1day", "一天内"),
        ("gt-7day", "一周内"),
        ("gt-31day", "一月内"),
        ("gt-365day", "一年内")
    ]

    static let sizeOptions: [(id: String, label: String)] = [
        ("all", "不限大小"),
        ("lt100mb", "100MB 以下"),
        ("gt100mb-lt500mb", "100–500MB"),
        ("gt500mb-lt1gb", "500MB–1GB"),
        ("gt1gb-lt5gb", "1–5GB"),
        ("gt5gb", "5GB 以上")
    ]
}
