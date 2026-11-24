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

    // MARK: - 多账号密码

    /// 历史账号按「服务端 + 账号」各存一份密码，互不覆盖。
    static func password(forKey key: String) -> String? {
        read("auth.password.\(key)")
    }

    static func savePassword(_ password: String, forKey key: String) {
        write(password, account: "auth.password.\(key)")
    }

    static func deletePassword(forKey key: String) {
        delete("auth.password.\(key)")
    }

    /// 通用安全字符串读写：用于保存账号、历史记录等不宜落在 UserDefaults 的数据。
    static func string(forKey key: String) -> String? {
        read("app.\(key)")
    }

    static func saveString(_ value: String, forKey key: String) {
        write(value, account: "app.\(key)")
    }

    static func deleteString(forKey key: String) {
        delete("app.\(key)")
    }

    // MARK: - 基础操作

    private static func read(_ account: String) -> String? {
        keychainRead(account) ?? fallbackRead(account)
    }

    private static func keychainRead(_ account: String) -> String? {
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
            // 首次解锁后可用（后台播放取流需要），但不随 iCloud 钥匙串或加密备份迁移到别的设备。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey(account))
        } else {
            RexLog.session.error("Keychain 写入失败 status=\(status)")
            #if targetEnvironment(simulator)
            // 只有模拟器在缺少 keychain 授权时才退回沙盒存储，真机绝不把密码写进 UserDefaults。
            fallbackWrite(value, account: account)
            #endif
        }
    }

    private static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(account))
    }

    // MARK: - 无签名环境回退

    private static func fallbackKey(_ account: String) -> String {
        "rexhub.secureFallback.\(account)"
    }

    private static func fallbackRead(_ account: String) -> String? {
        #if targetEnvironment(simulator)
        UserDefaults.standard.string(forKey: fallbackKey(account))
        #else
        nil
        #endif
    }

    private static func fallbackWrite(_ value: String, account: String) {
        UserDefaults.standard.set(value, forKey: fallbackKey(account))
    }
}
