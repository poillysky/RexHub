import Foundation

/// 服务端地址的解析与持久化。
/// 支持 `192.168.1.10:8080`、`rex.local`、`https://hub.example.com` 等写法。
enum ServerConfig {
    private static let storageKey = "rexhub.server.address"
    private static let httpsKey = "rexhub.server.https"

    static var savedText: String {
        get { UserDefaults.standard.string(forKey: storageKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    /// 是否强制使用 HTTPS 访问服务端。
    static var httpsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: httpsKey) }
        set { UserDefaults.standard.set(newValue, forKey: httpsKey) }
    }

    static var baseURL: URL? { resolve(savedText) }

    /// 解析服务端地址；`useHTTPS` 为空时使用已保存的开关状态。
    static func resolve(_ raw: String, useHTTPS: Bool? = nil) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let https = useHTTPS ?? httpsEnabled
        let hostText = trimmed.range(of: "://").map { String(trimmed[$0.upperBound...]) } ?? trimmed
        let text = "\(https ? "https" : "http")://\(hostText)"

        guard var components = URLComponents(string: text),
              let host = components.host,
              isValidHost(host) else { return nil }

        components.query = nil
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }

    /// 输入中是否已显式写了协议，用于同步开关状态。
    static func explicitHTTPS(in raw: String) -> Bool? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("https://") { return true }
        if text.hasPrefix("http://") { return false }
        return nil
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if isIPv4(host) { return true }
        return host.contains(".") && !host.contains(" ")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }
}
