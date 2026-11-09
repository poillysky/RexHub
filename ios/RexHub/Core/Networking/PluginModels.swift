import Foundation

// MARK: - 插件框架

struct PluginInfo: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let author: String
    let category: String
    let version: String
    let installedVersion: String
    let enabled: Bool
    let running: Bool
    let proxy: Bool
    let showInDrama: Bool
    let error: String
    let port: Int?
    let sourceRepo: String

    private enum CodingKeys: String, CodingKey {
        case id, name, description, author, category, version
        case installedVersion, enabled, running, proxy, showInDrama
        case error, port, sourceRepo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? id
        description = container.rexString(.description) ?? ""
        author = container.rexString(.author) ?? ""
        category = container.rexString(.category) ?? ""
        version = container.rexString(.version) ?? ""
        installedVersion = container.rexString(.installedVersion) ?? version
        enabled = container.rexBool(.enabled) ?? false
        running = container.rexBool(.running) ?? false
        proxy = container.rexBool(.proxy) ?? false
        showInDrama = container.rexBool(.showInDrama) ?? false
        error = container.rexString(.error) ?? ""
        port = container.rexInt(.port)
        sourceRepo = container.rexString(.sourceRepo) ?? ""
    }
}

struct PluginListResponse: Decodable, Sendable {
    let items: [PluginInfo]
}

struct PluginMarketEntry: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let author: String
    let category: String
    let version: String
    let repository: String
    let installed: Bool
    let installedVersion: String
    let updateAvailable: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, description, author, category, version
        case repository, installed, installedVersion, updateAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        name = container.rexString(.name) ?? id
        description = container.rexString(.description) ?? ""
        author = container.rexString(.author) ?? ""
        category = container.rexString(.category) ?? ""
        version = container.rexString(.version) ?? ""
        repository = container.rexString(.repository) ?? ""
        installed = container.rexBool(.installed) ?? false
        installedVersion = container.rexString(.installedVersion) ?? ""
        updateAvailable = container.rexBool(.updateAvailable) ?? false
    }
}

struct PluginMarket: Decodable, Sendable {
    let plugins: [PluginMarketEntry]
    let errors: [String]

    private enum CodingKeys: String, CodingKey {
        case plugins, errors
    }

    private struct MarketError: Decodable {
        let error: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugins = container.rexArray(.plugins, as: PluginMarketEntry.self)
        let rows = (try? container.decodeIfPresent([MarketError].self, forKey: .errors)) ?? []
        errors = rows.compactMap { $0.error }.filter { !$0.isEmpty }
    }
}

struct PluginUpdateInfo: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let installedVersion: String
    let latestVersion: String
}

struct PluginUpdateResponse: Decodable, Sendable {
    let items: [PluginUpdateInfo]
}

struct PluginLogs: Decodable, Sendable {
    let id: String
    let lines: [String]

    private enum CodingKeys: String, CodingKey {
        case id, lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        lines = container.rexArray(.lines, as: String.self)
    }
}

// MARK: - Stremio

struct StremioSnapshot: Decodable, Sendable {
    let repositories: [StremioRepository]
    let addons: [StremioAddon]

    private enum CodingKeys: String, CodingKey {
        case repositories, addons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositories = container.rexArray(.repositories, as: StremioRepository.self)
        addons = container.rexArray(.addons, as: StremioAddon.self)
    }
}

struct StremioRepository: Decodable, Identifiable, Sendable {
    let url: String
    let title: String
    let count: Int

    var id: String { url }

    private enum CodingKeys: String, CodingKey {
        case url, title, count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.rexString(.url) ?? ""
        title = container.rexString(.title) ?? ""
        count = container.rexInt(.count) ?? 0
    }
}

struct StremioAddon: Decodable, Identifiable, Sendable {
    let slug: String
    let addonID: String
    let name: String
    let version: String
    let enabled: Bool
    let error: String
    let transport: String

    var id: String { slug }

    private enum CodingKeys: String, CodingKey {
        case slug, addonID = "id", enabled, error, transport
        case manifest
    }

    private enum ManifestKeys: String, CodingKey {
        case name, version, description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = container.rexString(.slug) ?? ""
        addonID = container.rexString(.addonID) ?? slug
        enabled = container.rexBool(.enabled) ?? false
        error = container.rexString(.error) ?? ""
        transport = container.rexString(.transport) ?? ""

        let manifest = try? container.nestedContainer(keyedBy: ManifestKeys.self, forKey: .manifest)
        name = manifest.flatMap { try? $0.decodeIfPresent(String.self, forKey: .name) } ?? addonID
        version = manifest.flatMap { try? $0.decodeIfPresent(String.self, forKey: .version) } ?? ""
    }
}

// MARK: - 请求体

struct PluginInstallBody: Encodable {
    let repository: String
    let id: String
}

struct StremioRepositoryBody: Encodable {
    let url: String
    let title: String?
}

struct StremioAddonBody: Encodable {
    let url: String
}

struct StremioEnabledBody: Encodable {
    let enabled: Bool
}
