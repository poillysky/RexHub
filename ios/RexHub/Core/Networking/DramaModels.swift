import Foundation

// MARK: - 短剧

struct DramaSite: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let enabled: Bool
    let capabilities: [String]
    let ui: DramaSiteUI?

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, capabilities, ui
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        name = container.rexString(.name) ?? ""
        enabled = container.rexBool(.enabled) ?? true
        capabilities = (try? container.decode([String].self, forKey: .capabilities)) ?? []
        ui = try? container.decode(DramaSiteUI.self, forKey: .ui)
    }
}

/// 插件声明的站点视觉信息，与 PWA `ui.shortdrama` 对齐。
struct DramaSiteUI: Decodable, Hashable, Sendable {
    let shortdrama: DramaShortdramaUI?

    private enum CodingKeys: String, CodingKey {
        case shortdrama
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortdrama = try? container.decode(DramaShortdramaUI.self, forKey: .shortdrama)
    }
}

struct DramaShortdramaUI: Decodable, Hashable, Sendable {
    let title: String?
    let subtitle: String?
    let accent: String?
    let icon: String?
    let logo: String?
    let badge: String?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, accent, icon, logo, badge
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.rexString(.title)
        subtitle = container.rexString(.subtitle)
        accent = container.rexString(.accent)
        icon = container.rexString(.icon)
        logo = container.rexString(.logo)
        badge = container.rexString(.badge)
    }
}

struct DramaSiteList: Decodable, Sendable {
    let items: [DramaSite]
}

struct DramaCard: Decodable, Identifiable, Hashable, Sendable {
    let site: String
    let siteName: String
    let id: String
    let title: String
    let cover: String
    let description: String
    let season: Int
    let episodeCount: Int

    private enum CodingKeys: String, CodingKey {
        case site, siteName, id, title, cover, description, season, episodeCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = container.rexString(.site) ?? ""
        siteName = container.rexString(.siteName) ?? ""
        id = container.rexString(.id) ?? UUID().uuidString
        title = container.rexString(.title) ?? "未命名短剧"
        cover = container.rexString(.cover) ?? ""
        description = container.rexString(.description) ?? ""
        season = container.rexInt(.season) ?? 1
        episodeCount = container.rexInt(.episodeCount) ?? 0
    }
}

struct DramaPage: Decodable, Sendable {
    let site: String
    let siteName: String
    let items: [DramaCard]
    let hasMore: Bool
    let nextPage: Int?

    private enum CodingKeys: String, CodingKey {
        case site, siteName, items, hasMore, nextPage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = container.rexString(.site) ?? ""
        siteName = container.rexString(.siteName) ?? ""
        items = container.rexArray(.items, as: DramaCard.self)
        hasMore = container.rexBool(.hasMore) ?? false
        nextPage = container.rexInt(.nextPage)
    }
}

struct DramaEpisode: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let episode: Int
    let duration: Int
    let disabled: Bool
}

struct DramaSeries: Decodable, Sendable {
    let site: String
    let siteName: String
    let id: String
    let title: String
    let cover: String
    let description: String
    let season: Int
    let episodeCount: Int
    let complete: Bool
    let episodes: [DramaEpisode]
    let seasons: [DramaCard]

    private enum CodingKeys: String, CodingKey {
        case site, siteName, id, title, cover, description, season
        case episodeCount, complete, episodes, seasons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = container.rexString(.site) ?? ""
        siteName = container.rexString(.siteName) ?? ""
        id = container.rexString(.id) ?? ""
        title = container.rexString(.title) ?? "未命名短剧"
        cover = container.rexString(.cover) ?? ""
        description = container.rexString(.description) ?? ""
        season = container.rexInt(.season) ?? 1
        episodeCount = container.rexInt(.episodeCount) ?? 0
        complete = container.rexBool(.complete) ?? true
        episodes = container.rexArray(.episodes, as: DramaEpisode.self)
        seasons = container.rexArray(.seasons, as: DramaCard.self)
    }
}

// MARK: - 榜单

struct DramaRankFilterOption: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct DramaRankFilterGroup: Decodable, Hashable, Sendable {
    let title: String
    let items: [DramaRankFilterOption]
}

struct DramaRank: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let filters: [DramaRankFilterGroup]
}

struct DramaRankGroup: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let ranks: [DramaRank]
}

struct DramaRankListResponse: Decodable, Sendable {
    let groups: [DramaRankGroup]
}
