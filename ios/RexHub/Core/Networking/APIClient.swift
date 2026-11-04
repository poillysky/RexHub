import Foundation
import SwiftUI

// MARK: - 领域模型

struct AuthUser: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

/// 会话只保存「凭证 + 用户 + 到期时间」，DTO 不进页面。
struct AuthSession: Hashable, Sendable {
    let token: String
    let user: AuthUser
    let expiresAt: Date

    init(token: String, user: AuthUser, expiresAt: Date = .distantFuture) {
        self.token = token
        self.user = user
        self.expiresAt = expiresAt
    }
}

// MARK: - 错误模型

enum APIError: LocalizedError, Equatable {
    case offline
    case unreachable
    case timeout
    case cancelled
    case unauthorized
    case forbidden
    case notFound
    case badRequest(String?)
    case conflict(String?)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .offline:
            return "网络未连接，请检查 Wi-Fi 或蜂窝网络"
        case .unreachable:
            return "无法连接服务器，请检查地址和网络"
        case .timeout:
            return "请求超时，请重试"
        case .cancelled:
            return nil
        case .unauthorized:
            return "账号或密码错误"
        case .forbidden:
            return "没有权限访问该内容"
        case .notFound:
            return "内容不存在或已被删除"
        case .badRequest(let detail):
            return detail ?? "请求参数不正确"
        case .conflict(let detail):
            return detail ?? "服务端状态冲突，请稍后重试"
        case .rateLimited:
            return "请求过于频繁，请稍后重试"
        case .server(let status):
            return "服务器返回错误（\(status)）"
        case .decoding:
            return "服务器响应格式不正确"
        }
    }

    /// 仅网络抖动、超时、限流与 5xx 值得重试。
    var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .rateLimited:
            return true
        case .server(let status):
            return (500...599).contains(status)
        default:
            return false
        }
    }

    var retryDelay: TimeInterval? {
        switch self {
        case .rateLimited(let retryAfter):
            return retryAfter
        default:
            return nil
        }
    }
}

// MARK: - 客户端

struct APIClient: Sendable {
    let baseURL: URL
    var token: String?
    var timeout: TimeInterval = 10
    var maxRetries: Int = 2
    /// 直链解析要等服务端转存 + 取地址，比普通请求慢，单独放宽到 30s。
    var playbackResolveTimeout: TimeInterval = 30

    /// 登录拿到 token 后复用同一份配置。
    func withToken(_ token: String?) -> APIClient {
        var copy = self
        copy.token = token
        return copy
    }

