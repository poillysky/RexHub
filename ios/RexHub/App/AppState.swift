import Foundation
import Network
import Observation

/// 全局唯一阶段真相：启动、登录、会话恢复、退出都只改这里。
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        /// 第 1 页：品牌静态图，只做视觉过渡。
        case launching
        /// 第 2 页：拿本地会话真实连一次服务器，连上之前一直停在这里。
        case connecting(AuthSession)
        /// 第 3 页：登录表单。
        case unauthenticated
        /// 第 4 页：正式主页。
        case authenticated(AuthSession)
    }

    private(set) var phase: Phase = .launching
    /// 连接页的失败态：只切换成「连接失败 + 重试」，仍然留在连接页。
    private(set) var connectionFailed = false
    private(set) var isOffline = false
    /// 当前会话的客户端，由组合根注入给各页面，页面不再自行构造。
    private(set) var client: APIClient?
    /// 运行中凭证失效时的提示文案，非空时由根视图弹一次提示。
    private(set) var sessionExpiredMessage: String?

    @ObservationIgnored private let sessions: SessionStoring
    @ObservationIgnored private let makeClient: (URL, String?) -> APIClient
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "rexhub.network.path")
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    init(
        sessions: SessionStoring = SessionStore(),
        makeClient: @escaping (URL, String?) -> APIClient = { APIClient(baseURL: $0, token: $1) }
    ) {
        self.sessions = sessions
        self.makeClient = makeClient

        // 请求层发现 token 失效时，直接把我们推回登录页。
        SessionEventSink.shared.setCredentialsExpiredHandler { [weak self] in
            Task { @MainActor in self?.handleCredentialsExpired() }
        }
    }

    // MARK: - 启动

    /// 启动顺序：品牌静态图 → 有本地会话就进连接页真实校验，没有直接进登录页。
    /// 校验通过才进主页；凭证明确失效退回登录页；连不上就停在连接页等重试。
    func bootstrap() async {
        guard phase == .launching else { return }

        startNetworkMonitor()
        let startedAt = Date()
        connectionFailed = false

        // 品牌静态图至少停留一拍，避免网络极快时一闪而过。
        await pause(until: 0.7, since: startedAt)

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

        let session = AuthSession(
            token: token,
            user: cachedUser,
            expiresAt: sessions.expiresAt ?? .distantFuture
        )
        phase = .connecting(session)
        await connect(session: session, baseURL: baseURL)
    }

    /// 连接页上的真实校验，也是「重试」的唯一入口。
    private func connect(session: AuthSession, baseURL: URL) async {
        let startedAt = Date()
        let client = makeClient(baseURL, session.token)

        connectionFailed = false
        do {
            let user = try await validate(using: client)
            // 连接页也至少停留一拍，成功响应太快时不至于闪一下。
            await pause(until: 0.5, since: startedAt)
            guard case .connecting(let current) = phase,
                  current.token == session.token else { return }

            let refreshed = AuthSession(
                token: session.token,
                user: user,
                expiresAt: session.expiresAt
            )
            sessions.save(refreshed)
            self.client = client
            isOffline = false
            phase = .authenticated(refreshed)
            RexLog.session.notice("会话校验通过")
        } catch APIError.unauthorized, APIError.forbidden {
            guard case .connecting(let current) = phase,
                  current.token == session.token else { return }
            sessions.clear()
            self.client = nil
            isOffline = false
            sessionExpiredMessage = "请重新登录"
            phase = .unauthenticated
            RexLog.session.notice("登录信息已失效，退回登录页")
        } catch {
            // 断网、地址不通、超时：留在连接页，用户可以重试或退出登录。
            guard case .connecting(let current) = phase,
                  current.token == session.token else { return }
            connectionFailed = true
            RexLog.session.notice("连接失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 连接页点「重试」。
    func retryConnection() async {
        guard case .connecting(let session) = phase,
              let baseURL = ServerConfig.baseURL else { return }
        await connect(session: session, baseURL: baseURL)
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
            handleCredentialsExpired()
        } catch {
            // 仍然连不上，保持离线态，等下一次回到前台或网络恢复。
        }
    }

    /// 根视图消费完「登录已过期」提示后复位。
    func acknowledgeSessionExpired() {
        sessionExpiredMessage = nil
    }

    // MARK: - 网络状态

    /// 监听系统网络状态：断开即置离线（首页徽标 + 全局提示条），恢复后自动重新校验。
    private func startNetworkMonitor() {
        guard monitorTask == nil else { return }

        let monitor = pathMonitor
        let stream = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            monitor.start(queue: pathMonitorQueue)
        }

        monitorTask = Task { [weak self] in
            for await isSatisfied in stream {
                guard let self else { return }
                self.networkStatusChanged(isSatisfied: isSatisfied)
            }
        }
    }

    private func networkStatusChanged(isSatisfied: Bool) {
        // 只有已登录（使用中）才需要提示离线；启动/登录页的网络问题各有自己的错误态。
        guard case .authenticated = phase else {
            isOffline = false
            return
        }

        if isSatisfied {
            guard isOffline else { return }
            Task { await retryConnectionIfOffline() }
        } else {
            guard !isOffline else { return }
            isOffline = true
            RexLog.session.notice("网络已断开")
        }
    }

    /// 运行中 token 失效：清会话回登录页，并留一句提示给根视图弹出。
    private func handleCredentialsExpired() {
        guard case .authenticated = phase else { return }
        RexLog.session.notice("凭证已失效，自动退回登录页")
        client?.cancelAllInflight()
        sessions.clear()
        client = nil
        isOffline = false
        connectionFailed = false
        sessionExpiredMessage = "请重新登录"
        phase = .unauthenticated
    }

    /// 校验跑在后台，不阻塞首屏，所以用接近常规请求的超时兜底。
    private func validate(using client: APIClient) async throws -> AuthUser {
        try await withThrowingTaskGroup(of: AuthUser.self) { group in
            group.addTask { try await client.currentUser() }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw APIError.timeout
            }
            defer { group.cancelAll() }
            guard let user = try await group.next() else { throw APIError.timeout }
            return user
        }
    }

    private func pause(until minimum: TimeInterval, since start: Date) async {
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

        let previousText = ServerConfig.savedText
        let previousHTTPS = ServerConfig.httpsEnabled
        let previousHost = ServerConfig.baseURL?.host
        ServerConfig.savedText = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        ServerConfig.httpsEnabled = useHTTPS

        // 换服务端即视为换身份，旧凭证直接作废。
        if let previousHost, previousHost != baseURL.host {
            sessions.clear()
        }

        let client = makeClient(baseURL, nil)
        do {
            let session = try await client.login(username: username, password: password)
            sessions.save(session)
            self.client = client.withToken(session.token)
            isOffline = false
            connectionFailed = false
            sessionExpiredMessage = nil
            phase = .authenticated(session)
            RexLog.session.notice("登录成功 host=\(baseURL.host ?? "", privacy: .public)")
        } catch {
            // 登录失败不落库：避免把连不上的地址带进下次启动。
            ServerConfig.savedText = previousText
            ServerConfig.httpsEnabled = previousHTTPS
            throw error
        }
    }

    func signOut() {
        RexLog.session.notice("用户主动退出登录")
        client?.cancelAllInflight()
        sessions.clear()
        client = nil
        isOffline = false
        connectionFailed = false
        sessionExpiredMessage = nil
        phase = .unauthenticated
    }
}
