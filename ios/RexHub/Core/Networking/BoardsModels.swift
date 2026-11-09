import Foundation

// MARK: - 色花堂板块（与 PWA 的 sehuatang-forum.json 对齐）

struct ShtForumType: Decodable, Hashable, Sendable {
    let key: String
    let fid: String
    let typeid: String
    let name: String
    let typeName: String
    let boardName: String
}

struct ShtForumBoard: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let fid: String
    let types: [ShtForumType]

    var id: String { fid }
}

struct ShtForumCategory: Decodable, Identifiable, Hashable, Sendable {
    let category: String
    let boards: [ShtForumBoard]

    var id: String { category }
}

/// 板块树直接内嵌，避免客户端为一个静态列表额外发请求。
enum ShtForumCatalog {
    static let categories: [ShtForumCategory] = [
        ShtForumCategory(category: "综合讨论区", boards: [
            ShtForumBoard(name: "综合讨论区", fid: "95", types: []),
            ShtForumBoard(name: "网友原创区", fid: "141", types: []),
            ShtForumBoard(name: "转帖交流区", fid: "142", types: [])
        ]),
        ShtForumCategory(category: "原创BT电影", boards: [
            ShtForumBoard(name: "国产原创", fid: "2", types: []),
            ShtForumBoard(name: "亚洲无码原创", fid: "36", types: []),
            ShtForumBoard(name: "亚洲有码原创", fid: "37", types: []),
            ShtForumBoard(name: "高清中文字幕", fid: "103", types: []),
            ShtForumBoard(name: "三级写真", fid: "107", types: []),
            ShtForumBoard(name: "VR视频区", fid: "160", types: []),
            ShtForumBoard(name: "素人有码系列", fid: "104", types: []),
            ShtForumBoard(name: "欧美无码", fid: "38", types: []),
            ShtForumBoard(name: "4K原版", fid: "151", types: []),
            ShtForumBoard(name: "韩国主播", fid: "152", types: []),
            ShtForumBoard(name: "动漫原创", fid: "39", types: [])
        ])
    ]
}

// MARK: - 板块资源

struct BrowseItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let resourceName: String
    let sizeBytes: Int64
    let sizeText: String
    let createdAt: String
    let magnet: String
    let ed2k: String
    let link: String
    let password: String
    let previewImage: String?
    let boardName: String

    private enum CodingKeys: String, CodingKey {
        case id, hash, title, name, resourceName, size, sizeText
        case createdAt, magnet, ed2k, link, ed2kLink, password
        case previewImages, boardName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? container.rexString(.hash) ?? UUID().uuidString
        title = container.rexString(.title) ?? container.rexString(.name) ?? "未命名资源"
        resourceName = container.rexString(.resourceName) ?? ""
        sizeBytes = container.rexInt64(.size) ?? 0
        sizeText = container.rexString(.sizeText) ?? ""
        createdAt = container.rexString(.createdAt) ?? ""
        magnet = container.rexString(.magnet) ?? ""
        ed2k = container.rexString(.ed2k) ?? container.rexString(.ed2kLink) ?? ""
        link = container.rexString(.link) ?? ""
        password = container.rexString(.password) ?? ""
        boardName = container.rexString(.boardName) ?? ""
        let previews = container.rexArray(.previewImages, as: String.self)
        previewImage = previews.first
    }

    /// 可复制 / 可转存的链接，按优先级取第一个。
    var primaryLink: String {
        if !magnet.isEmpty { return magnet }
        if !ed2k.isEmpty { return ed2k }
        return link
    }
}

struct BrowseResult: Decodable, Sendable {
    let resources: [BrowseItem]
    let hasMore: Bool
    let page: Int

    private enum CodingKeys: String, CodingKey {
        case resources, hasMore, has_more, page
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resources = container.rexArray(.resources, as: BrowseItem.self)
        hasMore = container.rexBool(.hasMore) ?? container.rexBool(.has_more) ?? false
        page = container.rexInt(.page) ?? 1
    }
}