    /// 退出登录 / 切换服务端时取消所有在途请求。
    static func cancelAllInflight() {
        URLSession.shared.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    // MARK: 接口

    func login(username: String, password: String) async throws -> AuthSession {
        let body = try JSONEncoder().encode(LoginBody(username: username, password: password))
        let data = try await send(
            path: "api/auth/login",
            method: "POST",
            body: body,
            authorized: false,
            retryable: false
        )
        let response = try decode(LoginResponse.self, from: data)
        return AuthSession(
            token: response.token,
            user: response.user,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    /// 启动时校验会话；仅 401/403 表示凭证失效。
    func currentUser() async throws -> AuthUser {
        let data = try await send(
            path: "api/auth/me",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(AuthUser.self, from: data)
    }

    /// 修改密码：旧密码由服务端校验，成功后旧会话仍有效。
    func changePassword(current: String, new: String) async throws {
        let body = try JSONEncoder().encode(
            ChangePasswordBody(oldPassword: current, newPassword: new)
        )
        _ = try await send(
            path: "api/auth/password",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false
        )
    }


    /// 图标库配置由服务端统一维护，App 只做管理端。
    func iconLibraries() async throws -> [String] {
        let data = try await send(
            path: "api/settings/icon-libraries",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(IconLibrariesResponse.self, from: data).urls
    }

    /// 保存图标库列表，返回服务端清洗后的结果。
    func updateIconLibraries(_ urls: [String]) async throws -> [String] {
        let body = try JSONEncoder().encode(IconLibrariesBody(urls: urls))
        let data = try await send(
            path: "api/settings/icon-libraries",
            method: "PUT",
            body: body,
            authorized: true,
            retryable: false
        )
        return try decode(IconLibrariesResponse.self, from: data).urls
    }

    /// 列网盘目录；`cid == "0"` 为根目录。
    func panList(cid: String = "0", offset: Int = 0, limit: Int = 200) async throws -> PanList {
        let data = try await send(
            path: "api/pan/list",
            method: "GET",
            query: ["cid": cid, "offset": String(offset), "limit": String(limit)],
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(PanList.self, from: data)
    }

    /// 只解析播放直链，视频流量由客户端直连 115 CDN。
    func panPlay(pickcode: String) async throws -> PanPlayInfo {
        let data = try await send(
            path: "api/pan/play",
            method: "GET",
            query: ["pickcode": pickcode],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: playbackResolveTimeout
        )
        return try decode(PanPlayInfo.self, from: data)
    }

    /// 取全量观看进度，用于跨设备补齐列表里的续播圆环。
    func panPlaybackProgress() async throws -> [PanPlaybackProgress] {
        let data = try await send(
            path: "api/pan/progress",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(PanProgressResponse.self, from: data).items
    }

    /// 上报观看进度；`position <= 0` 表示看完或没看，服务端会删除该记录。
    func panUpdateProgress(pickcode: String, position: Double, duration: Double) async throws {
        let body = try JSONEncoder().encode(
            PanProgressBody(pickcode: pickcode, position: position, duration: duration)
        )
        _ = try await send(
            path: "api/pan/progress",
            method: "PUT",
            body: body,
            authorized: true,
            retryable: false
        )
    }

    /// 取图片缩略图字节，由服务端代理 115，Cookie 不出服务端。
    func panThumbnail(sha1: String) async throws -> Data {
        try await send(
            path: "api/pan/thumb",
            method: "GET",
            query: ["sha1": sha1],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 20
        )
    }

    /// 115 账号快照：头像、VIP 与容量由服务端探测后返回。
    func panAccount() async throws -> PanAccount {
        let data = try await send(
            path: "api/pan/account",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: playbackResolveTimeout
        )
        return try decode(PanAccount.self, from: data)
    }

    /// 服务管理：只读服务卡片与在线状态，凭据字段不下发。
    func serviceList() async throws -> [ServiceCard] {
        let data = try await send(
            path: "api/services",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(ServiceListResponse.self, from: data).items
    }

    /// 可参与搜索的自托管服务。
    func searchServices() async throws -> [SearchService] {
        let data = try await send(
            path: "api/search/services",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(SearchServicesResponse.self, from: data).items
    }

    /// 跨服务检索资源；`serviceIDs` 为空时由服务端搜索全部可用服务。
    func searchResources(
        keyword: String,
        serviceIDs: Set<String>,
        offset: Int = 0
    ) async throws -> SearchResponse {
        let data = try await send(
            path: "api/search",
            method: "GET",
            query: [
                "q": keyword,
                "svc": serviceIDs.sorted().joined(separator: ","),
                "offset": String(offset),
            ],
            body: nil,
            authorized: true,
            // 检索本身按来源各自限时，最长的一次可能接近一分钟；
            // 客户端不再设短超时，超时后由结果页自己静默续搜。
            retryable: false,
            requestTimeout: 120
        )
        return try decode(SearchResponse.self, from: data)
    }

    // MARK: 影视

    /// 服务端 TMDB 插件声明的栏目。
    func mediaCatalogs() async throws -> [MediaCatalog] {
        let data = try await send(
            path: "api/media/catalogs",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(MediaCatalogsResponse.self, from: data).items
    }

    /// 栏目分页海报；插件按页向上游取数据，页与页之间可能重复，由页面自行去重。
    func mediaList(catalog: String, page: Int) async throws -> MediaListResponse {
        let data = try await send(
            path: "api/media/list",
            method: "GET",
            query: ["catalog": catalog, "page": String(page)],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MediaListResponse.self, from: data)
    }

    /// 影视详情（简介、演职员、预告片、剧集分集）。
    func mediaDetail(id: String) async throws -> MediaDetail {
        let data = try await send(
            path: "api/media/detail",
            method: "GET",
            query: ["id": id],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MediaDetail.self, from: data)
    }

    /// TMDB 图片统一走服务端代理：图片接口公开，不需要带 token。
    func mediaImageURL(path: String, size: String = "w500") -> URL? {
        guard !path.isEmpty else { return nil }
        return url(for: "api/media/image", query: ["path": path, "size": size])
    }

    /// 云下载任务列表。`stat`：0 全部 / 12 进行中 / 9 失败 / 11 已完成。
    func panCloudTasks(stat: Int = 0, page: Int = 1, pageSize: Int = 30) async throws -> PanCloudTasks {
        let data = try await send(
            path: "api/pan/cloud",
            method: "GET",
            query: [
                "stat": String(stat),
                "page": String(page),
                "page_size": String(pageSize),
            ],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: playbackResolveTimeout
        )
        return try decode(PanCloudTasks.self, from: data)
    }

    /// 添加云下载任务，支持 HTTP / HTTPS / FTP / 磁力 / 电驴链接。
    func panCloudAdd(urls: [String], cid: String = "0") async throws -> Int {
        let body = try JSONEncoder().encode(PanCloudAddBody(urls: urls, cid: cid))
        let data = try await send(
            path: "api/pan/cloud",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
        return try decode(PanCloudAddResult.self, from: data).count
    }

    /// 资源转存：115 分享链接走接收分享，磁力 / 电驴 / 直链走云下载。
    func panSave(urls: [String], password: String = "", cid: String = "0") async throws -> PanSaveResult {
        let body = try JSONEncoder().encode(
            PanSaveBody(urls: urls, password: password, cid: cid)
        )
        let data = try await send(
            path: "api/pan/save",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
        return try decode(PanSaveResult.self, from: data)
    }

    /// 重试失败的云下载任务。
    func panCloudRetry(infoHash: String) async throws {
        _ = try await send(
            path: "api/pan/cloud/retry",
            method: "POST",
            body: try JSONEncoder().encode(PanCloudTaskBody(infoHash: infoHash)),
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
    }

    /// 删除云下载任务（不影响已保存到网盘的文件）。
    func panCloudDelete(infoHash: String) async throws {
        _ = try await send(
            path: "api/pan/cloud/delete",
            method: "POST",
            body: try JSONEncoder().encode(PanCloudTaskBody(infoHash: infoHash)),
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
    }

    /// 在当前目录新建文件夹。
    func panCreateFolder(cid: String, name: String) async throws {
        let body = try JSONEncoder().encode(PanFolderBody(cid: cid, name: name))
        _ = try await send(
            path: "api/pan/folder",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
    }

    /// 批量删除，115 侧会移入回收站。
    func panDelete(ids: [String]) async throws {
        let body = try JSONEncoder().encode(PanDeleteBody(ids: ids))
        _ = try await send(
            path: "api/pan/delete",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
    }

    /// 重命名单个文件 / 文件夹，`name` 需带扩展名。
    func panRename(id: String, name: String) async throws {
        let body = try JSONEncoder().encode(PanRenameBody(id: id, name: name))
        _ = try await send(
            path: "api/pan/rename",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
    }

    /// 批量重命名：一次请求提交多组「id → 新名称」，名称需带扩展名。
    func panRenameBatch(_ items: [PanRenamePair]) async throws {
        let body = try JSONEncoder().encode(PanRenameBatchBody(items: items))
        _ = try await send(
            path: "api/pan/rename-batch",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
    }

    /// 批量移动 / 复制到目标目录，`cid` 为 "0" 表示根目录。
    func panMove(ids: [String], to cid: String) async throws {
        try await transfer(path: "api/pan/move", ids: ids, cid: cid)
    }

    func panCopy(ids: [String], to cid: String) async throws {
        try await transfer(path: "api/pan/copy", ids: ids, cid: cid)
    }

    private func transfer(path: String, ids: [String], cid: String) async throws {
        let body = try JSONEncoder().encode(PanTransferBody(ids: ids, cid: cid))
        _ = try await send(
            path: path,
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: playbackResolveTimeout
        )
    }

    /// 上传本地文件到网盘目录。请求体写入临时文件，避免大文件占满内存。
    func panUpload(fileName: String, fileURL: URL, cid: String) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rex-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let output = try FileHandle(forWritingTo: tempURL)
        defer { try? output.close() }

        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")
        var head = "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"cid\"\r\n\r\n\(cid)\r\n"
        head += "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(head.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()

        var request = URLRequest(url: url(for: "api/pan/upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw APIError.cancelled
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.decoding }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 400:
            throw APIError.badRequest(Self.detail(from: data))
        case 409:
            throw APIError.conflict(Self.detail(from: data))
        case 429:
            throw APIError.rateLimited(retryAfter: http.retryAfterSeconds)
        default:
            throw APIError.server(status: http.statusCode)
        }
    }

    // MARK: 请求

    private func send(
        path: String,
        method: String,
        query: [String: String]? = nil,
        body: Data?,
        authorized: Bool,
        retryable: Bool,
        requestTimeout: TimeInterval? = nil
    ) async throws -> Data {
        var attempt = 0

        while true {
            do {
                return try await perform(
                    path: path,
                    method: method,
                    query: query,
                    body: body,
                    authorized: authorized,
                    requestTimeout: requestTimeout
                )
            } catch let error as APIError {
                guard retryable, error.isRetryable, attempt < maxRetries else { throw error }
                attempt += 1
                let base = error.retryDelay ?? pow(2, Double(attempt - 1)) * 0.3
                let jitter = Double.random(in: 0...0.15)
                try await Task.sleep(for: .seconds(base + jitter))
            }
        }
    }

    private func perform(
        path: String,
        method: String,
        query: [String: String]?,
        body: Data?,
        authorized: Bool,
        requestTimeout: TimeInterval?
    ) async throws -> Data {
        var request = URLRequest(url: url(for: path, query: query))
        request.httpMethod = method
        request.timeoutInterval = requestTimeout ?? timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if authorized, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw APIError.cancelled
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.decoding }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 400:
            throw APIError.badRequest(Self.detail(from: data))
        case 409:
            throw APIError.conflict(Self.detail(from: data))
        case 429:
            throw APIError.rateLimited(retryAfter: http.retryAfterSeconds)
        default:
            throw APIError.server(status: http.statusCode)
        }
    }

    private func url(for path: String, query: [String: String]? = nil) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        let prefix = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = prefix + path
        components.queryItems = query?
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        components.fragment = nil
        return components.url ?? baseURL
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private static func map(_ error: URLError) -> APIError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            return .unreachable
        }
    }

    private static func detail(from data: Data) -> String? {
        struct Envelope: Decodable { let detail: String? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.detail
    }
}

// MARK: - DTO

private struct LoginBody: Encodable {
    let username: String
    let password: String
}

private struct ChangePasswordBody: Encodable {
    let oldPassword: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case oldPassword = "old_password"
        case newPassword = "new_password"
    }
}

private struct LoginResponse: Decodable {
    let token: String
    let expiresIn: Int
    let user: AuthUser
}

// MARK: - 外观配置 DTO

private struct IconLibrariesBody: Encodable {
    let urls: [String]
}

private struct IconLibrariesResponse: Decodable {
    let urls: [String]
}

// MARK: - 网盘 DTO

struct PanItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDir: Bool
    let size: Int64
    let pickcode: String
    let sha1: String
    let updatedAt: Int64
}

struct PanList: Decodable, Sendable {
    let cid: String
    let offset: Int
    let total: Int
    let items: [PanItem]
}

struct PanPlayInfo: Decodable, Sendable {
    let url: URL
    let headers: [String: String]
    let expiresIn: Int
}

/// 跨设备观看进度。`updatedAt` 为服务端写入时间（Unix 秒），本地比它新时不覆盖。
struct PanPlaybackProgress: Decodable, Sendable {
    let pickcode: String
    let position: Double
    let duration: Double
    let updatedAt: Double
}

struct ServiceCard: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: String
    let categoryLabel: String
    let host: String
    let port: Int
    let url: String
    let notes: String
    let online: Bool?
    let latency: Int?
}

struct ServiceListResponse: Decodable, Sendable {
    let items: [ServiceCard]
}

// MARK: - 搜索 DTO

struct SearchService: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let categoryLabel: String
    let notes: String
}

struct SearchResult: Decodable, Identifiable, Hashable, Sendable {
    let title: String
    /// 色花堂的帖子标题与文件名分开下发：`title` 用于列表和详情页顶部，
    /// `resourceName` 是真实文件名，只在两者不同时才有值。
    let resourceName: String?
    let link: String
    let password: String
    let kind: String

    // 详情页用的资源元数据；老服务端不下发这些字段，按 nil 处理
    let size: Int64?
    let sizeText: String?
    let filesCount: Int?
    /// ISO 8601 收录时间，展示前由页面本地化。
    let createdAt: String?
    let seeders: Int?
    let leechers: Int?
    let resolution: String?
    let codec: String?
    let releaseGroup: String?
    let boardName: String?
    let sourceUrl: String?
    let description: String?
    let previewImages: [String]?
    let actresses: [String]?
    let code: String?
    let censored: String?

    var id: String { link.isEmpty ? title : link + "|" + title }
}

struct SearchGroup: Decodable, Sendable {
    let id: String
    let name: String
    let error: String
    let hasMore: Bool
    /// 还有匹配数据，但服务端已达到单次检索的候选上限（老服务端没有该字段）
    let truncated: Bool?
    let items: [SearchResult]
}

struct SearchResponse: Decodable, Sendable {
    let keyword: String
    let groups: [SearchGroup]
}

private struct SearchServicesResponse: Decodable {
    let items: [SearchService]
}

// MARK: - 影视 DTO

struct MediaCatalog: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// movie / series
    let mediaType: String

    var isMovie: Bool { mediaType == "movie" }
}

struct MediaItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let mediaType: String
    let title: String
    /// TMDB 图片路径（如 `/abc.jpg`），非完整地址；由 `mediaImageURL` 拼成代理地址。
    let poster: String
    let backdrop: String
    let overview: String
    /// 年份区间，剧集形如 `2024–`。
    let year: String
    let rating: Double?

    var isMovie: Bool { mediaType == "movie" }
    var yearText: String { year.isEmpty ? "" : year }
}

struct MediaListResponse: Decodable, Sendable {
    let catalog: String
    let page: Int
    let hasMore: Bool
    let items: [MediaItem]
}

private struct MediaCatalogsResponse: Decodable {
    let items: [MediaCatalog]
}

struct MediaTrailer: Decodable, Hashable, Sendable {
    let name: String
    let url: String
}

struct MediaVideo: Decodable, Identifiable, Hashable, Sendable {
    let season: Int
    let episode: Int
    let title: String
    let overview: String
    /// 剧集剧照路径，可能为空。
    let still: String
    let rating: Double?
    let released: String

    var id: String { "\(season)-\(episode)" }
    var code: String { "S\(season)E\(episode)" }
}

/// 演员条目：服务端直连 TMDB 补齐头像与角色，`profile` 是 TMDB 头像路径。
struct MediaCastMember: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let character: String
    /// 头像路径，可能为空；为空时 UI 回落到姓名首字。
    let profile: String

    var id: String { name + "#" + character }
}

struct MediaDetail: Decodable, Sendable {
    let id: String
    let mediaType: String
    let title: String
    let poster: String
    let backdrop: String
    let logo: String
    let overview: String
    let tagline: String
    let year: String
    let released: String
    let rating: Double?
    let runtime: String
    let genres: [String]
    let countries: [String]
    let cast: [String]
    let director: [String]
    let writer: [String]
    let trailers: [MediaTrailer]
    let videos: [MediaVideo]
    /// 带头像的演员列表；老服务端没有该字段时为空。
    let castPeople: [MediaCastMember]?
    /// 相关推荐；老服务端没有该字段时为空。
    let recommendations: [MediaItem]?

    var isMovie: Bool { mediaType == "movie" }

    /// 剧集按季分组，季内按集号升序；电影返回空数组。
    var seasons: [(season: Int, episodes: [MediaVideo])] {
        Dictionary(grouping: videos, by: \.season)
            .map { (season: $0.key, episodes: $0.value.sorted { $0.episode < $1.episode }) }
            .sorted { $0.season < $1.season }
    }
}

/// 115 账号快照。`status` 为 ok / pending / invalid / unbound。
struct PanAccount: Decodable, Sendable {
    let bound: Bool
    let status: String
    let username: String
    let avatar: String
    let vipActive: Bool
    let vipForever: Bool
    let vipExpire: String
    let total: Int64?
    let used: Int64?
    let message: String
}

struct PanCloudTasks: Decodable, Sendable {
    let counts: PanCloudCounts
    let quota: PanCloudQuota
    let page: Int
    let pageCount: Int
    let tasks: [PanCloudTask]
}

struct PanCloudCounts: Decodable, Sendable {
    let total: Int
    let downloading: Int
    let failed: Int
    let finished: Int
}

struct PanCloudQuota: Decodable, Sendable {
    let remaining: Int
    let total: Int
}

/// 云下载任务。`status` 为 115 的 display_status，例如 failed / downloading / finished。
struct PanCloudTask: Decodable, Identifiable, Hashable, Sendable {
    let infoHash: String
    let name: String
    let size: Int64
    let addTime: Int64
    let status: String
    let statusText: String
    let percent: Double
    let url: String
    let actions: [String]

    var id: String { infoHash }
}

private struct PanCloudAddResult: Decodable {
    let count: Int
}

struct PanSaveResult: Decodable {
    let mode: String
    let count: Int
    let received: Int
    let cloud: Int
    let errors: [String]
}

private struct PanSaveBody: Encodable {
    let urls: [String]
    let password: String
    let cid: String
}

private struct PanCloudAddBody: Encodable {
    let urls: [String]
    let cid: String
}

private struct PanCloudTaskBody: Encodable {
    let infoHash: String
}

private struct PanFolderBody: Encodable {
    let cid: String
    let name: String
}

private struct PanDeleteBody: Encodable {
    let ids: [String]
}

private struct PanRenameBody: Encodable {
    let id: String
    let name: String
}

struct PanRenamePair: Encodable, Hashable, Sendable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

private struct PanRenameBatchBody: Encodable {
    let items: [PanRenamePair]
}

private struct PanTransferBody: Encodable {
    let ids: [String]
    let cid: String
}

private struct PanProgressResponse: Decodable {
    let items: [PanPlaybackProgress]
}

private struct PanProgressBody: Encodable {
    let pickcode: String
    let position: Double
    let duration: Double
}

private extension HTTPURLResponse {
    var retryAfterSeconds: TimeInterval? {
        guard let raw = value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw)
    }
}

// MARK: - 依赖注入

private struct APIClientKey: EnvironmentKey {
    static let defaultValue: APIClient? = nil
}

extension EnvironmentValues {
    /// 当前会话的客户端，由 `RootView` 注入；页面不自行构造，保证超时与重试策略一致。
    var apiClient: APIClient? {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }
}
