import SwiftUI
import WebKit

// MARK: - 115 账号与转存

struct P115SettingsView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var alert: RexAlertInfo?

    @State private var cookie = ""
    @State private var folderCid = "0"
    @State private var folderName = ""
    @State private var label = ""
    @State private var hasCookie = false
    @State private var cookieHint = ""
    @State private var configured = false
    @State private var status: P115Status?
    @State private var showsQR = false
    @State private var showsFolderPicker = false

    var body: some View {
        SettingsPage(title: "115 网盘") {
            if isLoading {
                RexSkeleton(width: .infinity, height: 120, cornerRadius: RexRadius.panel)
            } else {
                statusCard

                SettingsCard {
                    SettingsInputRow(
                        icon: "key",
                        title: "Cookie",
                        placeholder: hasCookie ? "留空保持现有登录" : "粘贴 115 Cookie",
                        text: $cookie,
                        isSecure: true
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "folder",
                        title: "转存目录 ID",
                        placeholder: "0 表示根目录",
                        text: $folderCid,
                        keyboard: .numberPad
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "text.badge.checkmark",
                        title: "目录名称",
                        placeholder: "可选，便于识别",
                        text: $folderName
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "tag",
                        title: "展示名",
                        placeholder: "可选",
                        text: $label
                    )
                    .disabled(!isAdmin)
                }

                if isAdmin {
                    VStack(spacing: RexSpacing.sm) {
                        Button {
                            showsQR = true
                        } label: {
                            Label("扫码登录 115", systemImage: "qrcode")
                                .font(.system(.subheadline, weight: .medium))
                                .foregroundStyle(RexColor.brandBlue)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(
                                    RexColor.brandBlue.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                )
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button {
                            showsFolderPicker = true
                        } label: {
                            Label("从 115 选择转存目录", systemImage: "folder")
                                .font(.system(.subheadline, weight: .medium))
                                .foregroundStyle(RexColor.primaryText)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(
                                    RexColor.surface,
                                    in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                                }
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }

                if isAdmin {
                    HStack(spacing: RexSpacing.md) {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack(spacing: RexSpacing.sm) {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "bolt.horizontal")
                                }
                                Text("测试登录")
                            }
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(RexColor.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RexColor.surface,
                                in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isTesting || isSaving)

                        Button {
                            Task { await save() }
                        } label: {
                            HStack(spacing: RexSpacing.sm) {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(RexColor.onBrand)
                                }
                                Text("保存")
                            }
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(RexColor.onBrand)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RexColor.brandGradient,
                                in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isSaving || isTesting)
                    }
                } else {
                    RexNote(text: "当前账号不是管理员，只能查看配置。")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showsQR) {
            P115QRLoginView { settings in
                hasCookie = settings.hasCookie == true
                configured = settings.configured == true
                cookie = ""
                alert = .success("扫码登录成功，已保存 Cookie")
                Task {
                    status = try? await apiClient?.fetchSettings("api/settings/p115/status", as: P115Status.self)
                }
            }
            .rexSheetStyle()
        }
        .rexBottomDrawer(isPresented: $showsFolderPicker) {
            PanFolderPickerView(mode: .select) { cid in
                folderCid = cid
                Task { await save() }
            }
        }
        .rexAlert($alert)
    }

    private var statusCard: some View {
        SettingsCard {
            SettingsRow(
                icon: configured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                title: "登录状态",
                value: configured ? "已配置" : "未配置",
                iconTint: configured ? RexColor.success : RexColor.warning
            )

            if !cookieHint.isEmpty {
                SettingsDivider()
                SettingsRow(icon: "person.text.rectangle", title: "账号标识", value: cookieHint)
            }

            if let status {
                if let authOk = status.authOk {
                    SettingsDivider()
                    SettingsRow(
                        icon: authOk ? "checkmark.circle.fill" : "xmark.circle.fill",
                        title: "Cookie 校验",
                        value: authOk ? "有效" : (status.authError ?? "已失效"),
                        iconTint: authOk ? RexColor.success : RexColor.error
                    )
                }

                if let quota = status.quota, let total = status.quotaTotal {
                    SettingsDivider()
                    SettingsRow(icon: "arrow.down.circle", title: "离线额度", value: "\(quota) / \(total)")
                }

                if let total = status.spaceTotalText, let used = status.spaceUsedText {
                    SettingsDivider()
                    SettingsRow(icon: "internaldrive", title: "空间", value: "\(used) / \(total)")
                }

                if let remain = status.spaceRemainText {
                    SettingsDivider()
                    SettingsRow(icon: "internaldrive.fill", title: "剩余空间", value: remain)
                }
            }
        }
    }

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录", title: "加载失败")
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await apiClient.fetchSettings("api/settings/p115", as: P115Settings.self)
            hasCookie = settings.hasCookie == true
            configured = settings.configured == true
            cookieHint = settings.cookieHint ?? ""
            folderCid = settings.folderCid ?? "0"
            folderName = settings.folderName ?? ""
            label = settings.label ?? ""

            status = try? await apiClient.fetchSettings("api/settings/p115/status", as: P115Status.self)
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }

    private func save() async {
        guard let apiClient, !isSaving else { return }
        isSaving = true
        alert = nil
        defer { isSaving = false }

        do {
            let body = P115SaveBody(
                cookie: cookie,
                folderCid: folderCid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0" : folderCid,
                folderName: folderName,
                label: label,
                validate: true
            )
            let _: P115Settings = try await apiClient.putSettings(
                "api/settings/p115",
                json: try JSONEncoder().encode(body),
                as: P115Settings.self
            )
            cookie = ""
            hasCookie = true
            RexHaptics.success()
            alert = .success("115 配置已保存")
            status = try? await apiClient.fetchSettings("api/settings/p115/status", as: P115Status.self)
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func test() async {
        guard let apiClient, !isTesting else { return }
        isTesting = true
        alert = nil
        defer { isTesting = false }

        do {
            let body = P115SaveBody(
                cookie: cookie,
                folderCid: folderCid.isEmpty ? "0" : folderCid,
                folderName: folderName,
                label: label,
                validate: true
            )
            let result = try await apiClient.postSettings(
                "api/settings/p115/validate",
                json: try JSONEncoder().encode(body),
                as: ServiceTestResult.self
            )
            RexHaptics.success()
            alert = .success(result.message ?? "登录有效")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }
}

// MARK: - 115 扫码登录

private struct P115QRLoginView: View {
    var onSaved: (P115Settings) -> Void

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var start: P115QRStart?
    @State private var statusText = "正在获取二维码…"
    @State private var isExpired = false
    @State private var errorText: String?
    @State private var alert: RexAlertInfo?
    @State private var polling: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    ZStack {
                        RoundedRectangle(cornerRadius: RexRadius.largeCard, style: .continuous)
                            .fill(Color.white)

                        if let start, let qr = start.qrImage {
                            SVGDataView(dataURL: qr)
                                .frame(width: 220, height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous))
                        } else if errorText == nil {
                            ProgressView()
                        }
                    }
                    .frame(width: 248, height: 248)
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)

                    Text(statusText)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(RexColor.primaryText)
                        .multilineTextAlignment(.center)

                    if isExpired {
                        Button {
                            Task { await begin() }
                        } label: {
                            Text("刷新二维码")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(RexColor.onBrand)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    RexColor.brandGradient,
                                    in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(RexSpacing.xl)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(RexPageBackground())
            .navigationTitle("扫码登录 115")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { await begin() }
        .onDisappear { polling?.cancel() }
        .rexAlert($alert)
    }

    private func begin() async {
        guard let apiClient else { return }
        polling?.cancel()
        start = nil
        errorText = nil
        alert = nil
        isExpired = false
        statusText = "正在获取二维码…"

        do {
            let value = try await apiClient.p115QRStart()
            start = value
            statusText = "等待扫码…"
            beginPolling(value)
        } catch {
            errorText = error.localizedDescription
            alert = .failure(error.localizedDescription, title: "扫码登录失败")
            statusText = "获取二维码失败"
        }
    }

    private func beginPolling(_ value: P115QRStart) {
        polling = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard let apiClient else { return }

                do {
                    let status = try await apiClient.p115QRStatus(
                        uid: value.uid,
                        time: value.time,
                        sign: value.sign
                    )
                    if !status.statusLabel.isEmpty {
                        statusText = status.statusLabel
                    }

                    if status.expired {
                        isExpired = true
                        statusText = "二维码已过期"
                        return
                    }

                    if status.done {
                        statusText = "登录成功，正在保存…"
                        let settings = try await apiClient.p115QRComplete(
                            uid: value.uid,
                            app: value.app ?? "alipaymini"
                        )
                        RexHaptics.success()
                        onSaved(settings)
                        dismiss()
                        return
                    }
                } catch {
                    // 单次轮询失败不终止，继续等下一次。
                    continue
                }
            }
        }
    }
}

