import SwiftUI
import UIKit

/// 「更多」Tab：iOS 原生风格的分组设置中心。
/// 结构固定：服务状态卡 → 常用功能快捷入口 → 外观与文件 / 视频与音乐 / 其他设置 / 应用与支持，
struct MoreView: View {
    let session: AuthSession
    var onLogout: () -> Void
    var reselectToken: Int = 0
    var isOffline: Bool = false

    @State private var isScrolled = false

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(title: "更多", isScrolled: isScrolled)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: RexSpacing.xxl) {
                        VStack(alignment: .leading, spacing: RexSpacing.sm) {
                            Text("个人设置与服务中心")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RexColor.secondaryText)
                                .padding(.horizontal, RexSpacing.xs)

                            NavigationLink {
                                AccountSettingsView(session: session, onLogout: onLogout)
                            } label: {
                                ServiceStatusCard(isOffline: isOffline)
                            }
                            .buttonStyle(.plain)
                        }

                        SettingsSection(title: "常用功能") {
                            QuickActionGrid(actions: quickActions)
                        }

                        SettingsSection(title: "外观与文件") {
                            SettingsLink(icon: "paintpalette", title: "外观与主题") {
                                AppearanceSettingsView()
                            }
                            SettingsDivider()
                            SettingsLink(icon: "list.bullet.rectangle", title: "文件列表") {
                                FileListSettingsView()
                            }
                        }

                        SettingsSection(title: "视频与音乐") {
                            SettingsLink(icon: "play.rectangle", title: "视频播放器") {
                                VideoPlayerSettingsView()
                            }

                            SettingsDivider()

                            SettingsLink(icon: "slider.horizontal.3", title: "播放偏好") {
                                PlaybackPreferenceView()
                            }

                            SettingsDivider()

                            SettingsLink(icon: "hand.draw", title: "手势") {
                                GestureSettingsView()
                            }

                            SettingsDivider()

                            SettingsLink(icon: "captions.bubble", title: "字幕") {
                                SubtitleSettingsView()
                            }

                            SettingsDivider()

                            SettingsLink(icon: "music.note", title: "音乐播放器") {
                                MusicPlayerSettingsView()
                            }
                        }

                        SettingsSection(title: "其他设置") {
                            entry("eye.slash", "私密模式设置")
                            SettingsDivider()
                            SettingsLink(icon: "internaldrive", title: "缓存管理") {
                                CacheManagementView()
                            }
                        }

                        SettingsSection(title: "应用与支持") {
                            entry("info.circle", "关于与版本", value: appVersion)
                            SettingsDivider()
                            entry("envelope", "问题反馈")
                            SettingsDivider()
                            entry("doc.text.magnifyingglass", "日志与诊断")
                        }

                        Text("RexHub · Version \(appVersion)")
                            .font(.system(size: 12))
                            .foregroundStyle(RexColor.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, RexSpacing.xs)
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(RexScrollOffsetReader(space: "moreScroll"))
                    .id("moreTop")
                }
                .rexScrollTracking("moreScroll", isScrolled: $isScrolled)
                .onChange(of: reselectToken) { _, _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("moreTop", anchor: .top)
                    }
                }
            }
        }
        .background(RexColor.background.ignoresSafeArea())
    }

    /// 常用功能：高频业务入口，不是设置项，不与下面的分组重复。
    private var quickActions: [QuickAction] {
        [
            QuickAction(icon: .symbol("heart.fill", 0xFF8FB1, 0xFF4D6D), title: "我的收藏") {
                AnyView(ComingSoonPage(title: "我的收藏"))
            },
            QuickAction(icon: .asset("Brand115"), title: "115 网盘") {
                AnyView(PanAccountView())
            },
            QuickAction(icon: .symbol("server.rack", 0x64D2FF, 0x0A84FF), title: "服务管理") {
                AnyView(ServiceManagementView())
            },
            QuickAction(icon: .symbol("puzzlepiece.extension.fill", 0xA98BFF, 0x6D5AE6), title: "插件管理") {
                AnyView(ComingSoonPage(title: "插件管理"))
            }
        ]
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// 统一入口：未接入的设置项先进占位页。
    private func entry(_ icon: String, _ title: String, value: String? = nil) -> some View {
        SettingsLink(icon: icon, title: title, value: value) {
            ComingSoonPage(title: title)
        }
    }
}

