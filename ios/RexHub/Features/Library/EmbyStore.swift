import Foundation
import Observation

/// Emby 服务器列表：地址等信息进 UserDefaults，访问令牌进 Keychain。
@MainActor
@Observable
final class EmbyStore {
    static let shared = EmbyStore()

    private enum Key {
        static let servers = "rexhub.emby.servers"
    }

    private let defaults = UserDefaults.standard

    private(set) var servers: [EmbyServer] = []

    private init() {
        load()
    }

    // MARK: 增删改

    func save(_ server: EmbyServer, token: String) {
        Keychain.saveString(token, forKey: tokenKey(server.id))

        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.insert(server, at: 0)
        }
        persist()
    }

    func remove(_ server: EmbyServer) {
        servers.removeAll { $0.id == server.id }
        Keychain.deleteString(forKey: tokenKey(server.id))
        persist()
    }

    func token(for server: EmbyServer) -> String? {
        Keychain.string(forKey: tokenKey(server.id))
    }

    /// 直接可用的客户端；令牌缺失时仍可发起登录。
    func client(for server: EmbyServer) -> EmbyClient? {
        EmbyClient(host: server.host, token: token(for: server))
    }

    // MARK: 存储

    private func tokenKey(_ id: String) -> String {
        "emby.token.\(id)"
    }

    private func load() {
        guard let data = defaults.data(forKey: Key.servers) else { return }
        servers = (try? JSONDecoder().decode([EmbyServer].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: Key.servers)
    }
}
