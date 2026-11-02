import Foundation

/// 会话的本地存储边界：token 进 Keychain，用户快照与到期时间进 UserDefaults。
protocol SessionStoring: Sendable {
    var token: String? { get }
    var user: AuthUser? { get }
    var expiresAt: Date? { get }
    func save(_ session: AuthSession)
    func clear()
}

struct SessionStore: SessionStoring {
    private static let userKey = "rexhub.auth.user"
    private static let expiryKey = "rexhub.auth.expiresAt"

    var token: String? {
        Keychain.token
    }

    var user: AuthUser? {
        guard let data = UserDefaults.standard.data(forKey: Self.userKey) else { return nil }
        return try? JSONDecoder().decode(AuthUser.self, from: data)
    }

    var expiresAt: Date? {
        UserDefaults.standard.object(forKey: Self.expiryKey) as? Date
    }

    func save(_ session: AuthSession) {
        Keychain.saveToken(session.token)
        if let data = try? JSONEncoder().encode(session.user) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
        }
        if session.expiresAt == .distantFuture {
            UserDefaults.standard.removeObject(forKey: Self.expiryKey)
        } else {
            UserDefaults.standard.set(session.expiresAt, forKey: Self.expiryKey)
        }
    }

    func clear() {
        Keychain.deleteToken()
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        UserDefaults.standard.removeObject(forKey: Self.expiryKey)
    }
}
