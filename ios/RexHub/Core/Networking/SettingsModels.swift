import Foundation

// MARK: - 服务配置 DTO

/// AVDB / CloudSaver / MoviePilot / MorePlay 的公共配置形状。
/// 服务端只回传 `hasApiKey` / `hasPassword`，真实凭据不会下发。
struct ServiceSettings: Decodable, Sendable {
    let enabled: Bool?
    let baseUrl: String?
    let timeoutSec: Double?
    let note: String?
    let hasApiKey: Bool?
    let hasPassword: Bool?
    let username: String?
    let searchSite: String?
    let searchSites: [String]?
    let tokenPageUrl: String?
}

/// 保存时把各家字段并成一个超集，服务端按自己的模型取用，多余字段会被忽略。
struct ServiceSaveBody: Encodable {
    var enabled: Bool
    var baseUrl: String
    var timeoutSec: Double
    var note: String?
    var apiKey: String?
    var username: String?
    var password: String?
    var searchSite: String?
    var searchSites: [String]?
}

/// 连接测试结果：不同服务的 data 结构略有差异，这里只取公共字段。
struct ServiceTestResult: Decodable, Sendable {
    let ok: Bool?
    let message: String?
    let latencyMs: Double?
    let totalResults: Int?
}

// MARK: - Postgres 服务（Bitmagnet / 色花资源库）

struct DbServiceSettings: Decodable, Sendable {
    let enabled: Bool?
    let dsn: String?
    let note: String?
    let configured: Bool?
}

struct DbServiceSaveBody: Encodable {
    var enabled: Bool
    var dsn: String
    var note: String
}

/// 色花堂子板地区覆盖：key = fid:typeid（整板 typeid 为空）。
struct ForumRegionSettings: Decodable, Sendable {
    let regionByKey: [String: String]?
}

struct ForumRegionSaveBody: Encodable {
    var regionByKey: [String: String]
}

// MARK: - 115

struct P115Settings: Decodable, Sendable {
    let folderCid: String?
    let folderName: String?
    let label: String?
    let hasCookie: Bool?
    let cookieHint: String?
    let configured: Bool?
    /// 按来源（search / media / maker）保存的转存目录。
    let targets: [String: P115TargetFolder]?
}

struct P115TargetFolder: Decodable, Sendable {
    let folderCid: String?
    let folderName: String?
}

struct P115Status: Decodable, Sendable {
    let authOk: Bool?
    let authError: String?
    let quota: Int?
    let quotaTotal: Int?
    let offlineLimit: Int?
    let spaceTotalText: String?
    let spaceUsedText: String?
    let spaceRemainText: String?
}

struct P115SaveBody: Encodable {
    var cookie: String
    var folderCid: String
    var folderName: String
    var label: String
    var validate: Bool
}

/// 只更新某个来源的转存目录。
struct P115TargetsSaveBody: Encodable {
    struct Folder: Encodable {
        var folderCid: String
        var folderName: String
    }

    var targets: [String: Folder]
    var validate: Bool = false
}

// MARK: - 115 扫码登录 / 目录

struct P115QRStart: Decodable, Sendable {
    let uid: String
    let time: String
    let sign: String
    let qrImage: String?
    let app: String?

    private enum CodingKeys: String, CodingKey {
        case uid, time, sign, qrImage, app
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = container.rexString(.uid) ?? ""
        time = container.rexString(.time) ?? ""
        sign = container.rexString(.sign) ?? ""
        qrImage = container.rexString(.qrImage)
        app = container.rexString(.app)
    }
}

struct P115QRStatus: Decodable, Sendable {
    let status: String
    let statusLabel: String
    let done: Bool
    let expired: Bool

    private enum CodingKeys: String, CodingKey {
        case status, statusLabel, done, expired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.rexString(.status) ?? ""
        statusLabel = container.rexString(.statusLabel) ?? ""
        done = container.rexBool(.done) ?? false
        expired = container.rexBool(.expired) ?? false
    }
}

struct P115Folder: Decodable, Identifiable, Hashable, Sendable {
    let cid: String
    let name: String

    var id: String { cid }
}

struct P115FolderPage: Decodable, Sendable {
    let ok: Bool
    let message: String
    let parentCid: String
    let path: [P115Folder]
    let folders: [P115Folder]

    private enum CodingKeys: String, CodingKey {
        case ok, message, parentCid, path, folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.rexBool(.ok) ?? false
        message = container.rexString(.message) ?? ""
        parentCid = container.rexString(.parentCid) ?? "0"
        path = container.rexArray(.path, as: P115Folder.self)
        folders = container.rexArray(.folders, as: P115Folder.self)
    }
}

struct P115QRStartBody: Encodable {
    let app: String
}

struct P115QRStatusBody: Encodable {
    let uid: String
    let time: String
    let sign: String
}

struct P115QRCompleteBody: Encodable {
    let uid: String
    let app: String
    let save: Bool
}

// MARK: - 网络

struct NetworkSettings: Decodable, Sendable {
    let proxyUrl: String?
    let proxyEnabled: Bool?
    let configured: Bool?
    let flareSolverrUrl: String?
    let flareSolverrEnabled: Bool?
    let flareSolverrConfigured: Bool?
    let githubApiUrl: String?
    let githubTokenSet: Bool?
    let githubMirror: String?
}

struct NetworkSaveBody: Encodable {
    var proxyUrl: String?
    var proxyEnabled: Bool?
    var flareSolverrUrl: String?
    var flareSolverrEnabled: Bool?
}

// MARK: - TMDB

struct TmdbSettings: Decodable, Sendable {
    let configured: Bool?
    let apiKeyHint: String?
}

struct TmdbSaveBody: Encodable {
    var apiKey: String
}
