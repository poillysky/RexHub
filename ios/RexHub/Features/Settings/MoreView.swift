import SwiftUI
import UIKit

/// 「更多」Tab：与 PWA 设置中心同构 —— 大标题 + 分组入口（彩色图标 + 描述）。
struct MoreView: View {
    let session: AuthSession
    var onLogout: () -> Void
    var reselectToken: Int = 0
    var isOffline: Bool = false

    @State private var isScrolled = false
    @State private var cacheUsage = CacheUsage.zero
    @State private var isLoadingCache = true
    @State private var isShowingCache = false

    var body: some View {
        VStack(spacing: 0) {
            RexHubTitle(title: "更多") {
                EmptyView()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: RexSpacing.xl) {
                        cacheSection
                        quickSection
                        accountSection
                        playerSection
                        networkSection
                        supportSection

                        Text("RexHub · Version \(appVersion)")
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.tertiaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, RexSpacing.xs)
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.sm)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(RexScrollOffsetReader(space: "moreScroll"))
                    .id("moreTop")
                }
                .scrollBounceBehavior(.basedOnSize)
                .rexScrollTracking("moreScroll", isScrolled: $isScrolled)
                .onChange(of: reselectToken) { _, _ in
                    RexHaptics.tap()
                    withAnimation(RexMotion.standard) {
                        proxy.scrollTo("moreTop", anchor: .top)
                    }
                }
            }
        }
        .background(RexPageBackground())
        .task { await refreshCache() }
        .navigationDestination(isPresented: $isShowingCache) {
            CacheManagementView()
        }
        .onChange(of: isShowingCache) { _, showing in
            guard !showing else { return }
            Task { await refreshCache() }
        }
    }

    // MARK: - 分组

    private var cacheSection: some View {
        Button {
            isShowingCache = true
        } label: {
            CacheStorageCard(usage: cacheUsage, isLoading: isLoadingCache)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("缓存管理")
    }

    private func refreshCache() async {
        cacheUsage = await CacheStats.scan()
        isLoadingCache = false
    }

    private var accountSection: some View {
        SettingsSection(title: "账号与外观") {
            RexSettingsNavLink(
                icon: "person.2.fill",
                tint: Color(hex: 0x0A84FF),
                title: "用户管理"
            ) {
                AccountSettingsView(session: session, onLogout: onLogout)
            }

            SettingsDivider()

            RexSettingsNavLink(
                icon: "paintpalette.fill",
                tint: Color(hex: 0x6D5AE6),
                title: "外观"
            ) {
                AppearanceSettingsView()
            }

            SettingsDivider()

            RexSettingsNavLink(
                icon: "list.bullet.rectangle.fill",
                tint: RexColor.brandBlue,
                title: "文件列表"
            ) {
                FileListSettingsView()
            }
        }
    }

    /// 缓存卡片下方的快捷入口：一行四列，点进去是各自的配置列表。
    private var quickSection: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text("快捷入口")
                .font(RexFont.section)
                .foregroundStyle(RexColor.secondaryText)
                .padding(.horizontal, RexSpacing.xs)

            QuickActionGrid(actions: quickActions)
                .padding(.vertical, RexSpacing.md)
                .padding(.horizontal, RexSpacing.xs)
                .frame(maxWidth: .infinity)
                .rexCard(cornerRadius: RexRadius.panel)
        }
    }

    private var quickActions: [QuickAction] {
        var actions: [QuickAction] = [
            QuickAction(
                icon: .asset("Brand115"),
                title: "115 网盘",
                destination: {
                    AnyView(PanAccountView(isAdmin: session.user.isAdmin))
                }
            ),
            QuickAction(
                icon: .symbol("square.stack.3d.up.fill", 0x34C759, 0x248A3D),
                title: "服务",
                destination: {
                    AnyView(ServiceSettingsHubView(isAdmin: session.user.isAdmin))
                }
            ),
            QuickAction(
                icon: .asset("ServicePluginCenter"),
                title: "插件",
                destination: {
                    AnyView(PluginSettingsHubView(isAdmin: session.user.isAdmin))
                }
            )
        ]

        if session.user.isAdmin {
            actions.append(
                QuickAction(
                    icon: .asset("ServiceAI"),
                    title: "AI 模型",
                    destination: {
                        AnyView(AISettingsView(isAdmin: true))
                    }
                )
            )
        }

        return actions
    }

    private var networkSection: some View {
        SettingsSection(title: "网络管理") {
            RexSettingsNavLink(
                imageName: "ServiceNetwork",
                title: "网络代理"
            ) {
                NetworkSettingsView(isAdmin: session.user.isAdmin)
            }
        }
    }

    private var playerSection: some View {
        SettingsSection(title: "播放与音频") {
            RexSettingsNavLink(
                icon: "play.rectangle.fill",
                tint: Color(hex: 0x0A84FF),
                title: "视频播放器"
            ) {
                VideoPlayerSettingsView()
            }

            SettingsDivider()

            RexSettingsNavLink(
                icon: "slider.horizontal.3",
                tint: Color(hex: 0x64D2FF),
                title: "播放偏好"
            ) {
                PlaybackPreferenceView()
            }

            SettingsDivider()

            RexSettingsNavLink(
                icon: "hand.draw.fill",
                tint: Color(hex: 0xFF9F0A),
                title: "手势"
            ) {
                GestureSettingsView()
            }

            SettingsDivider()

            RexSettingsNavLink(
                icon: "captions.bubble.fill",
                tint: Color(hex: 0xEC4899),
                title: "字幕"
            ) {
                SubtitleSettingsView()
            }

            SettingsDivider()

            RexSettingsNavLink(
                icon: "music.note",
                tint: Color(hex: 0xA855F7),
                title: "音乐播放器"
            ) {
                MusicPlayerSettingsView()
            }
        }
    }

    private var supportSection: some View {
        SettingsSection(title: "应用与支持") {
            RexSettingsNavButton(
                icon: "info.circle.fill",
                tint: Color(hex: 0x0A84FF),
                title: "关于与版本",
                value: nil,
                action: {}
            )

            SettingsDivider()

            RexSettingsNavButton(
                icon: "envelope.fill",
                tint: Color(hex: 0x10B981),
                title: "问题反馈",
                value: nil,
                action: {}
            )

            SettingsDivider()

            RexSettingsNavButton(
                icon: "doc.text.magnifyingglass",
                tint: Color(hex: 0x64748B),
                title: "日志与诊断",
                value: nil,
                action: {}
            )
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - 二级页

/// 「服务」快捷入口：服务配置列表，图标使用 PWA 同款品牌图。
private struct ServiceSettingsHubView: View {
    let isAdmin: Bool

    var body: some View {
        SettingsPage(title: "服务管理") {
            SettingsSection(title: "服务") {
                ForEach(Array(ServiceKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    if index > 0 {
                        SettingsDivider()
                    }

                    RexSettingsNavLink(
                        imageName: kind.imageName,
                        title: kind.title,
                        tags: kind.tags,
                        subtitle: kind.subtitle
                    ) {
                        ServiceSettingsDestination(kind: kind, isAdmin: isAdmin)
                    }
                }
            }

            RexNote(text: "连接参数在此维护；账号、密码与令牌仅管理员可修改，普通账号只读。")
        }
    }
}

/// 按服务类型分流到 HTTP 配置页或 Postgres 连接配置页。
private struct ServiceSettingsDestination: View {
    let kind: ServiceKind
    let isAdmin: Bool

    var body: some View {
        if kind.usesPostgres {
            PostgresDbSettingsView(
                kind: kind,
                isAdmin: isAdmin,
                showsForumManagement: kind == .sehuatang
            )
        } else {
            ServiceSettingsView(kind: kind, isAdmin: isAdmin)
        }
    }
}

/// 「插件」快捷入口：插件配置列表。
private struct PluginSettingsHubView: View {
    let isAdmin: Bool

    var body: some View {
        SettingsPage(title: "插件") {
            SettingsSection(title: "插件") {
                RexSettingsNavLink(
                    imageName: "ServicePluginCenter",
                    title: "插件中心"
                ) {
                    PluginCenterView(isAdmin: isAdmin)
                }

                if isAdmin {
                    SettingsDivider()

                    RexSettingsNavLink(
                        imageName: "ServiceStremio",
                        title: "Stremio 插件库"
                    ) {
                        StremioSettingsView(isAdmin: true)
                    }
                }
            }
        }
    }
}

private struct AccountSettingsView: View {
    let session: AuthSession
    var onLogout: () -> Void

    @State private var avatars = AvatarStore.shared
    @State private var isPickingAvatar = false
    @State private var isConfirmingLogout = false

    private var serverHost: String {
        ServerConfig.baseURL?.host ?? "未设置"
    }

    /// 只读展示，不做会话列表。
    private var deviceSummary: String {
        let device = UIDevice.current
        return "\(device.model) · \(device.systemName) \(device.systemVersion)"
    }

    var body: some View {
        SettingsPage(title: "账号设置") {
            profileCard

            SettingsSection(title: "安全") {
                SettingsLink(icon: "lock.rotation", title: "修改密码") {
                    ChangePasswordView(onLogout: onLogout)
                }

                SettingsDivider()

                SettingsRow(
                    icon: "iphone.gen3",
                    title: "当前设备",
                    value: deviceSummary
                )
            }

            SettingsCard {
                Button {
                    isConfirmingLogout = true
                } label: {
                    SettingsRow(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "退出登录",
                        titleColor: RexColor.error,
                        iconTint: RexColor.error
                    )
                }
                .buttonStyle(RexRowButtonStyle())
            }
        }
        .sheet(isPresented: $isPickingAvatar) {
            AvatarPickerSheet(name: session.user.name)
                .rexSheetStyle()
        }
        .alert("退出登录", isPresented: $isConfirmingLogout) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { onLogout() }
        } message: {
            Text("退出后需要重新登录才能继续使用。")
        }
    }

    private var profileCard: some View {
        HStack(spacing: RexSpacing.md) {
            RexAvatar(name: session.user.name, size: 52, selection: avatars.selection)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.user.name.isEmpty ? "未命名账号" : session.user.name)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Text(serverHost)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: RexSpacing.sm)

            Button {
                isPickingAvatar = true
            } label: {
                Text("更换头像")
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                    .padding(.horizontal, RexSpacing.md)
                    .frame(height: 34)
                    .background(RexColor.brandBlue.opacity(0.10), in: Capsule(style: .continuous))
                    .frame(minHeight: RexLayout.minTouch)
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .frame(maxWidth: .infinity)
        .rexCard(cornerRadius: RexRadius.panel)
    }
}

// MARK: - 更换头像

private struct AvatarPickerSheet: View {
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var avatars = AvatarStore.shared

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: RexSpacing.lg),
        count: 4
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    LazyVGrid(columns: columns, spacing: RexSpacing.lg) {
                        optionButton(id: nil)

                        ForEach(AvatarStore.styles) { style in
                            optionButton(id: style.id)
                        }
                    }

                    RexNote(text: "不选头像时使用昵称首字母，选择结果仅保存在本机。")
                }
                .padding(RexSpacing.xl)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(RexPageBackground())
            .navigationTitle("更换头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func optionButton(id: String?) -> some View {
        let selection: AvatarStore.Selection = id.map { .builtIn($0) } ?? .initial

        return Button {
            avatars.select(id)
        } label: {
            RexAvatar(name: name, size: 56, selection: selection)
                .overlay {
                    Circle()
                        .strokeBorder(RexColor.brandBlue, lineWidth: 2)
                        .padding(-4)
                        .opacity(avatars.selection == selection ? 1 : 0)
                }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(id.flatMap { AvatarStore.style(id: $0)?.title } ?? "使用昵称首字母")
        .accessibilityAddTraits(avatars.selection == selection ? .isSelected : [])
    }
}

// MARK: - 修改密码

private struct ChangePasswordView: View {
    var onLogout: () -> Void

    @Environment(\.apiClient) private var apiClient

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var alert: RexAlertInfo?
    @State private var isFinished = false
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case current
        case next
        case confirm
    }

    private var canSubmit: Bool {
        !isSaving
            && !currentPassword.isEmpty
            && newPassword.count >= 8
            && newPassword == confirmPassword
    }

    var body: some View {
        SettingsPage(title: "修改密码") {
            VStack(spacing: RexSpacing.md) {
                SettingsCard {
                    inputRow(
                        icon: "lock",
                        placeholder: "当前密码",
                        text: $currentPassword,
                        contentType: .password,
                        field: .current
                    )

                    SettingsDivider()

                    inputRow(
                        icon: "lock.rotation",
                        placeholder: "新密码（至少 8 位）",
                        text: $newPassword,
                        contentType: .newPassword,
                        field: .next
                    )

                    SettingsDivider()

                    inputRow(
                        icon: "checkmark.shield",
                        placeholder: "再次输入新密码",
                        text: $confirmPassword,
                        contentType: .newPassword,
                        field: .confirm
                    )
                }

                Button {
                    Task { await submit() }
                } label: {
                    ZStack {
                        if isSaving {
                            ProgressView()
                                .tint(RexColor.onBrand)
                        } else {
                            Text("保存修改")
                        }
                    }
                }
                .buttonStyle(RexPrimaryButtonStyle(height: 54))
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.45)

                RexNote(text: "修改后所有设备的登录状态会立即失效，需要用新密码重新登录。")
            }
            .rexAlert($alert)
        }
        .alert("密码已修改", isPresented: $isFinished) {
            Button("重新登录") { onLogout() }
        } message: {
            Text("请使用新密码重新登录。")
        }
    }

    private func inputRow(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType,
        field: Field
    ) -> some View {
        HStack(spacing: RexSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 22)

            SecureField(placeholder, text: text)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
                .submitLabel(field == .confirm ? .done : .next)
                .onSubmit { advance(from: field) }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, 4)
        .frame(minHeight: 56)
    }

    private func advance(from field: Field) {
        switch field {
        case .current:
            focused = .next
        case .next:
            focused = .confirm
        case .confirm:
            Task { await submit() }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        guard let client = apiClient else {
            alert = .failure("登录状态已失效，请重新登录")
            RexHaptics.error()
            return
        }

        focused = nil
        isSaving = true
        alert = nil
        defer { isSaving = false }

        do {
            try await client.changePassword(current: currentPassword, new: newPassword)
            RexHaptics.success()
            isFinished = true
        } catch {
            RexHaptics.error()
            alert = .failure((error as? LocalizedError)?.errorDescription ?? "修改失败，请重试")
        }
    }
}

