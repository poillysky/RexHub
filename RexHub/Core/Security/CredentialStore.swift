import Foundation

/// 「记住密码」：账号存 UserDefaults，密码独立存放在 Keychain。
enum CredentialStore {
    private static let accountKey = "rexhub.auth.rememberedAccount"

    static var account: String? {
        get { UserDefaults.standard.string(forKey: accountKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: accountKey)
            } else {
                UserDefaults.standard.removeObject(forKey: accountKey)
            }
        }
    }

    static var password: String? {
        Keychain.savedPassword
    }

    static func remember(account: String, password: String) {
        self.account = account
        Keychain.savePassword(password)
    }

    static func forget() {
        account = nil
        Keychain.deletePassword()
    }
}
