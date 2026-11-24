import SwiftUI

/// 资源库：Emby 媒体服务器。
struct LibraryView: View {
    /// 外部每次递增表示重复点了「资源库」标签，回到页面顶部。
    var reselectToken: Int = 0

    @State private var store = EmbyStore.shared
    @State private var isAddingServer = false
    @State private var path: [LibraryRoute] = []
    @State private var pendingDelete: EmbyServer?
    @State private var isEditing = false

    /// 每台服务器的电影 / 剧集数量探测结果。
    @State private var probes: [String: ServerProbe] = [:]

    private let columns = [
        GridItem(.flexible(), spacing: RexSpacing.md),
        GridItem(.flexible(), spacing: RexSpacing.md)
    ]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RexHubTitle(title: "资源库") {
                    headerActions
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: RexSpacing.xxl) {
                            serverSection
                        }
                        .id("libraryTop")
                        .padding(.horizontal, RexSpacing.xl)
                        .padding(.top, RexSpacing.xs)
                        .padding(.bottom, RexSpacing.huge)
                        .frame(maxWidth: RexLayout.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .refreshable {
                        await probeServers()
                    }
                    .onChange(of: reselectToken) { _, _ in
                        if !path.isEmpty {
                            path.removeAll()
                        }
                        withAnimation(RexMotion.standard) {
                            proxy.scrollTo("libraryTop", anchor: .top)
                        }
                    }
                }
            }
            .background(RexPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await probeServers()
            }
            .onChange(of: store.servers.count) { _, _ in
                Task { await probeServers() }
            }
            .navigationDestination(isPresented: $isAddingServer) {
                EmbyServerFormView()
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .server(let id):
                    if let server = store.servers.first(where: { $0.id == id }) {
                        EmbyServerDetailView(server: server)
                    }
                }
            }
            .confirmationDialog(
                "删除服务器",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let server = pendingDelete {
                        store.remove(server)
                        probes[server.id] = nil
                        RexHaptics.success()
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                if let server = pendingDelete {
                    Text("将移除「\(server.name)」，本机保存的登录信息一并删除。")
                }
            }
        }
    }

    // MARK: - 顶栏

    private var headerActions: some View {
        HStack(spacing: RexSpacing.xs) {
            if !store.servers.isEmpty {
                Button {
                    RexHaptics.tap()
                    withAnimation(RexMotion.quick) { isEditing.toggle() }
                } label: {
                    Text(isEditing ? "完成" : "编辑")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .padding(.horizontal, RexSpacing.lg)
                        .frame(minHeight: 38)
                        .background(RexColor.surface, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(isEditing ? "完成编辑" : "编辑媒体服务器")
            }

            Menu {
                Button {
                    RexHaptics.tap()
                    isAddingServer = true
                } label: {
                    Label {
                        Text("Emby")
                    } icon: {
                        Image("EmbyLogo")
                            .renderingMode(.original)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加服务器")
        }
    }

    // MARK: - 媒体服务器

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            sectionHeader("媒体服务器", detail: isEditing ? "点按卡片左上角移除" : nil)

            if store.servers.isEmpty {
                Text("请添加媒体库")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(
                        RexColor.field,
                        in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                            .strokeBorder(
                                RexColor.cardBorder,
                                style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                            )
                    }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: RexSpacing.md) {
                    ForEach(store.servers) { server in
                        LibraryServerCard(
                            server: server,
                            probe: probes[server.id] ?? .loading,
                            isEditing: isEditing,
                            onDelete: { pendingDelete = server }
                        ) {
                            path.append(.server(server.id))
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = server
                            } label: {
                                Label("删除服务器", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RexSpacing.sm) {
            Text(title)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(RexColor.primaryText)

            if let detail {
                Text(detail)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 数据

    private func probeServers() async {
        for server in store.servers {
            guard let client = store.client(for: server) else {
                probes[server.id] = .failed
                continue
            }

            if probes[server.id] == nil {
                probes[server.id] = .loading
            }

            do {
                probes[server.id] = .ready(try await client.counts(userID: server.userId))
            } catch {
                probes[server.id] = .failed
            }
        }
    }
}

// MARK: - 路由

enum LibraryRoute: Hashable {
    case server(String)
}

// MARK: - 卡片的辅助类型

/// 服务器探测状态：决定状态点颜色与数量文案。
private enum ServerProbe {
    case loading
    case ready(EmbyCounts)
    case failed
}

// MARK: - 服务器卡片

private struct LibraryServerCard: View {
    let server: EmbyServer
    let probe: ServerProbe
    let isEditing: Bool
    let onDelete: () -> Void
    let action: () -> Void

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                HStack(alignment: .top, spacing: RexSpacing.sm) {
                    iconTile

                    Spacer(minLength: 0)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                }

                Spacer(minLength: RexSpacing.xs)

                Text(server.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Text(lineText)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)

                Text(countText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
            }
            .padding(RexSpacing.lg)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .overlay(alignment: .topLeading) {
                if isEditing {
                    Button {
                        RexHaptics.tap()
                        onDelete()
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RexColor.error, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -7, y: -7)
                    .accessibilityLabel("删除服务器")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name)，\(lineText)，\(countText)")
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [RexColor.brandBlue, RexColor.brandBlue.opacity(0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: "server.rack")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: RexColor.brandBlue.opacity(0.26), radius: 6, y: 3)
    }

    private var statusColor: Color {
        switch probe {
        case .ready: return RexColor.success
        case .failed: return RexColor.warning
        case .loading: return RexColor.tertiaryText.opacity(0.45)
        }
    }

    /// 去掉 scheme，卡片里只留可读的地址。
    private var lineText: String {
        server.host
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private var countText: String {
        switch probe {
        case .ready(let counts):
            return "电影:\(counts.movies)  剧集:\(counts.series)"
        case .failed:
            return "未连接 · 点按查看"
        case .loading:
            return "正在同步…"
        }
    }
}

// MARK: - 服务器详情

/// 单个 Emby 服务器：展示连接与媒体库。
struct EmbyServerDetailView: View {
    let server: EmbyServer

    @State private var libraries: [EmbyLibrary] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        SettingsPage(title: server.name, onRefresh: { await load() }) {
            SettingsSection(title: "连接") {
                SettingsRow(icon: "link", title: "地址", value: server.host)

                SettingsDivider()

                SettingsRow(icon: "person", title: "用户", value: server.username)

                SettingsDivider()

                SettingsRow(icon: "clock", title: "最近连接", value: lastConnectedText)
            }

            librarySection

            RexNote(text: "媒体库来自 Emby 服务器。播放与详情页将在后续版本补齐。")
        }
        .task { await load() }
    }

    private var lastConnectedText: String {
        server.lastConnected.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var librarySection: some View {
        if isLoading {
            SettingsSection(title: "媒体库") {
                ForEach(0..<2, id: \.self) { _ in
                    RexSkeleton(width: .infinity, height: 44)
                }
            }
        } else if let errorText {
            RexStateCard(
                symbol: "wifi.exclamationmark",
                title: "媒体库加载失败",
                message: errorText,
                tone: .warning,
                actionTitle: "重试"
            ) {
                Task { await load() }
            }
        } else if libraries.isEmpty {
            RexStateCard(
                symbol: "rectangle.stack",
                title: "没有可展示的媒体库",
                message: "请在 Emby 服务器上创建媒体库后刷新。",
                tone: .neutral
            )
        } else {
            SettingsSection(title: "媒体库") {
                ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                    if index > 0 {
                        SettingsDivider()
                    }

                    SettingsRow(
                        icon: librarySymbol(for: library),
                        title: library.name,
                        value: libraryTypeText(for: library)
                    )
                }
            }
        }
    }

    private func librarySymbol(for library: EmbyLibrary) -> String {
        switch library.collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "homevideos": return "video"
        case "photos": return "photo"
        default: return "rectangle.stack"
        }
    }

    private func libraryTypeText(for library: EmbyLibrary) -> String {
        switch library.collectionType {
        case "movies": return "电影"
        case "tvshows": return "剧集"
        case "music": return "音乐"
        case "homevideos": return "家庭视频"
        case "photos": return "照片"
        default: return "媒体"
        }
    }

    private func load() async {
        guard let client = EmbyStore.shared.client(for: server) else {
            errorText = "服务器地址不正确"
            isLoading = false
            return
        }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            libraries = try await client.libraries(userID: server.userId)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "无法读取媒体库"
        }
    }
}