private struct ComingSoonPage: View {
    let title: String

    var body: some View {
        SettingsPage(title: title) {
            RexStateCard(
                symbol: "wrench.and.screwdriver",
                title: "「\(title)」正在接入",
                message: "该功能的设置项会在后续版本开放，当前版本无需调整。",
                tone: .brand
            )
        }
    }
}

// MARK: - 组件

/// 服务状态卡：连接状态 + 账号信息，点击进入账号设置。
private struct ServiceStatusCard: View {
    let isOffline: Bool

    var body: some View {
        HStack(spacing: RexSpacing.md) {
            RexLogoMark(size: 44, hasShadow: false)

            VStack(alignment: .leading, spacing: 3) {
                Text("NAS 服务")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Text(isOffline ? "服务连接中断 · 账号信息" : "服务连接正常 · 账号信息")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: RexSpacing.sm)

            statusBadge

            Image(systemName: "chevron.right")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(RexColor.tertiaryText)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: 76)
        .rexCard(cornerRadius: RexRadius.panel)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOffline ? RexColor.warning : RexColor.success)
                .frame(width: 6, height: 6)

            Text(isOffline ? "未连接" : "已连接")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(isOffline ? RexColor.warning : RexColor.success)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            (isOffline ? RexColor.warning : RexColor.success).opacity(0.12),
            in: Capsule(style: .continuous)
        )
    }
}

