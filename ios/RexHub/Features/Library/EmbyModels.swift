import Foundation

// MARK: - 服务器

/// 用户添加的 Emby 服务器。访问令牌单独存 Keychain，不随列表落盘。
struct EmbyServer: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    /// 规范化后的地址，如 `http://192.168.1.10:8096`。
    var host: String
    var username: String
    var userId: String
    var lastConnected: Date
}

// MARK: - 接口返回

/// 登录结果。
struct EmbyAuth: Sendable {
    let token: String
    let userId: String
    let userName: String
    let serverName: String
}

/// Emby 的一个媒体库（对应 `/Users/{id}/Views` 的一项）。
struct EmbyLibrary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let collectionType: String?
    let imageTag: String?
}

/// 媒体库里的一个条目。
struct EmbyItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let imageTag: String?
    let productionYear: Int?
}
