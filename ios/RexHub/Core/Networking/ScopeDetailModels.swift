import Foundation

/// 种子内的单个文件。`/api/magnet/detail` 与 `/api/resources/{hash}` 的 `files[]` 同构。
struct TorrentFile: Decodable, Hashable, Sendable {
    let index: Int
    let path: String
    let size: Int64
    let fileExtension: String

    private enum CodingKeys: String, CodingKey {
        case index, path, size
        case fileExtension = "extension"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = container.rexInt(.index) ?? 0
        path = container.rexString(.path) ?? ""
        size = container.rexInt64(.size) ?? 0
        fileExtension = container.rexString(.fileExtension) ?? ""
    }
}

/// `/api/magnet/detail`：Bitmagnet 本地库详情。
/// 服务端同时返回 `created_at`（数字）与 `createdAt`（空串），
/// 用 `.convertFromSnakeCase` 会撞名，这里统一用显式 snake CodingKeys + 原始解码器。
struct MagnetDetail: Decodable, Hashable, Sendable {
    let hash: String
    let name: String
    let title: String
    let size: Int64
    let filesCount: Int
    let files: [TorrentFile]
    let filesStatus: String
    let singleFile: Bool
    let createdAt: Int64
    let magnet: String
    let magnetUri: String
    let magnets: [String]

    private enum CodingKeys: String, CodingKey {
        case hash, name, title, size, files, magnet, magnets
        case filesCount = "files_count"
        case filesStatus = "files_status"
        case singleFile = "single_file"
        case createdAt = "created_at"
        case magnetUri = "magnet_uri"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = (container.rexString(.hash) ?? "").lowercased()
        name = container.rexString(.name) ?? ""
        title = container.rexString(.title) ?? ""
        size = container.rexInt64(.size) ?? 0
        filesCount = container.rexInt(.filesCount) ?? 0
        files = container.rexArray(.files, as: TorrentFile.self)
        filesStatus = container.rexString(.filesStatus) ?? ""
        singleFile = container.rexBool(.singleFile) ?? false
        createdAt = container.rexInt64(.createdAt) ?? 0
        magnet = container.rexString(.magnet) ?? ""
        magnetUri = container.rexString(.magnetUri) ?? ""
        magnets = container.rexArray(.magnets, as: String.self)
    }

    /// 标题：name → title → hash（对齐 PWA）。
    var displayName: String {
        if !name.isEmpty { return name }
        if !title.isEmpty { return title }
        return hash
    }

    /// 文件数：files_count → files 数量。
    var effectiveFilesCount: Int {
        filesCount > 0 ? filesCount : files.count
    }

    /// 完整磁力：magnet_uri → magnet → magnets[0]。
    var primaryMagnet: String {
        for value in [magnetUri, magnet] where !value.isEmpty {
            return value
        }
        return magnets.first { !$0.isEmpty } ?? ""
    }

    /// 卡片正文展示的短磁力。
    var shortMagnet: String {
        "magnet:?xt=urn:btih:\(hash)"
    }
}

struct MagnetPreviewShot: Decodable, Hashable, Sendable {
    let screenshot: String

    private enum CodingKeys: String, CodingKey {
        case screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screenshot = (container.rexString(.screenshot) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `/api/magnet/preview`：WhatsLink 截图预览；无图时 `screenshots` 为空。
struct MagnetPreview: Decodable, Hashable, Sendable {
    let hash: String
    let name: String
    let fileType: String
    let screenshots: [MagnetPreviewShot]

    private enum CodingKeys: String, CodingKey {
        case hash, name, screenshots
        case fileType = "file_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = container.rexString(.hash) ?? ""
        name = container.rexString(.name) ?? ""
        fileType = container.rexString(.fileType) ?? "unknown"
        screenshots = container.rexArray(.screenshots, as: MagnetPreviewShot.self)
    }
}

/// `/api/resources/{hash}`：色花堂资源详情（字段由 `resource_format.format_resource` 产出）。
struct ResourceDetail: Decodable, Hashable, Sendable {
    let hash: String
    let name: String
    let title: String
    let description: String
    let sourceUrl: String
    let boardName: String
    let extractPassword: String
    let previewImages: [String]
    let ed2kLinks: [String]
    let size: Int64
    let ed2kLink: String
    let linkKind: String
    let filesCount: Int
    let files: [TorrentFile]
    let createdAt: Int64

    private enum CodingKeys: String, CodingKey {
        case hash, name, title, description, size, files
        case sourceUrl = "source_url"
        case boardName = "board_name"
        case extractPassword = "extract_password"
        case previewImages = "preview_images"
        case ed2kLinks = "ed2k_links"
        case ed2kLink = "ed2k_link"
        case linkKind = "link_kind"
        case filesCount = "files_count"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = container.rexString(.hash) ?? ""
        name = container.rexString(.name) ?? ""
        title = container.rexString(.title) ?? ""
        description = container.rexString(.description) ?? ""
        sourceUrl = container.rexString(.sourceUrl) ?? ""
        boardName = container.rexString(.boardName) ?? ""
        extractPassword = container.rexString(.extractPassword) ?? ""
        previewImages = container.rexArray(.previewImages, as: String.self)
        ed2kLinks = container.rexArray(.ed2kLinks, as: String.self)
        size = container.rexInt64(.size) ?? 0
        ed2kLink = container.rexString(.ed2kLink) ?? ""
        linkKind = container.rexString(.linkKind) ?? ""
        filesCount = container.rexInt(.filesCount) ?? 0
        files = container.rexArray(.files, as: TorrentFile.self)
        createdAt = container.rexInt64(.createdAt) ?? 0
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !name.isEmpty { return name }
        return hash
    }

    /// 下载链：`ed2k_links` 非空用全部，否则回退主链（后端已按 hash 过滤）。
    var links: [String] {
        if !ed2kLinks.isEmpty { return ed2kLinks }
        return ed2kLink.isEmpty ? [] : [ed2kLink]
    }
}
