import Foundation
import Observation

/// 全局唯一阶段真相：启动、登录、会话恢复、退出都只改这里。
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case launching
        case unauthenticated
        case authenticated(AuthSession)
    }

    private(set) var phase: Phase = .launching
    private(set) var isOffline = false
    /// 启动时连不上服务端的原因，交给登录页提示一次。
    private(set) var loginNotice: String?
    /// 当前会话的客户端，由组合根注入给各页面，页面不再自行构造。
    private(set) var client: APIClient?

    @ObservationIgnored private let sessions: SessionStoring
    @ObservationIgnored private let makeClient: (URL, String?) -> APIClient

    init(
        sessions: SessionStoring = SessionStore(),
        makeClient: @escaping (URL, String?) -> APIClient = { APIClient(baseURL: $0, token: $1) }
    ) {
        self.sessions = sessions
        self.makeClient = makeClient
    }

    // MARK: - 启动

    /// 闪屏由真实准备驱动：最短 300ms，会话校验最多等 1.5s。
    func bootstrap() async {
        let startedAt = Date()
        await restoreSession()
        await holdSplash(minimum: 0.3, since: startedAt)
    }

    private func restoreSession() async {
        loginNotice = nil

        guard let baseURL = ServerConfig.baseURL,
              let token = sessions.token,
              let cachedUser = sessions.user else {
            sessions.clear()
            phase = .unauthenticated
            return
        }

        if let expiresAt = sessions.expiresAt, expiresAt <= Date() {
            sessions.clear()
            phase = .unauthenticated
            return
        }

        do {
            let client = makeClient(baseURL, token)
            let user = try await validate(using: client)
            let session = AuthSession(
                token: token,
                user: user,
                expiresAt: sessions.expiresAt ?? .distantFuture
            )
            sessions.save(session)
            self.client = client
            isOffline = false
            phase = .authenticated(session)
        } catch APIError.unauthorized, APIError.forbidden {
            sessions.clear()
            client = nil
            isOffline = false
            phase = .unauthenticated
        } catch {
            // 连不上服务端（离线 / 地址错误 / 超时）：保留 token 与用户快照进首页离线态，
            // 回到前台时再重试校验，不把用户退回登录页。
            let session = AuthSession(
                token: token,
                user: cachedUser,
                expiresAt: sessions.expiresAt ?? .distantFuture
            )
            client = makeClient(baseURL, token)
            isOffline = true
            phase = .authenticated(session)
        }
    }

    /// 首页处于离线态时，回到前台再校验一次；成功即摘掉离线条。
    func retryConnectionIfOffline() async {
        guard isOffline,
              case .authenticated(let session) = phase,
              let baseURL = ServerConfig.baseURL else { return }

        let client = makeClient(baseURL, session.token)
        do {
            let user = try await validate(using: client)
            let refreshed = AuthSession(
                token: session.token,
                user: user,
                expiresAt: sessions.expiresAt ?? .distantFuture
            )
            sessions.save(refreshed)
            self.client = client
            isOffline = false
            phase = .authenticated(refreshed)
        } catch APIError.unauthorized, APIError.forbidden {
            sessions.clear()
            self.client = nil
            isOffline = false
            phase = .unauthenticated
        } catch {
            // 仍然连不上，保持离线态，等下一次回到前台。
        }
    }

    private func validate(using client: APIClient) async throws -> AuthUser {
        try await withThrowingTaskGroup(of: AuthUser.self) { group in
            group.addTask { try await client.currentUser() }
            group.addTask {
                try await Task.sleep(for: .seconds(1.5))
                throw APIError.timeout
            }
            defer { group.cancelAll() }
            guard let user = try await group.next() else { throw APIError.timeout }
            return user
        }
    }

    private func holdSplash(minimum: TimeInterval, since start: Date) async {
        let remaining = minimum - Date().timeIntervalSince(start)
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }

    // MARK: - 登录 / 退出

    func signIn(
        serverText: String,
        useHTTPS: Bool,
        username: String,
        password: String
    ) async throws {
        guard let baseURL = ServerConfig.resolve(serverText, useHTTPS: useHTTPS) else {
            throw APIError.unreachable
        }

        let previousHost = ServerConfig.baseURL?.host
        ServerConfig.savedText = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        ServerConfig.httpsEnabled = useHTTPS

        // 换服务端即视为换身份，旧凭证直接作废。
        if let previousHost, previousHost != baseURL.host {
            sessions.clear()
        }

        let client = makeClient(baseURL, nil)
        let session = try await client.login(username: username, password: password)
        sessions.save(session)
        self.client = client.withToken(session.token)
        isOffline = false
        loginNotice = nil
        phase = .authenticated(session)
    }

    func signOut() {
        APIClient.cancelAllInflight()
        sessions.clear()
        client = nil
        isOffline = false
        loginNotice = nil
        phase = .unauthenticated
    }
}
