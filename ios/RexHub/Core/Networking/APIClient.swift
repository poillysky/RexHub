import Foundation
import SwiftUI

// MARK: - 领域模型

struct AuthUser: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let isAdmin: Bool

    init(id: String, name: String, isAdmin: Bool = false) {
        self.id = id
        self.name = name
        self.isAdmin = isAdmin
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, username, isAdmin
    }

    private enum LegacyKeys: String, CodingKey {
        case isAdmin = "is_admin"
    }

    /// 服务端返回 `{id, username, is_admin}`，本地会话文件存 `{id, name, isAdmin}`，
    /// 两套字段都在这里兼容。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .id) {
            id = value
        } else if let value = try? container.decode(Int.self, forKey: .id) {
            id = String(value)
        } else {
            id = ""
        }

        name = (try? container.decode(String.self, forKey: .username))
            ?? (try? container.decode(String.self, forKey: .name))
            ?? ""

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        isAdmin = (try? legacy.decode(Bool.self, forKey: .isAdmin))
            ?? (try? container.decode(Bool.self, forKey: .isAdmin))
            ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isAdmin, forKey: .isAdmin)
    }
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
        let response = try decodeEnvelope(LoginPayload.self, from: data)
        // 服务端会话固定 30 天，登录响应不返回到期时间，这里按同一口径记录。
        return AuthSession(
            token: response.token,
            user: response.user,
            expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60)
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
        return try decodeEnvelope(AuthUser.self, from: data)
    }

    /// 修改密码：旧密码由服务端校验，成功后旧会话仍有效。
    func changePassword(current: String, new: String) async throws {
        let body = try JSONEncoder().encode(
            ChangePasswordBody(currentPassword: current, newPassword: new)
        )
        _ = try await send(
            path: "api/auth/password",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false
        )
    }


    /// 范围聚合搜索：返回裸 JSON（不包 Envelope）。
    func searchScope(
        scope: SearchScope,
        keyword: String,
        page: Int = 1,
        pageSize: Int = 20,
        options: ScopeSearchOptions = ScopeSearchOptions()
    ) async throws -> ScopeResponse {
        let data = try await send(
            path: "api/search/scope",
            method: "GET",
            query: [
                "scope": scope.rawValue,
                "keyword": keyword,
                "page": String(page),
                "page_size": String(pageSize),
                "sort_type": options.sort,
                "filter_time": options.filterTime,
                "filter_size": options.filterSize,
                "source": options.source,
            ],
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 40
        )
        return try decode(ScopeResponse.self, from: data)
    }

    // MARK: 短剧

    func dramaSites() async throws -> [DramaSite] {
        let data = try await send(
            path: "api/shortdrama/sites",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decode(DramaSiteList.self, from: data).items
    }

    func dramaCatalog(site: String, page: Int = 1) async throws -> DramaPage {
        let data = try await send(
            path: "api/shortdrama/\(site)/catalog",
            method: "GET",
            query: ["page": String(page)],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decode(DramaPage.self, from: data)
    }

    /// 不传 `site` 时跨站点全局搜索。
    func dramaSearch(keyword: String, page: Int = 1, site: String? = nil) async throws -> DramaPage {
        let data = try await send(
            path: site == nil ? "api/shortdrama/search" : "api/shortdrama/\(site!)/search",
            method: "GET",
            query: ["q": keyword, "page": String(page)],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decode(DramaPage.self, from: data)
    }

    func dramaRankLists(site: String) async throws -> [DramaRankGroup] {
        let data = try await send(
            path: "api/shortdrama/\(site)/lists",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decode(DramaRankListResponse.self, from: data).groups
    }

    func dramaRank(
        site: String,
        group: String,
        rank: String,
        filter: String = "",
        page: Int = 1
    ) async throws -> DramaPage {
        var query = ["group": group, "rank": rank, "page": String(page)]
        if !filter.isEmpty { query["filter"] = filter }
        let data = try await send(
            path: "api/shortdrama/\(site)/rank",
            method: "GET",
            query: query,
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decode(DramaPage.self, from: data)
    }

    func dramaSeries(site: String, id: String) async throws -> DramaSeries {
        let data = try await send(
            path: "api/shortdrama/\(site)/series/\(id)",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decode(DramaSeries.self, from: data)
    }

    /// 播放地址：服务端对 302 的片源直接跳 CDN，其余透传；token 走查询参数。
    func dramaStreamURL(site: String, episodeID: String) -> URL? {
        var query = ["token": token ?? ""]
        query = query.filter { !$0.value.isEmpty }
        return url(for: "api/shortdrama/\(site)/episodes/\(episodeID)/stream", query: query.isEmpty ? nil : query)
    }

    // MARK: AI 助手

    func assistantMeta() async throws -> AssistantMeta {
        let data = try await send(
            path: "api/ai/assistant/meta",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decodeEnvelope(AssistantMeta.self, from: data)
    }

    /// 非流式兜底：流式失败时仍能拿到完整回复。
    func assistantChat(
        message: String,
        history: [AssistantHistoryTurn] = []
    ) async throws -> AssistantReply {
        let body = try JSONEncoder().encode(
            AssistantChatBody(message: message, history: history, preferSources: [])
        )
        let data = try await send(
            path: "api/ai/assistant/chat",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: 120
        )
        return try decodeEnvelope(AssistantReply.self, from: data)
    }

    /// 流式对话：服务端用 SSE 推送检索状态与卡片，最终一帧带上完整回复。
    func assistantChatStream(
        message: String,
        history: [AssistantHistoryTurn] = [],
        preferSources: [String] = []
    ) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        let body = try? JSONEncoder().encode(
            AssistantChatBody(message: message, history: history, preferSources: preferSources)
        )
        let requestURL = url(for: "api/ai/assistant/chat/stream")
        let token = self.token

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: requestURL)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 180
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let body {
                        request.httpBody = body
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                    if let token {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.decoding
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        switch http.statusCode {
                        case 401: throw APIError.unauthorized
                        case 403: throw APIError.forbidden
                        case 404: throw APIError.notFound
                        case 429: throw APIError.rateLimited(retryAfter: nil)
                        default: throw APIError.server(status: http.statusCode)
                        }
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payloadText = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let payloadData = payloadText.data(using: .utf8),
                              let payload = try? decoder.decode(AssistantStreamPayload.self, from: payloadData) else {
                            continue
                        }

                        switch payload.event {
                        case "status":
                            if let text = payload.data.text, !text.isEmpty {
                                continuation.yield(AssistantStreamEvent(kind: .status(text)))
                            }
                        case "cards_partial":
                            continuation.yield(AssistantStreamEvent(kind: .cards(payload.data.cards)))
                        case "done":
                            let final = AssistantFinal(
                                reply: payload.data.reply ?? "",
                                cards: payload.data.cards,
                                steps: payload.data.steps,
                                usedLlm: payload.data.usedLlm ?? false,
                                toolSummary: payload.data.toolSummary ?? ""
                            )
                            continuation.yield(AssistantStreamEvent(kind: .done(final)))
                        case "error":
                            let message = payload.data.message ?? "助手调用失败"
                            continuation.yield(AssistantStreamEvent(kind: .failure(message)))
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 插件中心 / Stremio

    func installedPlugins() async throws -> [PluginInfo] {
        let data = try await send(
            path: "api/admin/plugin-framework/installed",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 30
        )
        return try decode(PluginListResponse.self, from: data).items
    }

    func pluginMarket(repository: String = "") async throws -> PluginMarket {
        var query: [String: String]? = nil
        if !repository.isEmpty { query = ["repository": repository] }
        let data = try await send(
            path: "api/admin/plugin-framework/market",
            method: "GET",
            query: query,
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
        return try decode(PluginMarket.self, from: data)
    }

    func pluginUpdates() async throws -> [PluginUpdateInfo] {
        let data = try await send(
            path: "api/admin/plugin-framework/updates",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
        return try decode(PluginUpdateResponse.self, from: data).items
    }

    func installPlugin(repository: String, id: String) async throws {
        _ = try await send(
            path: "api/admin/plugin-framework/install",
            method: "POST",
            body: try JSONEncoder().encode(PluginInstallBody(repository: repository, id: id)),
            authorized: true,
            retryable: false,
            requestTimeout: 120
        )
    }

    func setPluginEnabled(_ pluginID: String, enabled: Bool) async throws {
        _ = try await send(
            path: "api/admin/plugin-framework/\(pluginID)/\(enabled ? "enable" : "disable")",
            method: "POST",
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
    }

    func restartPlugin(_ pluginID: String) async throws {
        _ = try await send(
            path: "api/admin/plugin-framework/\(pluginID)/restart",
            method: "POST",
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
    }

    func updatePlugin(_ pluginID: String) async throws {
        _ = try await send(
            path: "api/admin/plugin-framework/\(pluginID)/update",
            method: "POST",
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 120
        )
    }

    func pluginLogs(_ pluginID: String, limit: Int = 120) async throws -> [String] {
        let data = try await send(
            path: "api/admin/plugin-framework/\(pluginID)/logs",
            method: "GET",
            query: ["limit": String(limit)],
            body: nil,
            authorized: true,
            retryable: true
        )
        return try decode(PluginLogs.self, from: data).lines
    }

    func stremioSnapshot() async throws -> StremioSnapshot {
        let data = try await send(
            path: "api/admin/stremio",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 30
        )
        return try decode(StremioSnapshot.self, from: data)
    }

    func addStremioAddon(url: String) async throws {
        _ = try await send(
            path: "api/admin/stremio/addons",
            method: "POST",
            body: try JSONEncoder().encode(StremioAddonBody(url: url)),
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
    }

    func setStremioAddonEnabled(slug: String, enabled: Bool) async throws {
        _ = try await send(
            path: "api/admin/stremio/addons/\(slug)/enabled",
            method: "PUT",
            body: try JSONEncoder().encode(StremioEnabledBody(enabled: enabled)),
            authorized: true,
            retryable: false,
            requestTimeout: 30
        )
    }

    func deleteStremioAddon(slug: String) async throws {
        _ = try await send(
            path: "api/admin/stremio/addons/\(slug)",
            method: "DELETE",
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 30
        )
    }

    // MARK: 色花堂板块

    func browse(
        page: Int = 1,
        pageSize: Int = 15,
        boardFid: String = "",
        board: String = "",
        keyword: String = ""
    ) async throws -> BrowseResult {
        var query = ["p": String(page), "ps": String(pageSize), "withTotalCount": "0"]
        if !boardFid.isEmpty { query["board_fid"] = boardFid }
        if !board.isEmpty { query["board"] = board }
        if !keyword.isEmpty { query["keyword"] = keyword }
        let data = try await send(
            path: "api/browse",
            method: "GET",
            query: query,
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 40
        )
        return try decodeEnvelope(BrowseResult.self, from: data)
    }

    // MARK: MoviePilot 影视

    func mpList(path: String, params: [String: String] = [:]) async throws -> MpListResult {
        var query = params
        query["path"] = path
        let data = try await send(
            path: "api/moviepilot/list",
            method: "GET",
            query: query,
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decodeEnvelope(MpListResult.self, from: data)
    }

    func mpDetail(source: String, id: String, mediaType: String) async throws -> MpDetail {
        let data = try await send(
            path: "api/moviepilot/detail",
            method: "GET",
            query: ["source": source, "id": id, "mediaType": mediaType],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decodeEnvelope(MpDetail.self, from: data)
    }

    func mpRelated(source: String, id: String, mediaType: String) async throws -> MpRelated {
        let data = try await send(
            path: "api/moviepilot/related",
            method: "GET",
            query: ["source": source, "id": id, "mediaType": mediaType],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decodeEnvelope(MpRelated.self, from: data)
    }

    /// 影视条目搜索：`source` 支持 tmdb / douban / bangumi / anilist。
    func mpMediaSearch(source: String, keyword: String, page: Int = 1) async throws -> MpSearchResult {
        let data = try await send(
            path: "api/moviepilot/media-search",
            method: "GET",
            query: ["source": source, "keyword": keyword, "page": String(page)],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 40
        )
        return try decodeEnvelope(MpSearchResult.self, from: data)
    }

    /// 影视片源聚合（插件 + Stremio addon），返回裸 JSON。
    func mediaStreams(
        id: String,
        imdb: String,
        mediaType: String,
        season: Int = 0,
        episode: Int = 0,
        title: String = ""
    ) async throws -> MediaStreamsResult {
        var query = ["id": id, "imdb": imdb, "mediaType": mediaType, "title": title]
        if season > 0 { query["season"] = String(season) }
        if episode > 0 { query["episode"] = String(episode) }
        let data = try await send(
            path: "api/media/streams",
            method: "GET",
            query: query,
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 30
        )
        return try decode(MediaStreamsResult.self, from: data)
    }

    /// 片源走同源代理，避免直链的防盗链与跨域问题；鉴权头随播放器携带。
    func mediaStreamProxyURL(raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        return url(for: "api/media/stream-proxy", query: ["url": raw])
    }

    /// 播放器需要的鉴权头（AVPlayer / KSPlayer 不自带 Cookie）。
    var authorizationHeaders: [String: String] {
        guard let token else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    // MARK: 115 扫码 / 目录

    func p115Folders(cid: String = "0") async throws -> P115FolderPage {
        let body = try JSONEncoder().encode(["cid": cid])
        let data = try await send(
            path: "api/settings/p115/folders",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: 40
        )
        return try decodeEnvelope(P115FolderPage.self, from: data)
    }

    func p115QRStart(app: String = "alipaymini") async throws -> P115QRStart {
        let data = try await send(
            path: "api/settings/p115/qrcode/start",
            method: "POST",
            body: try JSONEncoder().encode(P115QRStartBody(app: app)),
            authorized: true,
            retryable: false,
            requestTimeout: 40
        )
        return try decodeEnvelope(P115QRStart.self, from: data)
    }

    func p115QRStatus(uid: String, time: String, sign: String) async throws -> P115QRStatus {
        let body = try JSONEncoder().encode(P115QRStatusBody(uid: uid, time: time, sign: sign))
        let data = try await send(
            path: "api/settings/p115/qrcode/status",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false
        )
        return try decodeEnvelope(P115QRStatus.self, from: data)
    }

    func p115QRComplete(uid: String, app: String, save: Bool = true) async throws -> P115Settings {
        let body = try JSONEncoder().encode(P115QRCompleteBody(uid: uid, app: app, save: save))
        let data = try await send(
            path: "api/settings/p115/qrcode/complete",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: 40
        )
        return try decodeEnvelope(P115Settings.self, from: data)
    }

    // MARK: 服务设置（Envelope 包装）

    /// 读取服务配置。`path` 传 `api/settings/avdb` 这类相对路径。
    func fetchSettings<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await send(
            path: path,
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 30
        )
        return try decodeEnvelope(type, from: data)
    }

    /// 保存服务配置。
    func putSettings<T: Decodable>(_ path: String, json: Data, as type: T.Type) async throws -> T {
        let data = try await send(
            path: path,
            method: "PUT",
            body: json,
            authorized: true,
            retryable: false,
            requestTimeout: 40
        )
        return try decodeEnvelope(type, from: data)
    }

    /// 连接测试：只探测草稿配置，不落库。
    func postSettings<T: Decodable>(_ path: String, json: Data, as type: T.Type) async throws -> T {
        let data = try await send(
            path: path,
            method: "POST",
            body: json,
            authorized: true,
            retryable: false,
            requestTimeout: 40
        )
        return try decodeEnvelope(type, from: data)
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

    // MARK: 115 文件解压

    func panExtractConfig() async throws -> P115ExtractConfig {
        let data = try await send(
            path: "api/pan/extract/config",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(P115ExtractConfig.self, from: data)
    }

    func savePanExtractConfig(folderCid: String, folderName: String, password: String) async throws -> P115ExtractConfig {
        let body = try JSONEncoder().encode(
            P115ExtractConfigBody(folderCid: folderCid, folderName: folderName, password: password)
        )
        let data = try await send(
            path: "api/pan/extract/config",
            method: "PUT",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: 25
        )
        return try decode(P115ExtractConfig.self, from: data)
    }

    func panExtractStatus() async throws -> P115ExtractStatus {
        let data = try await send(
            path: "api/pan/extract/status",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(P115ExtractStatus.self, from: data)
    }

    func panExtractPreview(cid: String) async throws -> P115ExtractPreview {
        let data = try await send(
            path: "api/pan/extract/preview",
            method: "GET",
            query: ["cid": cid],
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
        return try decode(P115ExtractPreview.self, from: data)
    }

    func panExtractStart() async throws -> P115ExtractStatus {
        let data = try await send(
            path: "api/pan/extract/start",
            method: "POST",
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 30
        )
        return try decode(P115ExtractStatus.self, from: data)
    }

    func panExtractStop() async throws -> P115ExtractStatus {
        let data = try await send(
            path: "api/pan/extract/stop",
            method: "POST",
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 30
        )
        return try decode(P115ExtractStatus.self, from: data)
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

    // MARK: 片商（AVDB）

    /// 榜单：有码/无码/欧美/FC2 的日/周/月榜。
    func makerRank(category: MakerCategory, period: MakerPeriod) async throws -> MakerRankPage {
        let data = try await send(
            path: "api/makers/rank",
            method: "GET",
            query: ["category": category.rawValue, "period": period.rawValue],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerRankPage.self, from: data)
    }

    /// 最新：按磁链更新时间或发行日期排序，可按含磁链/含字幕筛选。
    func makerLatest(
        category: MakerCategory,
        page: Int = 1,
        sort: MakerLatestSort = .update,
        filter: MakerLatestFilter = .all
    ) async throws -> MakerMoviePage {
        let data = try await send(
            path: "api/makers/latest",
            method: "GET",
            query: [
                "category": category.rawValue,
                "page": String(page),
                "limit": "24",
                "sort_by": sort.rawValue,
                "filter_by": filter.rawValue,
            ],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerMoviePage.self, from: data)
    }

    /// TOP250：不传年份时为按类别榜，传年份时为该年度榜。
    func makerTop(category: MakerCategory, page: Int = 1, year: String? = nil) async throws -> MakerMoviePage {
        var query = ["category": category.rawValue, "page": String(page)]
        if let year, !year.isEmpty { query["year"] = year }
        let data = try await send(
            path: "api/makers/top",
            method: "GET",
            query: query,
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerMoviePage.self, from: data)
    }

    /// 热播：可播放榜，不随类别变化；`filterBy`：all 热播 / high_score 热门。
    func makerPlayback(period: MakerPeriod, filterBy: String = "all") async throws -> MakerMoviePage {
        let data = try await send(
            path: "api/makers/playback",
            method: "GET",
            query: ["period": period.rawValue, "filter_by": filterBy],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerMoviePage.self, from: data)
    }

    /// 演员列表（按类别分页）。
    func makerActors(category: MakerCategory, page: Int = 1) async throws -> MakerActorPage {
        let data = try await send(
            path: "api/makers/actors",
            method: "GET",
            query: ["category": category.rawValue, "page": String(page), "limit": "24"],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerActorPage.self, from: data)
    }

    /// 分类标签：按组返回标签，用于「分类」页。
    func makerTags(category: MakerCategory) async throws -> MakerTagsPage {
        let data = try await send(
            path: "api/makers/tags",
            method: "GET",
            query: ["category": category.rawValue],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerTagsPage.self, from: data)
    }

    /// 按标签 / 演员筛选影片。
    func makerBrowse(
        category: MakerCategory,
        group: String = "",
        tagId: String = "",
        actorID: String = "",
        page: Int = 1
    ) async throws -> MakerMoviePage {
        var query = ["category": category.rawValue, "page": String(page), "limit": "24"]
        if !group.isEmpty { query["group"] = group }
        if !tagId.isEmpty { query["tag_id"] = tagId }
        if !actorID.isEmpty { query["actor_id"] = actorID }
        let data = try await send(
            path: "api/makers/browse",
            method: "GET",
            query: query,
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerMoviePage.self, from: data)
    }

    /// 最近浏览（服务端记录）。
    func makerRecentViewed() async throws -> [MakerMovie] {
        let data = try await send(
            path: "api/makers/recent-viewed",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerRecentViewed.self, from: data).items
    }

    /// 影片详情：简介、演员、标签、磁力、评论资源、相关影片。
    func makerMovie(id: String) async throws -> MakerMovieDetail {
        let data = try await send(
            path: "api/makers/movie/\(id)",
            method: "GET",
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 30
        )
        return try decode(MakerMovieDetail.self, from: data)
    }

    /// 在线播放源聚合：AVDB 播放源 + 片商插件 + Stremio 插件。
    func makerPlaySources(movieID: String, number: String, title: String) async throws -> MakerPlaySources {
        let data = try await send(
            path: "api/makers/movie/\(movieID)/play-sources",
            method: "GET",
            query: ["number": number, "title": title],
            body: nil,
            authorized: true,
            retryable: false,
            requestTimeout: 45
        )
        return try decode(MakerPlaySources.self, from: data)
    }

    /// 影片搜索（番号/标题），`filter`：all / subtitle / magnets / playable。
    func makerMovieSearch(
        keyword: String,
        page: Int = 1,
        filter: String = "all"
    ) async throws -> MakerMoviePage {
        let data = try await send(
            path: "api/makers/movie-search",
            method: "GET",
            query: ["q": keyword, "page": String(page), "limit": "24", "filter_by": filter],
            body: nil,
            authorized: true,
            retryable: true,
            requestTimeout: 25
        )
        return try decode(MakerMoviePage.self, from: data)
    }

    /// AVDB 图片统一走服务端代理（封面 CDN 是加扰字节流）。
    func makerImageURL(raw: String, width: Int = 400) -> URL? {
        guard !raw.isEmpty else { return nil }
        return url(for: "api/makers/image", query: ["url": raw, "w": String(width)])
    }

    /// 离线转存：磁力 / ED2K 直存 115 目标目录（后端按来源选目录）。
    func panOffline(urls: [String], password: String = "") async throws -> PanOfflineResult {
        let body = try JSONEncoder().encode(
            PanOfflineBody(urls: urls, password: password.isEmpty ? nil : password)
        )
        let data = try await send(
            path: "api/pan/offline",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
        return try decodeEnvelope(PanOfflineResult.self, from: data)
    }

    /// 接收 115 分享：转存到网盘目标目录，`source` 决定落点（search / media / maker）。
    func panShare(urls: [String], password: String = "", source: String? = nil) async throws -> PanOfflineResult {
        let body = try JSONEncoder().encode(
            PanShareBody(
                urls: urls,
                password: password.isEmpty ? nil : password,
                source: (source?.isEmpty == false) ? source : nil
            )
        )
        let data = try await send(
            path: "api/pan/share",
            method: "POST",
            body: body,
            authorized: true,
            retryable: false,
            requestTimeout: 60
        )
        return try decodeEnvelope(PanOfflineResult.self, from: data)
    }

    /// 资源转存：115 分享走接收分享，磁力 / ED2K 走离线下载（与 PWA 分流一致）。
    func panTransfer(urls: [String], password: String = "", source: String? = nil) async throws -> PanOfflineResult {
        var seen = Set<String>()
        let links = urls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        let shares = links.filter(Self.is115ShareLink)
        let offline = links.filter(Self.isOfflineLink)

        guard !shares.isEmpty || !offline.isEmpty else {
            throw APIError.badRequest("仅支持磁力 / ED2K / 115 分享链接")
        }

        var added = 0
        var failures: [PanOfflineFailure] = []
        var destName = ""
        var offlineError: Error?

        if !shares.isEmpty {
            let result = try await panShare(urls: shares, password: password, source: source)
            added += result.added
            failures += result.failed
            if destName.isEmpty { destName = result.destName }
        }

        if !offline.isEmpty {
            do {
                let result = try await panOffline(urls: offline, password: password)
                added += result.added
                failures += result.failed
                if destName.isEmpty { destName = result.destName }
            } catch {
                offlineError = error
            }
        }

        if added == 0, let offlineError {
            throw offlineError
        }

        if let offlineError {
            failures.append(
                PanOfflineFailure(
                    message: "115 分享已转存 \(added) 个；离线任务失败：\(offlineError.localizedDescription)"
                )
            )
        }

        return PanOfflineResult(ok: added > 0, added: added, failed: failures, destName: destName)
    }

    /// 115 分享链接（115 / 115cdn / anxia 域名）。
    static func is115ShareLink(_ raw: String) -> Bool {
        let value = raw.lowercased()
        return ["115.com/s/", "115cdn.com/s/", "anxia.com/s/"].contains { value.contains($0) }
    }

    /// 磁力 / ED2K 链接。
    static func isOfflineLink(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("magnet:?") || value.hasPrefix("ed2k://")
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

    /// `/api` 业务端点统一返回 `{data, message, status}`，这里拆信封后只解业务体。
    private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(SettingsEnvelope<T>.self, from: data).data
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
        struct Envelope: Decodable {
            let detail: String?
            let message: String?
        }
        let value = try? JSONDecoder().decode(Envelope.self, from: data)
        return value?.detail ?? value?.message
    }
}

// MARK: - DTO

private struct LoginBody: Encodable {
    let username: String
    let password: String
}

private struct ChangePasswordBody: Encodable {
    let currentPassword: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case currentPassword = "current_password"
        case newPassword = "new_password"
    }
}

/// 通用响应信封：`{data, message, status}`。
private struct SettingsEnvelope<Value: Decodable>: Decodable {
    let data: Value
}

/// 登录响应：服务端把用户字段与 token 一起放在 Envelope 的 data 里。
private struct LoginPayload: Decodable {
    let token: String
    let user: AuthUser

    private enum CodingKeys: String, CodingKey {
        case token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        user = try AuthUser(from: decoder)
    }
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

// MARK: - 网盘 DTO

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

/// 离线转存结果：`added` 为成功条数，`destName` 为实际落盘目录。
struct PanOfflineResult: Decodable, Sendable {
    let ok: Bool
    let added: Int
    let failed: [PanOfflineFailure]
    let destName: String

    private enum CodingKeys: String, CodingKey {
        case ok, added, failed, destName
    }

    private struct Failure: Decodable {
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case message
        }
    }

    init(ok: Bool, added: Int, failed: [PanOfflineFailure], destName: String) {
        self.ok = ok
        self.added = added
        self.failed = failed
        self.destName = destName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.rexBool(.ok) ?? false
        added = container.rexInt(.added) ?? 0
        destName = container.rexString(.destName) ?? ""
        let rows = container.rexArray(.failed, as: Failure.self)
        failed = rows.map { PanOfflineFailure(message: $0.message ?? "转存失败") }
    }
}

struct PanOfflineFailure: Sendable {
    let message: String
}

private struct PanOfflineBody: Encodable {
    let urls: [String]
    let password: String?
}

private struct PanShareBody: Encodable {
    let urls: [String]
    let password: String?
    let source: String?
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
