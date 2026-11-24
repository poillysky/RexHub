import SwiftUI
import UIKit

// MARK: - 二级页

/// 「服务」快捷入口：固定服务类型的配置页 + 后端已接入服务的只读清单。
struct ServiceSettingsHubView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient
    @State private var services: [ServiceCard] = []
    @State private var listError: String?

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
                        tags: kind.tags
                    ) {
                        ServiceSettingsDestination(kind: kind, isAdmin: isAdmin)
                    }
                }
            }

            serviceListSection
        }
        .task {
            guard services.isEmpty else { return }
            await loadServices()
        }
    }

    /// 后端服务清单：包含 NAS 服务与短剧等内容源，内容在 Web 端维护。
    @ViewBuilder
    private var serviceListSection: some View {
        if let listError {
            SettingsSection(title: "已接入服务") {
                RexStateCard(
                    symbol: "wifi.exclamationmark",
                    title: "服务清单加载失败",
                    message: listError,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task { await loadServices() }
                }
            }
        } else if !services.isEmpty {
            SettingsSection(title: "已接入服务") {
                ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                    if index > 0 {
                        SettingsDivider()
                    }

                    SettingsRow(
                        icon: service.sourceKind.isEmpty ? "server.rack" : "clapperboard",
                        title: service.name.isEmpty ? "未命名服务" : service.name,
                        value: serviceDetail(service)
                    )
                }
            }

            RexNote(text: "服务清单在 Web 端「服务管理」维护，App 只读展示。")
        }
    }

    private func serviceDetail(_ service: ServiceCard) -> String {
        let address = service.apiBase.isEmpty
            ? "\(service.host):\(service.port)"
            : service.apiBase
        let state: String
        switch service.online {
        case .some(true): state = "在线"
        case .some(false): state = "离线"
        case .none: state = "未检测"
        }
        return "\(service.categoryLabel) · \(address) · \(state)"
    }

    private func loadServices() async {
        guard let client = apiClient else {
            listError = "登录状态已失效，请重新登录"
            return
        }

        do {
            services = try await client.serviceList()
            listError = nil
        } catch let error as APIError {
            guard error != .cancelled else { return }
            listError = error.errorDescription ?? "服务清单加载失败，请重试"
        } catch {
            listError = "服务清单加载失败，请重试"
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

struct AccountSettingsView: View {
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
        SettingsPage(title: "个人设置") {
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
                SettingsRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    title: "退出登录",
                    titleColor: RexColor.error,
                    iconTint: RexColor.error
                )
                .rexRowAction { isConfirmingLogout = true }
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
                    .frame(minHeight: 34)
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
                .font(.system(.callout))
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

// MARK: - 组件

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
        .rexPushedScreen()
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
                    .font(.system(.body, weight: .medium))
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
                    .font(.system(.caption, weight: .semibold))
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
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(enabled ? RexColor.primaryText : RexColor.tertiaryText)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(icon == "minus" ? "\(title)减少" : "\(title)增加")
    }
}

struct SettingsLink<Destination: View>: View {
    var icon: String? = nil
    let title: String
    var value: String? = nil
    @ViewBuilder var destination: Destination

    @State private var isPresented = false

    var body: some View {
        SettingsRow(icon: icon, title: title, value: value, showsChevron: true)
            .rexRowAction { isPresented = true }
            .navigationDestination(isPresented: $isPresented) {
                destination
            }
    }
}
