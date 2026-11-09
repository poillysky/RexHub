import SwiftUI
import UIKit

// MARK: - 通用输入行

/// 设置页里的文本 / 密码输入行：图标 + 标题，输入框右对齐，整行最小高度与其它设置行一致。
struct SettingsInputRow: View {
    let icon: String
    let title: String
    var placeholder: String = ""
    @Binding var text: String
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil

    var body: some View {
        HStack(spacing: RexSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RexColor.brandBlue)
                .frame(width: 28)

            Text(title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(RexFont.rowValue)
            .foregroundStyle(RexColor.primaryText)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .textContentType(contentType)
            .frame(maxWidth: 190)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
    }
}

// MARK: - 服务种类

enum ServiceKind: String, Identifiable, CaseIterable {
    case bitmagnet
    case cloudSaver
    case sehuatang
    case avdb
    case moviePilot
    case morePlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bitmagnet: "Bitmagnet"
        case .cloudSaver: "CloudSaver"
        case .sehuatang: "色花堂"
        case .avdb: "AVDB"
        case .moviePilot: "MoviePilot"
        case .morePlay: "MorePlay"
        }
    }

    /// 列表行副标题，与 PWA 设置首页保持一致。
    var subtitle: String {
        switch self {
        case .bitmagnet: "磁力索引资源库"
        case .cloudSaver: "账号登录与资源搜索"
        case .sehuatang: "链接信息 · 论坛板块"
        case .avdb: "API 令牌 · 资源接口"
        case .moviePilot: "API 令牌 · 媒体订阅"
        case .morePlay: "猫源聚合 · 在线播放"
        }
    }

    var tags: [String] {
        switch self {
        case .bitmagnet: ["影视", "片商"]
        case .cloudSaver, .moviePilot, .morePlay: ["影视"]
        case .sehuatang, .avdb: ["片商"]
        }
    }

    var imageName: String {
        switch self {
        case .bitmagnet: "ServiceBitmagnet"
        case .cloudSaver: "ServiceCloudSaver"
        case .sehuatang: "ServiceSehuatang"
        case .avdb: "ServiceAvdb"
        case .moviePilot: "ServiceMoviePilot"
        case .morePlay: "ServiceMorePlay"
        }
    }

    var icon: String {
        switch self {
        case .bitmagnet: "harddrive"
        case .cloudSaver: "magnifyingglass.circle"
        case .sehuatang: "bubble.left.and.bubble.right"
        case .avdb: "database"
        case .moviePilot: "film"
        case .morePlay: "play.rectangle.on.rectangle"
        }
    }

    /// Bitmagnet / 色花资源库走 Postgres DSN 配置，其余走 HTTP 地址 + 凭据。
    var usesPostgres: Bool {
        self == .bitmagnet || self == .sehuatang
    }

    var settingsPath: String {
        switch self {
        case .bitmagnet: "api/settings/bitmagnet-db"
        case .cloudSaver: "api/settings/cloudsaver"
        case .sehuatang: "api/settings/resource-db"
        case .avdb: "api/settings/avdb"
        case .moviePilot: "api/settings/moviepilot"
        case .morePlay: "api/settings/moreplay"
        }
    }

    var testPath: String {
        switch self {
        case .bitmagnet: "api/settings/bitmagnet-db/test"
        case .cloudSaver: "api/cloudsaver/test"
        case .sehuatang: "api/settings/resource-db/test"
        case .avdb: "api/avdb/test"
        case .moviePilot: "api/moviepilot/test"
        case .morePlay: "api/moreplay/test"
        }
    }

    var defaultPort: String {
        self == .sehuatang ? "5435" : "5432"
    }

    var defaultDatabase: String {
        self == .sehuatang ? "ed2k" : "bitmagnet"
    }

    var summary: String {
        switch self {
        case .bitmagnet: "磁力索引库，影视与片商搜索都依赖它。"
        case .cloudSaver: "影视资源搜索与 115 转存。"
        case .sehuatang: "色花资源库，负责片商搜索与论坛板块信息。"
        case .avdb: "片商数据源，影视 Tab 的榜单与影片搜索都依赖它。"
        case .moviePilot: "影视推荐、订阅与下载。"
        case .morePlay: "猫源聚合在线播放。"
        }
    }

    var needsApiKey: Bool {
        self == .avdb || self == .moviePilot
    }

    var needsAccount: Bool {
        self == .cloudSaver
    }

    var usesSearchSites: Bool {
        self == .morePlay
    }
}