/// 常用功能快捷入口：一行四列，图标 + 文字，不是设置行。
private enum QuickActionIcon {
    case symbol(_ name: String, _ startHex: UInt32, _ endHex: UInt32)
    case asset(_ name: String)
}

private struct QuickAction: Identifiable {
    let icon: QuickActionIcon
    let title: String
    var destination: (() -> AnyView)?
    var action: (() -> Void)?

    var id: String { title }

    init(icon: QuickActionIcon, title: String, destination: @escaping () -> AnyView) {
        self.icon = icon
        self.title = title
        self.destination = destination
    }

    init(icon: QuickActionIcon, title: String, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.action = action
    }
}

private struct QuickActionGrid: View {
    let actions: [QuickAction]

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: RexSpacing.sm),
            count: max(1, min(actions.count, 4))
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: RexSpacing.md) {
            ForEach(actions) { action in
                if let destination = action.destination {
                    NavigationLink {
                        destination()
                    } label: {
                        cell(action)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(action.title)
                } else {
                    Button {
                        action.action?()
                    } label: {
                        cell(action)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(action.title)
                }
            }
        }
        .padding(.horizontal, RexSpacing.sm)
    }

    private func cell(_ action: QuickAction) -> some View {
        VStack(spacing: 10) {
            iconTile(action.icon)

            Text(action.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xs)
        .contentShape(RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous))
    }

    @ViewBuilder
    private func iconTile(_ icon: QuickActionIcon) -> some View {
        switch icon {
        case .symbol(let name, let startHex, let endHex):
            Image(systemName: name)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(
                    LinearGradient(
                        colors: [Color(hex: startHex), Color(hex: endHex)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: Color(hex: endHex).opacity(0.28), radius: 10, y: 5)

        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: Color(hex: 0x1B3B8F).opacity(0.18), radius: 10, y: 5)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text(title)
                .font(RexFont.section)
                .foregroundStyle(RexColor.secondaryText)
                .padding(.horizontal, RexSpacing.xs)

            SettingsCard {
                content
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    /// 顶栏右侧快捷操作，最多两个。
    var actions: [RexNavAction] = []
    /// 传入后页面支持下拉刷新。
    var onRefresh: (() async -> Void)? = nil
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var isScrolled = false

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: title,
                leading: .back(action: { dismiss() }),
                actions: actions,
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    content
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "settingsScroll"))
            }
            .modifier(SettingsRefreshModifier(action: onRefresh))
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .rexScrollTracking("settingsScroll", isScrolled: $isScrolled)
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 只有传入刷新动作时才启用下拉刷新，避免普通设置页出现空手势。
private struct SettingsRefreshModifier: ViewModifier {
    let action: (() async -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.refreshable { await action() }
        } else {
            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous))
        .rexCard(cornerRadius: RexRadius.panel)
    }
}