// MARK: - 二级页

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
                .buttonStyle(.plain)
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Text(serverHost)
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: RexSpacing.sm)

            Button {
                isPickingAvatar = true
            } label: {
                Text("更换头像")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                    .padding(.horizontal, RexSpacing.sm + 2)
                    .frame(height: 30)
                    .background(RexColor.brandBlue.opacity(0.1), in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
        )
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

                    Text("不选头像时使用昵称首字母，选择结果仅保存在本机。")
                        .font(.system(size: 12))
                        .foregroundStyle(RexColor.secondaryText)
                }
                .padding(RexSpacing.xl)
            }
            .background(RexColor.background)
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
    @State private var errorText: String?
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

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12))
                        .foregroundStyle(RexColor.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, RexSpacing.xs)
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
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundStyle(RexColor.onBrand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            .fill(RexColor.brandGradient)
                    )
                    .opacity(canSubmit ? 1 : 0.45)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!canSubmit)

                Text("修改后所有设备的登录状态会立即失效，需要用新密码重新登录。")
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RexSpacing.xs)
            }
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
        .frame(height: 56)
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
            errorText = "登录状态已失效，请重新登录"
            return
        }

        focused = nil
        isSaving = true
        errorText = nil
        defer { isSaving = false }

        do {
            try await client.changePassword(current: currentPassword, new: newPassword)
            isFinished = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "修改失败，请重试"
        }
    }
}

private struct ComingSoonPage: View {
    let title: String

    var body: some View {
        SettingsPage(title: title) {
            VStack(spacing: RexSpacing.lg) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(width: 64, height: 64)
                    .background(
                        RexColor.brandBlue.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                    )

                Text("「\(title)」正在接入")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)

                Text("这里会放该项的具体设置")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RexSpacing.xxxl)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
            )
        }
    }
}

/// 115 授权只走 Web 管理台，App 只做说明与地址展示，不收集 Cookie。
private struct WebAdminPage: View {
    let title: String
    let message: String

    private var adminAddress: String {
        guard let base = ServerConfig.baseURL else { return "未设置" }
        let trimmed = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed + "/admin"
    }

    var body: some View {
        SettingsPage(title: title) {
            VStack(spacing: RexSpacing.lg) {
                Image(systemName: "safari")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(width: 64, height: 64)
                    .background(
                        RexColor.brandBlue.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                    )

                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(RexColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)

                Text(adminAddress)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RexSpacing.xxxl)
            .padding(.horizontal, RexSpacing.xl)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)

                Text(isOffline ? "服务连接中断 · 账号信息" : "服务连接正常 · 账号信息")
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: RexSpacing.sm)

            statusBadge

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText.opacity(0.55))
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(height: 76)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOffline ? RexColor.warning : RexColor.success)
                .frame(width: 6, height: 6)

            Text(isOffline ? "未连接" : "已连接")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            (isOffline ? RexColor.warning : RexColor.success).opacity(0.12),
            in: Capsule()
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

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: RexSpacing.sm),
        count: 4
    )

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
        VStack(spacing: RexSpacing.sm) {
            iconTile(action.icon)

            Text(action.title)
                .font(.system(size: 12))
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.md)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func iconTile(_ icon: QuickActionIcon) -> some View {
        switch icon {
        case .symbol(let name, let startHex, let endHex):
            Image(systemName: name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: [Color(hex: startHex), Color(hex: endHex)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: Color(hex: endHex).opacity(0.26), radius: 8, y: 4)

        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous))
                .shadow(color: Color(hex: 0x1B3B8F).opacity(0.22), radius: 8, y: 4)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
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
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "settingsScroll"))
            }
            .rexScrollTracking("settingsScroll", isScrolled: $isScrolled)
        }
        .background(RexColor.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
        )
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
                    .font(.system(size: 17))
                    .foregroundStyle(iconTint)
                    .frame(width: 28)
            }

            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(titleColor)

            Spacer(minLength: RexSpacing.sm)

            if let value {
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText.opacity(0.55))
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(height: 56)
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
                .font(.system(size: 16))
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(RexColor.brandBlue)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(height: 56)
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
                .font(.system(size: 16))
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Text("\(value) 秒")
                .font(.system(size: 14))
                .foregroundStyle(RexColor.secondaryText)
                .monospacedDigit()

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
        .frame(height: 56)
    }

    private func stepButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? RexColor.primaryText : RexColor.secondaryText.opacity(0.4))
                .frame(width: 38, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
