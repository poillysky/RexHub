import SwiftUI

/// 插件中心：已安装插件的启停/重启/更新/日志，以及市场安装入口。
struct PluginCenterView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case installed
        case market

        var id: String { rawValue }

        var title: String {
            switch self {
            case .installed: "已安装"
            case .market: "市场"
            }
        }
    }

    @State private var tab: Tab = .installed
    @State private var installed: [PluginInfo] = []
    @State private var market: [PluginMarketEntry] = []
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var alert: RexAlertInfo?
    @State private var logsText: [String] = []
    @State private var logsTitle = ""
    @State private var showsLogs = false
    @State private var isScrolled = false

    var body: some View {
        SettingsPage(title: "插件中心", actions: actions) {
            Picker("视图", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: tab) { _, _ in
                Task { await loadCurrent(force: true) }
            }

            if isLoading, currentIsEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    RexSkeleton(width: .infinity, height: 84, cornerRadius: RexRadius.panel)
                }
            } else if let errorText, currentIsEmpty {
                RexInlineNotice(
                    title: "加载失败",
                    message: errorText,
                    tone: .error,
                    actionTitle: "重试"
                ) {
                    Task { await loadCurrent(force: true) }
                }
            } else {
                if tab == .installed {
                    installedList
                } else {
                    marketList
                }
            }

            if !isAdmin {
                RexNote(text: "当前账号不是管理员，插件操作不可用。")
            }
        }
        .task { await loadCurrent(force: false) }
        .sheet(isPresented: $showsLogs) {
            PluginLogsSheet(title: logsTitle, lines: logsText)
                .rexSheetStyle()
        }
        .rexAlert($alert)
    }

    private var actions: [RexNavAction] {
        [
            RexNavAction(
                systemImage: "arrow.clockwise",
                label: "刷新",
                isEnabled: !isLoading && !isBusy,
                action: { Task { await loadCurrent(force: true) } }
            )
        ]
    }

    private var currentIsEmpty: Bool {
        tab == .installed ? installed.isEmpty : market.isEmpty
    }

    // MARK: - 已安装

    private var installedList: some View {
        VStack(spacing: RexSpacing.lg) {
            ForEach(installed) { plugin in
                SettingsCard {
                    SettingsRow(
                        icon: plugin.running ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        title: plugin.name,
                        value: plugin.installedVersion.isEmpty ? plugin.version : plugin.installedVersion,
                        iconTint: plugin.running ? RexColor.success : RexColor.warning
                    )

                    if !plugin.description.isEmpty {
                        Text(plugin.description)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineSpacing(2)
                            .padding(.horizontal, RexSpacing.lg)
                            .padding(.bottom, RexSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !plugin.error.isEmpty {
                        RexNote(text: plugin.error, tone: .error)
                            .padding(.bottom, RexSpacing.sm)
                    }

                    SettingsDivider()

                    SettingsSwitchRow(
                        title: "启用",
                        isOn: Binding(
                            get: { plugin.enabled },
                            set: { value in
                                guard isAdmin else { return }
                                Task { await toggle(plugin, enabled: value) }
                            }
                        )
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    HStack(spacing: RexSpacing.md) {
                        smallButton("重启", icon: "arrow.clockwise") {
                            Task { await restart(plugin) }
                        }
                        .disabled(!isAdmin || isBusy)

                        smallButton("更新", icon: "square.and.arrow.down") {
                            Task { await update(plugin) }
                        }
                        .disabled(!isAdmin || isBusy)

                        smallButton("日志", icon: "doc.text.magnifyingglass") {
                            Task { await loadLogs(plugin) }
                        }
                    }
                    .padding(.horizontal, RexSpacing.lg)
                    .padding(.vertical, RexSpacing.sm)
                }
            }
        }
    }

    // MARK: - 市场

    private var marketList: some View {
        VStack(spacing: RexSpacing.lg) {
            ForEach(market) { entry in
                SettingsCard {
                    SettingsRow(
                        icon: "shippingbox",
                        title: entry.name,
                        value: entry.version,
                        iconTint: RexColor.brandBlue
                    )

                    if !entry.description.isEmpty {
                        Text(entry.description)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineSpacing(2)
                            .padding(.horizontal, RexSpacing.lg)
                            .padding(.bottom, RexSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SettingsDivider()

                    HStack {
                        Text(entry.installed ? "已安装 \(entry.installedVersion)" : "未安装")
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.tertiaryText)

                        Spacer(minLength: RexSpacing.sm)

                        if entry.updateAvailable {
                            smallButton("更新", icon: "square.and.arrow.down") {
                                Task { await install(entry) }
                            }
                            .disabled(!isAdmin || isBusy)
                        } else if !entry.installed {
                            smallButton("安装", icon: "plus") {
                                Task { await install(entry) }
                            }
                            .disabled(!isAdmin || isBusy)
                        }
                    }
                    .padding(.horizontal, RexSpacing.lg)
                    .padding(.vertical, RexSpacing.sm)
                }
            }
        }
    }

    private func smallButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(.footnote, weight: .medium))
            }
            .foregroundStyle(RexColor.brandBlue)
            .padding(.horizontal, RexSpacing.md)
            .frame(height: 32)
            .background(
                RexColor.brandBlue.opacity(0.10),
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - 操作

    private func loadCurrent(force: Bool) async {
        guard let apiClient, !isBusy else { return }
        if !force {
            guard currentIsEmpty else { return }
        }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            if tab == .installed {
                installed = try await apiClient.installedPlugins()
            } else {
                let result = try await apiClient.pluginMarket()
                market = result.plugins
                if !result.errors.isEmpty {
                    let message = result.errors.joined(separator: "\n")
                    if currentIsEmpty {
                        errorText = message
                    } else {
                        alert = .failure(message, title: "加载失败")
                    }
                }
            }
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            if currentIsEmpty {
                errorText = error.localizedDescription
            } else {
                alert = .failure(error.localizedDescription, title: "加载失败")
            }
        }
    }

    private func toggle(_ plugin: PluginInfo, enabled: Bool) async {
        guard let apiClient, !isBusy else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }

        do {
            try await apiClient.setPluginEnabled(plugin.id, enabled: enabled)
            RexHaptics.success()
            installed = try await apiClient.installedPlugins()
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func restart(_ plugin: PluginInfo) async {
        guard let apiClient, !isBusy else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }

        do {
            try await apiClient.restartPlugin(plugin.id)
            RexHaptics.success()
            installed = try await apiClient.installedPlugins()
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func update(_ plugin: PluginInfo) async {
        guard let apiClient, !isBusy else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }

        do {
            try await apiClient.updatePlugin(plugin.id)
            RexHaptics.success()
            installed = try await apiClient.installedPlugins()
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func install(_ entry: PluginMarketEntry) async {
        guard let apiClient, !isBusy else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }

        do {
            try await apiClient.installPlugin(repository: entry.repository, id: entry.id)
            RexHaptics.success()
            if tab == .market {
                let result = try await apiClient.pluginMarket()
                market = result.plugins
            }
            installed = try await apiClient.installedPlugins()
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func loadLogs(_ plugin: PluginInfo) async {
        guard let apiClient else { return }
        logsTitle = plugin.name
        do {
            logsText = try await apiClient.pluginLogs(plugin.id)
        } catch {
            logsText = ["读取日志失败：\(error.localizedDescription)"]
        }
        showsLogs = true
    }
}

// MARK: - 日志

private struct PluginLogsSheet: View {
    let title: String
    let lines: [String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(lines.isEmpty ? "暂无日志" : lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(RexColor.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(RexSpacing.lg)
            }
            .background(RexPageBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Stremio 插件库

struct StremioSettingsView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    @State private var snapshot: StremioSnapshot?
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var alert: RexAlertInfo?
    @State private var newURL = ""
    @State private var showAddField = false

    var body: some View {
        SettingsPage(title: "Stremio 插件库") {
            if isLoading {
                ForEach(0..<3, id: \.self) { _ in
                    RexSkeleton(width: .infinity, height: 84, cornerRadius: RexRadius.panel)
                }
            } else {
                if showAddField {
                    SettingsCard {
                        SettingsInputRow(
                            icon: "link",
                            title: "Addon 地址",
                            placeholder: "https://example.com/manifest.json",
                            text: $newURL,
                            keyboard: .URL
                        )

                        SettingsDivider()

                        HStack {
                            Spacer(minLength: 0)
                            Button("添加") {
                                Task { await addAddon() }
                            }
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(RexColor.brandBlue)
                            .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                        }
                        .padding(.horizontal, RexSpacing.lg)
                        .frame(minHeight: 44)
                    }
                }

                if let snapshot, !snapshot.addons.isEmpty {
                    VStack(spacing: RexSpacing.lg) {
                        ForEach(snapshot.addons) { addon in
                            SettingsCard {
                                SettingsRow(
                                    icon: addon.enabled ? "puzzlepiece.fill" : "puzzlepiece",
                                    title: addon.name,
                                    value: addon.version,
                                    iconTint: addon.enabled ? RexColor.success : RexColor.tertiaryText
                                )

                                if !addon.error.isEmpty {
                                    RexNote(text: addon.error, tone: .error)
                                        .padding(.bottom, RexSpacing.sm)
                                }

                                SettingsDivider()

                                SettingsSwitchRow(
                                    title: "启用",
                                    isOn: Binding(
                                        get: { addon.enabled },
                                        set: { value in Task { await toggle(addon, enabled: value) } }
                                    )
                                )
                                .disabled(!isAdmin)
                            }
                        }
                    }
                } else {
                    RexStateCard(
                        symbol: "puzzlepiece.extension",
                        title: "还没有 Addon",
                        message: "添加 Stremio addon 地址后，影视搜索会自动聚合它的片源。",
                        tone: .neutral
                    )
                }

                if isAdmin {
                    Button {
                        withAnimation(RexMotion.quick) { showAddField.toggle() }
                    } label: {
                        Label(showAddField ? "取消添加" : "添加 Addon", systemImage: showAddField ? "xmark" : "plus")
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(RexColor.brandBlue)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(PressableButtonStyle())
                } else {
                    RexNote(text: "当前账号不是管理员，只能查看。")
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
        alert = nil
        defer { isLoading = false }

        do {
            snapshot = try await apiClient.stremioSnapshot()
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }

    private func toggle(_ addon: StremioAddon, enabled: Bool) async {
        guard let apiClient, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await apiClient.setStremioAddonEnabled(slug: addon.slug, enabled: enabled)
            RexHaptics.success()
            snapshot = try await apiClient.stremioSnapshot()
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }

    private func addAddon() async {
        guard let apiClient, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await apiClient.addStremioAddon(url: newURL.trimmingCharacters(in: .whitespacesAndNewlines))
            newURL = ""
            showAddField = false
            RexHaptics.success()
            snapshot = try await apiClient.stremioSnapshot()
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }
}
