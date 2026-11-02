import Foundation
import Security

/// 凭证只进 Keychain：会话 token 与「记住密码」各用独立 key。
enum Keychain {
    private static let service = "com.poilly.RexHub"
    private static let tokenAccount = "auth.token"
    private static let passwordAccount = "auth.password"

    static var token: String? {
        read(tokenAccount)
    }

    static func saveToken(_ token: String) {
        write(token, account: tokenAccount)
    }

    static func deleteToken() {
        delete(tokenAccount)
    }

    static var savedPassword: String? {
        read(passwordAccount)
    }

    static func savePassword(_ password: String) {
        write(password, account: passwordAccount)
    }

    static func deletePassword() {
        delete(passwordAccount)
    }

    // MARK: - 基础操作

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