/// 把服务端生成的 SVG data URL 渲染成图片（服务端用 segno 画二维码）。
private struct SVGDataView: UIViewRepresentable {
    let dataURL: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let html = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0;padding:0;display:flex;align-items:center;justify-content:center;background:transparent;">
        <img src="\(dataURL)" style="width:100%;height:100%;object-fit:contain;">
        </body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - 网络代理

struct NetworkSettingsView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isTestingProxy = false
    @State private var isTestingFlare = false
    @State private var alert: RexAlertInfo?

    @State private var proxyUrl = ""
    @State private var proxyEnabled = false
    @State private var flareUrl = ""
    @State private var flareEnabled = false

    var body: some View {
        SettingsPage(title: "网络代理") {
            if isLoading {
                RexSkeleton(width: .infinity, height: 120, cornerRadius: RexRadius.panel)
            } else {
                RexNote(text: "代理用于服务端访问外部站点；修改后会自动重启走代理的插件。")

                SettingsCard {
                    SettingsSwitchRow(title: "启用 HTTP 代理", isOn: $proxyEnabled)
                        .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "network",
                        title: "代理地址",
                        placeholder: "http://127.0.0.1:7897",
                        text: $proxyUrl,
                        keyboard: .URL
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsSwitchRow(title: "启用 FlareSolverr", isOn: $flareEnabled)
                        .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "shield.lefthalf.filled",
                        title: "FlareSolverr",
                        placeholder: "http://127.0.0.1:8191",
                        text: $flareUrl,
                        keyboard: .URL
                    )
                    .disabled(!isAdmin)
                }

                if isAdmin {
                    VStack(spacing: RexSpacing.md) {
                        HStack(spacing: RexSpacing.md) {
                            probeButton(title: "测试代理", isLoading: isTestingProxy) {
                                await testProxy()
                            }
                            .disabled(isTestingProxy || isSaving || proxyUrl.isEmpty)

                            probeButton(title: "测试 Flare", isLoading: isTestingFlare) {
                                await testFlare()
                            }
                            .disabled(isTestingFlare || isSaving || flareUrl.isEmpty)
                        }

                        Button {
                            Task { await save() }
                        } label: {
                            HStack(spacing: RexSpacing.sm) {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(RexColor.onBrand)
                                }
                                Text("保存网络配置")
                            }
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(RexColor.onBrand)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RexColor.brandGradient,
                                in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isSaving || isTestingProxy || isTestingFlare)
                    }
                } else {
                    RexNote(text: "当前账号不是管理员，只能查看配置。")
                }
            }
        }
        .task { await load() }
        .rexAlert($alert)
    }

    private func probeButton(title: String, isLoading: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: RexSpacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "bolt.horizontal")
                }
                Text(title)
            }
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(RexColor.primaryText)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录", title: "加载失败")
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await apiClient.fetchSettings("api/settings/network", as: NetworkSettings.self)
            proxyUrl = settings.proxyUrl ?? ""
            proxyEnabled = settings.proxyEnabled ?? false
            flareUrl = settings.flareSolverrUrl ?? ""
            flareEnabled = settings.flareSolverrEnabled ?? false
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }

    private func save() async {
        guard let apiClient, !isSaving else { return }
        isSaving = true
        alert = nil
        defer { isSaving = false }

        do {
            let body = NetworkSaveBody(
                proxyUrl: proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                proxyEnabled: proxyEnabled,
                flareSolverrUrl: flareUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                flareSolverrEnabled: flareEnabled
            )
            _ = try await apiClient.putSettings(
                "api/settings/network",
                json: try JSONEncoder().encode(body),
                as: NetworkSettings.self
            )
            RexHaptics.success()
            alert = .success("网络配置已保存")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func testProxy() async {
        guard let apiClient, !isTestingProxy else { return }
        isTestingProxy = true
        alert = nil
        defer { isTestingProxy = false }

        do {
            let body = NetworkSaveBody(proxyUrl: proxyUrl, proxyEnabled: proxyEnabled)
            let result = try await apiClient.postSettings(
                "api/settings/network/test",
                json: try JSONEncoder().encode(body),
                as: ServiceTestResult.self
            )
            RexHaptics.success()
            alert = .success(result.message ?? "代理正常")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func testFlare() async {
        guard let apiClient, !isTestingFlare else { return }
        isTestingFlare = true
        alert = nil
        defer { isTestingFlare = false }

        do {
            let body = NetworkSaveBody(flareSolverrUrl: flareUrl, flareSolverrEnabled: flareEnabled)
            let result = try await apiClient.postSettings(
                "api/settings/network/flare-test",
                json: try JSONEncoder().encode(body),
                as: ServiceTestResult.self
            )
            RexHaptics.success()
            alert = .success(result.message ?? "FlareSolverr 正常")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }
}

// MARK: - TMDB

struct TmdbSettingsView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var alert: RexAlertInfo?
    @State private var apiKey = ""
    @State private var hint = ""
    @State private var configured = false

    var body: some View {
        SettingsPage(title: "TMDB") {
            if isLoading {
                RexSkeleton(width: .infinity, height: 90, cornerRadius: RexRadius.panel)
            } else {
                SettingsCard {
                    SettingsRow(
                        icon: configured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        title: "配置状态",
                        value: configured ? "已配置" : "未配置",
                        iconTint: configured ? RexColor.success : RexColor.warning
                    )

                    if !hint.isEmpty {
                        SettingsDivider()
                        SettingsRow(icon: "key", title: "当前 Key", value: hint)
                    }

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "key.fill",
                        title: "API Key",
                        placeholder: configured ? "留空保持现有 Key" : "请输入 TMDB API Key",
                        text: $apiKey,
                        isSecure: true
                    )
                    .disabled(!isAdmin)
                }

                if isAdmin {
                    HStack(spacing: RexSpacing.md) {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack(spacing: RexSpacing.sm) {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "bolt.horizontal")
                                }
                                Text("测试 Key")
                            }
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(RexColor.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RexColor.surface,
                                in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isTesting || isSaving)

                        Button {
                            Task { await save() }
                        } label: {
                            HStack(spacing: RexSpacing.sm) {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(RexColor.onBrand)
                                }
                                Text("保存")
                            }
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(RexColor.onBrand)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RexColor.brandGradient,
                                in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isSaving || isTesting)
                    }
                } else {
                    RexNote(text: "当前账号不是管理员，只能查看配置。")
                }
            }
        }
        .task { await load() }
        .rexAlert($alert)
    }

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录", title: "加载失败")
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await apiClient.fetchSettings("api/settings/tmdb", as: TmdbSettings.self)
            configured = settings.configured == true
            hint = settings.apiKeyHint ?? ""
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }

    private func save() async {
        guard let apiClient, !isSaving else { return }
        isSaving = true
        alert = nil
        defer { isSaving = false }

        do {
            _ = try await apiClient.putSettings(
                "api/settings/tmdb",
                json: try JSONEncoder().encode(TmdbSaveBody(apiKey: apiKey)),
                as: TmdbSettings.self
            )
            apiKey = ""
            configured = true
            RexHaptics.success()
            alert = .success("TMDB 配置已保存")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func test() async {
        guard let apiClient, !isTesting else { return }
        isTesting = true
        alert = nil
        defer { isTesting = false }

        do {
            let result = try await apiClient.postSettings(
                "api/settings/tmdb/test",
                json: try JSONEncoder().encode(TmdbSaveBody(apiKey: apiKey)),
                as: ServiceTestResult.self
            )
            RexHaptics.success()
            alert = .success(result.message ?? "TMDB 连接成功")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }
}