// MARK: - 服务配置页

struct ServiceSettingsView: View {
    let kind: ServiceKind
    /// 仅管理员可保存与探测，普通用户只读。
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var alert: RexAlertInfo?
    @State private var isScrolled = false

    @State private var enabled = true
    @State private var baseUrl = ""
    @State private var timeoutSec = 20.0
    @State private var note = ""
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""
    @State private var searchSitesText = ""
    @State private var hasStoredSecret = false
    @State private var tokenPageUrl: String?

    var body: some View {
        SettingsPage(title: kind.title) {
            if isLoading {
                RexSkeleton(width: .infinity, height: 120, cornerRadius: RexRadius.panel)
            } else {
                RexNote(text: kind.summary)

                SettingsCard {
                    SettingsSwitchRow(
                        title: "启用 \(kind.title)",
                        isOn: Binding(
                            get: { enabled },
                            set: { value in
                                enabled = value
                                guard isAdmin else { return }
                                Task { await save() }
                            }
                        )
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "link",
                        title: "服务地址",
                        placeholder: "http://192.168.1.10:端口",
                        text: $baseUrl,
                        keyboard: .URL,
                        contentType: .URL
                    )
                    .disabled(!isAdmin)

                    if kind.needsApiKey {
                        SettingsDivider()
                        SettingsInputRow(
                            icon: "key",
                            title: "API 令牌",
                            placeholder: hasStoredSecret ? "留空保持现有令牌" : "请输入令牌",
                            text: $apiKey,
                            isSecure: true
                        )
                        .disabled(!isAdmin)
                    }

                    if kind.needsAccount {
                        SettingsDivider()
                        SettingsInputRow(
                            icon: "person",
                            title: "账号",
                            placeholder: "用户名",
                            text: $username,
                            contentType: .username
                        )
                        .disabled(!isAdmin)

                        SettingsDivider()
                        SettingsInputRow(
                            icon: "lock",
                            title: "密码",
                            placeholder: hasStoredSecret ? "留空保持现有密码" : "请输入密码",
                            text: $password,
                            isSecure: true,
                            contentType: .password
                        )
                        .disabled(!isAdmin)
                    }

                    if kind.usesSearchSites {
                        SettingsDivider()
                        SettingsInputRow(
                            icon: "list.bullet",
                            title: "优先站点",
                            placeholder: "逗号分隔，如 nyaa, acgrip",
                            text: $searchSitesText
                        )
                        .disabled(!isAdmin)
                    }

                    SettingsDivider()

                    SettingsStepperRow(
                        title: "超时",
                        value: Binding(
                            get: { Int(timeoutSec) },
                            set: { timeoutSec = Double($0) }
                        ),
                        range: 5...120,
                        step: 5
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "text.alignleft",
                        title: "备注",
                        placeholder: "可选",
                        text: $note
                    )
                    .disabled(!isAdmin)
                }

                if let tokenPageUrl, let url = URL(string: tokenPageUrl) {
                    RexNote(text: "令牌获取页：\(tokenPageUrl)")
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
                                Text("测试连接")
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
                        .disabled(isTesting || isSaving || baseUrl.isEmpty)

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
                        .disabled(isSaving || isTesting || baseUrl.isEmpty)
                    }
                } else {
                    RexNote(text: "当前账号不是管理员，只能查看配置。")
                }
            }
        }
        .task { await load() }
        .rexAlert($alert)
    }

    // MARK: - 数据

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录")
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await apiClient.fetchSettings(kind.settingsPath, as: ServiceSettings.self)
            enabled = settings.enabled ?? true
            baseUrl = settings.baseUrl ?? ""
            timeoutSec = settings.timeoutSec ?? 20
            note = settings.note ?? ""
            username = settings.username ?? ""
            hasStoredSecret = settings.hasApiKey == true || settings.hasPassword == true
            tokenPageUrl = settings.tokenPageUrl
            searchSitesText = (settings.searchSites ?? []).joined(separator: ", ")
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription)
        }
    }

    private func save() async {
        guard let apiClient, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await apiClient.putSettings(
                kind.settingsPath,
                json: try JSONEncoder().encode(saveBody()),
                as: ServiceSettings.self
            )
            hasStoredSecret = hasStoredSecret || !apiKey.isEmpty || !password.isEmpty
            apiKey = ""
            password = ""
            RexHaptics.success()
            alert = .success("配置已保存")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func test() async {
        guard let apiClient, !isTesting else { return }
        isTesting = true
        defer { isTesting = false }

        do {
            let result = try await apiClient.postSettings(
                kind.testPath,
                json: try JSONEncoder().encode(saveBody()),
                as: ServiceTestResult.self
            )
            RexHaptics.success()
            let message = result.message
                ?? (result.ok == false ? "连接失败" : "连接成功")
            alert = result.ok == false ? .failure(message) : .success(message)
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func saveBody() -> ServiceSaveBody {
        var body = ServiceSaveBody(
            enabled: enabled,
            baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            timeoutSec: timeoutSec,
            note: note
        )
        if kind.needsApiKey, !apiKey.isEmpty { body.apiKey = apiKey }
        if kind.needsAccount {
            body.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !password.isEmpty { body.password = password }
        }
        if kind.usesSearchSites {
            let sites = searchSitesText
                .split(whereSeparator: { $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            body.searchSites = sites
            body.searchSite = sites.first
        }
        return body
    }
}

// MARK: - Postgres 连接配置页（Bitmagnet / 色花资源库）

/// 对应 PWA 的 Bitmagnet / 色花资源库面板：开关、主机、端口、库名、账号与密码。
/// 凭据字段只在管理员下可编辑，普通账号只读。
struct PostgresDbSettingsView: View {
    let kind: ServiceKind
    let isAdmin: Bool
    var showsForumManagement: Bool = false

    @Environment(\.apiClient) private var apiClient

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var alert: RexAlertInfo?
    @State private var parseError: String?

    @State private var enabled = false
    @State private var host = ""
    @State private var port = ""
    @State private var database = ""
    @State private var user = "postgres"
    @State private var password = ""
    @State private var passwordTouched = false
    @State private var savedPassword = ""
    @State private var hasPassword = false
    @State private var note = ""
    @State private var dsnQuery = ""

    /// nil = 尚未探测或正在探测。
    @State private var connected: Bool?
    @State private var configured = false

    var body: some View {
        SettingsPage(title: kind.title) {
            if isLoading {
                RexSkeleton(width: .infinity, height: 148, cornerRadius: RexRadius.panel)
            } else {
                RexNote(text: kind.summary)

                SettingsCard {
                    SettingsRow(
                        icon: statusIcon,
                        title: "状态",
                        value: statusText,
                        iconTint: statusColor
                    )

                    SettingsDivider()

                    brandToggleRow

                    if showsForumManagement && isAdmin {
                        SettingsDivider()

                        NavigationLink {
                            SehuatangForumManageView(isAdmin: isAdmin)
                        } label: {
                            HStack(spacing: RexSpacing.md) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color(hex: 0x0A84FF))
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("论坛管理")
                                        .font(RexFont.row)
                                        .foregroundStyle(RexColor.primaryText)

                                    Text("板块地区 · \(ShtForumCatalog.categories.count) 大区")
                                        .font(RexFont.caption)
                                        .foregroundStyle(RexColor.secondaryText)
                                }

                                Spacer(minLength: RexSpacing.sm)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(RexColor.tertiaryText)
                            }
                            .padding(.horizontal, RexSpacing.lg)
                            .frame(minHeight: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RexRowButtonStyle())
                    }
                }

                SettingsSection(title: "连接信息") {
                    SettingsInputRow(
                        icon: "network",
                        title: "主机",
                        placeholder: "192.168.1.10",
                        text: $host
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "number",
                        title: "端口",
                        placeholder: kind.defaultPort,
                        text: $port,
                        keyboard: .numberPad
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "cylinder.split.1x2",
                        title: "库名",
                        placeholder: kind.defaultDatabase,
                        text: $database
                    )
                    .disabled(!isAdmin)
                }

                SettingsSection(title: "登录凭据") {
                    SettingsInputRow(
                        icon: "person",
                        title: "用户",
                        placeholder: "postgres",
                        text: $user,
                        contentType: .username
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "lock",
                        title: "密码",
                        placeholder: hasPassword ? "已保存，输入可覆盖" : "可留空",
                        text: passwordBinding,
                        isSecure: true,
                        contentType: .password
                    )
                    .disabled(!isAdmin)
                }

                if isAdmin {
                    HStack(spacing: RexSpacing.md) {
                        Button {
                            fillDefaults()
                        } label: {
                            secondaryLabel("默认值", busy: false)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isSaving || isTesting)

                        Button {
                            Task { await test() }
                        } label: {
                            secondaryLabel("测试", busy: isTesting)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isSaving || isTesting)

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

    // MARK: - 子视图

    private var brandToggleRow: some View {
        HStack(spacing: RexSpacing.md) {
            Image(kind.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("启用查询")
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)

                Text("\(kind.title) · 资源检索")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
            }

            Spacer(minLength: RexSpacing.sm)

            Toggle("启用查询", isOn: $enabled)
                .labelsHidden()
                .tint(RexColor.brandBlue)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: 64)
        .disabled(!isAdmin)
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { password },
            set: { newValue in
                password = newValue
                passwordTouched = true
            }
        )
    }

    private func secondaryLabel(_ title: String, busy: Bool) -> some View {
        HStack(spacing: RexSpacing.xs) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(RexColor.primaryText)
            }
            Text(title)
        }
        .font(.system(.subheadline, weight: .semibold))
        .foregroundStyle(RexColor.primaryText)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(
            RexColor.secondaryText.opacity(0.1),
            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
        )
    }

    // MARK: - 状态

    private var statusIcon: String {
        if !isAdmin { return configured ? "checkmark.circle.fill" : "circle.dotted" }
        switch connected {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "exclamationmark.circle.fill"
        case .none: return enabled ? "circle.dotted" : "pause.circle"
        }
    }

    private var statusColor: Color {
        if !isAdmin { return configured ? RexColor.success : RexColor.tertiaryText }
        switch connected {
        case .some(true): return RexColor.success
        case .some(false): return enabled ? RexColor.warning : RexColor.tertiaryText
        case .none: return enabled ? RexColor.secondaryText : RexColor.tertiaryText
        }
    }

    private var statusText: String {
        if !isAdmin { return configured ? "已配置" : "未配置" }
        if isTesting { return "检测中" }
        switch connected {
        case .some(true): return enabled ? "已连接" : "已连接（未启用）"
        case .some(false): return enabled ? "连接失败" : "未启用"
        case .none: return enabled ? "待检测" : "未启用"
        }
    }

    // MARK: - 数据

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录")
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await apiClient.fetchSettings(kind.settingsPath, as: DbServiceSettings.self)
            enabled = settings.enabled ?? false
            configured = settings.configured ?? false
            note = settings.note ?? ""

            let dsn = settings.dsn ?? ""
            if !parseDsn(dsn) {
                let message = "已保存的连接串无法解析，请重新填写连接信息后保存"
                parseError = message
                alert = .failure(message, title: "连接串无法解析")
                connected = false
            } else if isAdmin, enabled, !dsn.isEmpty {
                connected = nil
                await probe(dsn)
            } else {
                connected = false
            }

            // 普通账号拿不到 DSN，避免把默认值误当成真实配置展示。
            if !isAdmin {
                host = ""
                port = ""
                database = ""
                user = ""
            }
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription)
        }
    }

    private func save() async {
        guard let apiClient, isAdmin, !isSaving else { return }

        if let parseError {
            alert = .failure(parseError, title: "连接串无法解析")
            return
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alert = .failure("请填写主机地址")
            return
        }

        isSaving = true
        defer { isSaving = false }

        let dsn = buildDsn()
        let nextPassword = resolvePassword()

        do {
            let saved = try await apiClient.putSettings(
                kind.settingsPath,
                json: try JSONEncoder().encode(
                    DbServiceSaveBody(enabled: enabled, dsn: dsn, note: note)
                ),
                as: DbServiceSettings.self
            )
            enabled = saved.enabled ?? enabled
            configured = saved.configured ?? (enabled && !dsn.isEmpty)
            savedPassword = nextPassword
            hasPassword = !nextPassword.isEmpty
            password = ""
            passwordTouched = false
            parseError = nil
            RexHaptics.success()
            alert = .success("配置已保存")

            if enabled {
                await probe(dsn)
            } else {
                connected = false
            }
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func test() async {
        guard let apiClient, isAdmin, !isTesting, !isSaving else { return }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alert = .failure("请填写主机地址")
            return
        }

        isTesting = true
        defer { isTesting = false }

        do {
            let result = try await apiClient.postSettings(
                kind.testPath,
                json: try JSONEncoder().encode(
                    DbServiceSaveBody(enabled: enabled, dsn: buildDsn(), note: note)
                ),
                as: ServiceTestResult.self
            )
            let ok = result.ok ?? false
            connected = ok
            RexHaptics.success()
            let message = result.message
                ?? (ok ? "连接成功" : "连接失败")
            alert = ok ? .success(message) : .failure(message, title: "连接失败")
        } catch {
            connected = false
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    /// 静默探测：加载时刷新状态，不弹提示。
    private func probe(_ dsn: String) async {
        guard let apiClient else { return }

        isTesting = true
        defer { isTesting = false }

        do {
            let result = try await apiClient.postSettings(
                kind.testPath,
                json: try JSONEncoder().encode(
                    DbServiceSaveBody(enabled: enabled, dsn: dsn, note: note)
                ),
                as: ServiceTestResult.self
            )
            connected = result.ok ?? false
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            connected = false
        }
    }

    private func fillDefaults() {
        host = "127.0.0.1"
        port = kind.defaultPort
        database = kind.defaultDatabase
        user = "postgres"
        dsnQuery = ""
        parseError = nil
        password = ""
        passwordTouched = false
        RexHaptics.selection()
        alert = .success("已填入默认值")
    }

    // MARK: - DSN

    /// 把后端返回的 DSN 拆成可编辑字段；空的 DSN 视为尚未配置。
    private func parseDsn(_ raw: String) -> Bool {
        host = ""
        port = kind.defaultPort
        database = kind.defaultDatabase
        user = "postgres"
        password = ""
        passwordTouched = false
        savedPassword = ""
        hasPassword = false
        dsnQuery = ""

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        guard let components = URLComponents(string: text) else { return false }

        host = components.host ?? ""

        if let value = components.port {
            port = String(value)
        }

        if let value = components.user, !value.isEmpty {
            user = value
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            database = path
        }

        let stored = components.password ?? ""
        savedPassword = stored
        hasPassword = !stored.isEmpty

        if let query = components.percentEncodedQuery, !query.isEmpty {
            dsnQuery = "?" + query
        }

        return true
    }

    private func resolvePassword() -> String {
        passwordTouched ? password : (hasPassword ? savedPassword : "")
    }

    private func buildDsn() -> String {
        let hostValue = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseValue = database.trimmingCharacters(in: .whitespacesAndNewlines)
        let userValue = user.trimmingCharacters(in: .whitespacesAndNewlines)

        return "postgresql://\(encode(userValue.isEmpty ? "postgres" : userValue)):\(encode(resolvePassword()))@\(hostValue):\(portValue.isEmpty ? kind.defaultPort : portValue)/\(encode(databaseValue.isEmpty ? kind.defaultDatabase : databaseValue))\(dsnQuery)"
    }

    private func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - 色花堂论坛管理

private let forumRegionOptions: [(id: String, label: String)] = [
    ("japan", "日本"),
    ("china", "国产"),
    ("western", "欧美"),
    ("mixed", "混合"),
    ("other", "其他"),
]

/// 色花堂板块地区覆盖：大区 → 板块 → 地区。
struct SehuatangForumManageView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    @State private var overrides: [String: String] = [:]
    @State private var isLoading = true
    @State private var alert: RexAlertInfo?

    var body: some View {
        SettingsPage(
            title: "论坛管理",
            actions: [
                RexNavAction(
                    systemImage: "arrow.clockwise",
                    label: "刷新",
                    isEnabled: !isLoading,
                    action: { Task { await load() } }
                )
            ]
        ) {
            if isLoading {
                RexSkeleton(width: .infinity, height: 160, cornerRadius: RexRadius.panel)
            } else {
                ForEach(ShtForumCatalog.categories) { category in
                    SettingsSection(title: category.category) {
                        ForEach(Array(category.boards.enumerated()), id: \.element.fid) { index, board in
                            if index > 0 {
                                SettingsDivider()
                            }

                            RexSettingsNavLink(
                                icon: "folder.fill",
                                tint: Color(hex: 0x0A84FF),
                                title: board.name,
                                subtitle: "fid \(board.fid) · \(regionLabel(for: board))"
                            ) {
                                ForumBoardRegionView(
                                    board: board,
                                    overrides: $overrides,
                                    isAdmin: isAdmin
                                )
                            }
                        }
                    }
                }

                RexNote(text: "地区用于片商搜索的结果归类；未设置的板块保持默认，不参与筛选。")
            }
        }
        .task { await load() }
        .rexAlert($alert)
    }

    private func regionLabel(for board: ShtForumBoard) -> String {
        guard
            let id = overrides["\(board.fid):"],
            let option = forumRegionOptions.first(where: { $0.id == id })
        else {
            return "未设地区"
        }
        return option.label
    }

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录")
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await apiClient.fetchSettings(
                "api/settings/forum/sehuatang",
                as: ForumRegionSettings.self
            )
            overrides = settings.regionByKey ?? [:]
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }
}

/// 单个板块的地区设置。
struct ForumBoardRegionView: View {
    let board: ShtForumBoard
    @Binding var overrides: [String: String]
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    @State private var isSaving = false
    @State private var alert: RexAlertInfo?

    var body: some View {
        SettingsPage(title: board.name) {
            SettingsCard {
                ForEach(Array(forumRegionOptions.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        SettingsDivider()
                    }

                    Button {
                        Task { await save(option.id) }
                    } label: {
                        HStack(spacing: RexSpacing.md) {
                            Image(systemName: "globe.asia.australia.fill")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(RexColor.brandBlue)
                                .frame(width: 28)

                            Text(option.label)
                                .font(RexFont.row)
                                .foregroundStyle(RexColor.primaryText)

                            Spacer(minLength: RexSpacing.sm)

                            if selectedRegion == option.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(RexColor.brandBlue)
                            }
                        }
                        .padding(.horizontal, RexSpacing.lg)
                        .frame(minHeight: RexLayout.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RexRowButtonStyle())
                    .disabled(!isAdmin || isSaving)
                }
            }

            if isSaving {
                HStack(spacing: RexSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在保存")
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                }
                .frame(maxWidth: .infinity)
            }

            if !isAdmin {
                RexNote(text: "当前账号不是管理员，只能查看板块地区。")
            } else {
                RexNote(text: "fid \(board.fid) · 选择后立即生效。")
            }
        }
        .rexAlert($alert)
    }

    private var selectedRegion: String? {
        overrides["\(board.fid):"]
    }

    private func save(_ region: String) async {
        guard let apiClient, isAdmin, !isSaving else { return }

        var next = overrides
        next["\(board.fid):"] = region

        isSaving = true
        defer { isSaving = false }

        do {
            let saved = try await apiClient.putSettings(
                "api/settings/forum/sehuatang",
                json: try JSONEncoder().encode(ForumRegionSaveBody(regionByKey: next)),
                as: ForumRegionSettings.self
            )
            overrides = saved.regionByKey ?? next
            RexHaptics.success()
            alert = .success("已更新为\(regionLabel(region))")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func regionLabel(_ id: String) -> String {
        forumRegionOptions.first(where: { $0.id == id })?.label ?? id
    }
}