struct SettingsDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(RexColor.divider)
            .frame(height: 1 / displayScale)
            .padding(.leading, 56)
    }
}

struct SettingsRow: View {
    var icon: String? = nil
    let title: String
    var value: String? = nil
    var titleColor: Color = RexColor.primaryText
    var iconTint: Color = RexColor.brandBlue
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: RexSpacing.md) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 28)
            }

            Text(title)
                .font(RexFont.row)
                .foregroundStyle(titleColor)
                .lineLimit(2)

            Spacer(minLength: RexSpacing.sm)

            if let value {
                Text(value)
                    .font(RexFont.rowValue)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .contentShape(Rectangle())
    }
}

/// 开关行：标题 + 右侧系统开关，整行只读标题、开关独立响应。
struct SettingsSwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: RexSpacing.sm) {
            Text(title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)

            Spacer(minLength: RexSpacing.sm)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(RexColor.brandBlue)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .contentShape(Rectangle())
    }
}

/// 数值行：标题 + 当前值 + 减/加分段按钮，用于片头片尾秒数这类离散参数。
struct SettingsStepperRow: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 5...600
    var step: Int = 5

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: RexSpacing.md) {
            Text(title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Text("\(value) 秒")
                .font(RexFont.rowValue)
                .foregroundStyle(RexColor.secondaryText)
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: 0) {
                stepButton(icon: "minus", enabled: value > range.lowerBound) {
                    value = max(range.lowerBound, value - step)
                }

                Rectangle()
                    .fill(RexColor.divider)
                    .frame(width: 1 / displayScale, height: 20)

                stepButton(icon: "plus", enabled: value < range.upperBound) {
                    value = min(range.upperBound, value + step)
                }
            }
            .background(
                RexColor.field,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
    }

    private func stepButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            RexHaptics.selection()
        }) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? RexColor.primaryText : RexColor.tertiaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RexRowButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(icon == "minus" ? "\(title)减少" : "\(title)增加")
    }
}

struct SettingsLink<Destination: View>: View {
    var icon: String? = nil
    let title: String
    var value: String? = nil
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRow(icon: icon, title: title, value: value, showsChevron: true)
        }
        .buttonStyle(RexRowButtonStyle())
    }
}

#Preview {
    NavigationStack {
        MoreView(
            session: AuthSession(token: "preview", user: .init(id: "1", name: "poilly")),
            onLogout: {}
        )
        .toolbar(.hidden, for: .navigationBar)
    }
}
