import Foundation

// MARK: - 错误

enum EmbyError: LocalizedError {
    case invalidURL
    case unauthorized
    case http(Int)
    case decoding
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址不正确，请填写如 192.168.1.10:8096"
        case .unauthorized:
            return "用户名或密码错误"
        case .http(let status):
            return "服务器返回错误（\(status)）"
        case .decoding:
            return "服务器响应格式不正确，请确认是 Emby 服务"
        case .offline:
            return "无法连接服务器，请检查地址与网络"
        }
    }
}

// MARK: - 客户端

/// 直连 Emby 的最小客户端：登录、媒体库、条目列表与图片地址。
struct EmbyClient: Sendable {
    let baseURL: URL
    var token: String?

    init?(host: String, token: String? = nil) {
        guard let url = Self.normalizedURL(from: host) else { return nil }
        self.baseURL = url
        self.token = token
    }

    /// 把用户输入（可省略 scheme）整理成可请求的地址。
    static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: 接口

    func authenticate(username: String, password: String) async throws -> EmbyAuth {
        let body = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password
        ])

        let data = try await send(
            "Users/AuthenticateByName",
            method: "POST",
            body: body,
            token: nil
        )
        let payload = try decode(AuthPayload.self, from: data)

        return EmbyAuth(
            token: payload.accessToken,
            userId: payload.user.id,
            userName: payload.user.name,
            serverName: payload.serverName ?? ""
        )
    }

    func libraries(userID: String) async throws -> [EmbyLibrary] {
        let data = try await send(
            "Users/\(userID)/Views",
            query: [
                URLQueryItem(name: "IncludeExternalContent", value: "false")
            ]
        )
        let payload = try decode(ItemsPayload<LibraryPayload>.self, from: data)

        return payload.items.map {
            EmbyLibrary(
                id: $0.id,
                name: $0.name,
                collectionType: $0.collectionType,
                imageTag: $0.imageTags?["Primary"]
            )
        }
    }

    /// 电影 / 剧集总数：只取首条记录，靠响应里的 TotalRecordCount 拿总量。
    func counts(userID: String) async throws -> EmbyCounts {
        async let movies = totalCount(userID: userID, type: "Movie")
        async let series = totalCount(userID: userID, type: "Series")
        return try await EmbyCounts(movies: movies, series: series)
    }

    private func totalCount(userID: String, type: String) async throws -> Int {
        let data = try await send(
            "Users/\(userID)/Items",
            query: [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: type),
                URLQueryItem(name: "EnableImages", value: "false"),
                URLQueryItem(name: "Limit", value: "1")
            ]
        )
        return try decode(CountPayload.self, from: data).total
    }

    func items(userID: String, parentID: String, limit: Int = 200) async throws -> [EmbyItem] {
        let data = try await send(
            "Users/\(userID)/Items",
            query: [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
                URLQueryItem(name: "Limit", value: "\(limit)")
            ]
        )
        let payload = try decode(ItemsPayload<ItemPayload>.self, from: data)

        return payload.items.map {
            EmbyItem(
                id: $0.id,
                name: $0.name,
                type: $0.type ?? "",
                imageTag: $0.imageTags?["Primary"],
                productionYear: $0.productionYear
            )
        }
    }

    /// 图片走 `api_key` 查询参数：AsyncImage 无法附加自定义请求头。
    func imageURL(itemID: String, tag: String?, maxWidth: Int = 480) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Items/\(itemID)/Images/Primary"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var query = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "90")
        ]
        if let tag, !tag.isEmpty {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        if let token, !token.isEmpty {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = query
        return components.url
    }

    // MARK: 请求

    private func send(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        token: String? = nil
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw EmbyError.invalidURL
        }

        if !query.isEmpty {
            components.queryItems = query
        }

        guard let url = components.url else { throw EmbyError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        // 默认带客户端自带的访问令牌，登录接口显式传空表示匿名。
        request.setValue(authorizationHeader(token: token ?? self.token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EmbyError.offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw EmbyError.decoding
        }
        guard (200...299).contains(http.statusCode) else {
            throw http.statusCode == 401 ? EmbyError.unauthorized : EmbyError.http(http.statusCode)
        }
        return data
    }

    private func authorizationHeader(token: String?) -> String {
        var parts = [
            "MediaBrowser Client=\"RexHub\"",
            "Device=\"iPhone\"",
            "DeviceId=\"\(EmbyDevice.id)\"",
            "Version=\"\(EmbyDevice.appVersion)\""
        ]
        if let token, !token.isEmpty {
            parts.append("Token=\"\(token)\"")
        }
        return parts.joined(separator: ", ")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw EmbyError.decoding
        }
    }
}

// MARK: - 设备标识

enum EmbyDevice {
    private static let key = "rexhub.emby.deviceId"

    /// Emby 用 DeviceId 区分客户端，首次生成后固定下来。
    static var id: String {
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - 解码模型

/// 服务器可播放条目数量（电影 / 剧集）。
struct EmbyCounts: Sendable, Equatable {
    let movies: Int
    let series: Int
}

private struct CountPayload: Decodable {
    let total: Int

    private enum CodingKeys: String, CodingKey {
        case total = "TotalRecordCount"
    }
}

private struct AuthPayload: Decodable {
    let user: AuthUserPayload
    let accessToken: String
    let serverName: String?

    private enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverName = "ServerName"
    }
}

private struct AuthUserPayload: Decodable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

private struct ItemsPayload<Item: Decodable>: Decodable {
    let items: [Item]

    private enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

private struct LibraryPayload: Decodable {
    let id: String
    let name: String
    let collectionType: String?
    let imageTags: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
    }
}

private struct ItemPayload: Decodable {
    let id: String
    let name: String
    let type: String?
    let productionYear: Int?
    let imageTags: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case productionYear = "ProductionYear"
        case imageTags = "ImageTags"
    }
}
