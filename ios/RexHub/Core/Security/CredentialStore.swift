import Foundation

/// 「记住密码」：账号与地址存 UserDefaults，密码独立存放在 Keychain。
/// 支持多条历史记录（同一台设备可能连多个服务端 / 多个账号）。
enum CredentialStore {
    private static let accountKey = "rexhub.auth.rememberedAccount"
    private static let historyKey = "rexhub.auth.history"
    private static let maxHistory = 10

    /// 一条可一键回填的登录记录。
    struct Record: Codable, Identifiable, Equatable {
        var server: String
        var useHTTPS: Bool
        var account: String
        var lastUsedAt: Date

        var id: String { "\(server.lowercased())|\(useHTTPS)|\(account.lowercased())" }

        var serverLabel: String {
            server.isEmpty ? "未填写地址" : server
        }
    }

    static var account: String? {
        get { Keychain.string(forKey: "rememberedAccount") ?? UserDefaults.standard.string(forKey: accountKey) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.saveString(newValue, forKey: "rememberedAccount")
                UserDefaults.standard.set(newValue, forKey: accountKey)
            } else {
                Keychain.deleteString(forKey: "rememberedAccount")
                UserDefaults.standard.removeObject(forKey: accountKey)
            }
        }
    }

    static var password: String? {
        Keychain.savedPassword
    }

    /// 历史记录按最近使用排序。
    static var history: [Record] {
        guard let data = historyData,
              let list = try? JSONDecoder().decode([Record].self, from: data) else {
            return legacyHistory
        }
        return list.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    static func password(for record: Record) -> String? {
        Keychain.password(forKey: record.id) ?? Keychain.savedPassword
    }

    static func remember(
        server: String,
        useHTTPS: Bool,
        account: String,
        password: String
    ) {
        self.account = account
        Keychain.savePassword(password)
        Keychain.savePassword(password, forKey: key(server: server, useHTTPS: useHTTPS, account: account))

        var list = history.filter {
            $0.id != Record(server: server, useHTTPS: useHTTPS, account: account, lastUsedAt: .now).id
        }
        list.insert(
            Record(server: server, useHTTPS: useHTTPS, account: account, lastUsedAt: .now),
            at: 0
        )
        if list.count > maxHistory {
            let removed = list[maxHistory...]
            removed.forEach { Keychain.deletePassword(forKey: $0.id) }
            list = Array(list.prefix(maxHistory))
        }
        save(list)
    }

    static func remove(_ record: Record) {
        Keychain.deletePassword(forKey: record.id)
        save(history.filter { $0.id != record.id })
    }

    /// 清空所有「记住密码」痕迹：默认密码与每条历史记录的专属密码。
    /// 历史里的服务端 / 账号仍保留，方便下次登录回填用户名。
    static func forget() {
        history.forEach { Keychain.deletePassword(forKey: $0.id) }
        account = nil
        Keychain.deletePassword()
    }

    // MARK: - 内部

    private static func key(server: String, useHTTPS: Bool, account: String) -> String {
        Record(server: server, useHTTPS: useHTTPS, account: account, lastUsedAt: .now).id
    }

    private static func save(_ list: [Record]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
        Keychain.saveString(data.base64EncodedString(), forKey: "history")
    }

    /// 优先读 Keychain：卸载重装后历史记录仍在；旧版本数据回退到 UserDefaults。
    private static var historyData: Data? {
        if let encoded = Keychain.string(forKey: "history"),
           let data = Data(base64Encoded: encoded) {
            return data
        }
        return UserDefaults.standard.data(forKey: historyKey)
    }

    /// 兼容旧版本：只有一组账号密码，地址取当前保存的服务端。
    private static var legacyHistory: [Record] {
        guard let account, !account.isEmpty, password?.isEmpty == false else { return [] }
        let server = ServerConfig.savedText
        guard !server.isEmpty else { return [] }
        return [Record(server: server, useHTTPS: ServerConfig.httpsEnabled, account: account, lastUsedAt: .distantPast)]
    }
}
