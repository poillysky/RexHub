import SwiftUI
import WebKit

/// 外观主题：应用主题 / 标题风格 / 导航栏行为 / 品牌色，全部即时生效。
struct AppearanceSettingsView: View {
    private let theme = RexThemeStore.shared

    var body: some View {
        SettingsPage(title: "外观主题") {
            SettingsCard {
                menuRow(
                    title: "应用主题",
                    options: RexAppearance.allCases,
                    label: \.title,
                    selection: Binding(
                        get: { theme.appearance },
                        set: { theme.appearance = $0 }
                    )
                )

                SettingsDivider()

                menuRow(
                    title: "标题风格",
                    options: RexTitleStyle.allCases,
                    label: \.title,
                    selection: Binding(
                        get: { theme.titleStyle },
                        set: { theme.titleStyle = $0 }
                    )
                )

                SettingsDivider()

                SettingsLink(title: "图标库", value: librarySummary) {
                    IconLibraryView()
                }
            }

            SettingsSection(title: "导航栏") {
                toggleRow(
                    title: "滑动时收缩导航栏",
                    isOn: Binding(
                        get: { theme.collapseNavOnScroll },
                        set: { theme.collapseNavOnScroll = $0 }
                    )
                )

                SettingsDivider()

                toggleRow(
                    title: "显示导航栏名称",
                    isOn: Binding(
                        get: { theme.showNavTitle },
                        set: { theme.showNavTitle = $0 }
                    )
                )
            }

            SettingsSection(title: "主题颜色") {
                colorRow
            }

            SettingsSection(title: "Logo") {
                logoRow
            }
        }
    }

    private var librarySummary: String {
        let urls = theme.iconLibraryURLs
        guard let first = urls.first else { return "未配置" }
        guard urls.count == 1 else { return "\(urls.count) 个" }
        return iconLibraryName(for: first)
    }

    // MARK: - 行

    private func menuRow<T: Hashable & Identifiable>(
        title: String,
        options: [T],
        label: KeyPath<T, String>,
        selection: Binding<T>
    ) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option[keyPath: label]).tag(option)
                }
            }
        } label: {
            HStack(spacing: RexSpacing.sm) {
                Text(title)
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: RexSpacing.sm)

                Text(selection.wrappedValue[keyPath: label])
                    .font(RexFont.rowValue)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: RexLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RexRowButtonStyle())
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: RexSpacing.md) {
            Text(title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(RexColor.brandBlue)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
    }

    private var colorRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 44), spacing: RexSpacing.sm)],
            spacing: RexSpacing.sm
        ) {
            ForEach(RexBrandColor.allCases) { option in
                Button {
                    RexHaptics.selection()
                    withAnimation(RexMotion.spring) {
                        theme.brandColor = option
                    }
                } label: {
                    ZStack {
                        if option == theme.brandColor {
                            Circle()
                                .strokeBorder(option.color.opacity(0.35), lineWidth: 3)
                                .frame(width: 44, height: 44)
                                .transition(.scale.combined(with: .opacity))
                        }

                        Circle()
                            .fill(option.color)
                            .frame(width: 34, height: 34)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
                            }
                            .shadow(color: option.color.opacity(0.26), radius: 4, y: 2)

                        if option == theme.brandColor {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(RexColor.onBrand)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(option == theme.brandColor ? .isSelected : [])
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .animation(RexMotion.spring, value: theme.brandColor)
    }

    /// 四列网格：目前只有一套 Logo，补素材后追加 `RexLogoStyle` 即可自动排开。
    private var logoRow: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: RexSpacing.md),
                count: 4
            ),
            spacing: RexSpacing.md
        ) {
            ForEach(RexLogoStyle.allCases) { option in
                Button {
                    RexHaptics.selection()
                    withAnimation(RexMotion.quick) {
                        theme.logoStyle = option
                    }
                } label: {
                    Image(option.imageName)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    theme.logoStyle == option ? RexColor.brandBlue : RexColor.divider,
                                    lineWidth: theme.logoStyle == option ? 2 : 1
                                )
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if theme.logoStyle == option {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(RexColor.onBrand, RexColor.brandBlue)
                                    .padding(4)
                            }
                        }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(theme.logoStyle == option ? .isSelected : [])
            }
        }
        .padding(RexSpacing.lg)
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
            .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 图标库

/// 图标库：配置保存在服务端，App 只负责增删；本地 `UserDefaults` 作离线缓存。
private struct IconLibraryView: View {
    @Environment(\.apiClient) private var apiClient

    private let theme = RexThemeStore.shared

    @State private var draft = ""
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var previewing: IconLibraryTarget?
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBusy: Bool { isLoading || isSaving }

    private var canAdd: Bool { !trimmed.isEmpty && !isBusy }

    var body: some View {
        SettingsPage(title: "图标库") {
            SettingsCard {
                HStack(spacing: RexSpacing.md) {
                    Image(systemName: "link")
                        .font(.system(size: 17))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(width: 28)

                    TextField("https://github.com/owner/repo", text: $draft)
                        .font(RexFont.body)
                        .foregroundStyle(RexColor.primaryText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }

                    Button("添加") {
                        RexHaptics.tap()
                        Task { await add() }
                    }
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(canAdd ? RexColor.brandBlue : RexColor.tertiaryText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(!canAdd)
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(minHeight: RexLayout.rowHeight)
            }

            if isLoading && theme.iconLibraryURLs.isEmpty {
                SettingsCard {
                    HStack(spacing: RexSpacing.sm) {
                        ProgressView()
                            .controlSize(.small)

                        Text("正在读取服务端配置…")
                            .font(RexFont.subheadline)
                            .foregroundStyle(RexColor.secondaryText)
                    }
                    .padding(.horizontal, RexSpacing.lg)
                    .frame(minHeight: RexLayout.rowHeight)
                }
            }

            if !theme.iconLibraryURLs.isEmpty {
                SettingsCard {
                    ForEach(theme.iconLibraryURLs, id: \.self) { url in
                        libraryRow(url)

                        if url != theme.iconLibraryURLs.last {
                            SettingsDivider()
                        }
                    }
                }
            }

            if let errorText {
                RexNote(text: errorText, tone: .error)
            }

            RexNote(text: "配置保存在服务端，所有设备共用一份；列表为空表示不使用在线图标库。")
        }
        .task { await load() }
        .sheet(item: $previewing) { target in
            IconLibraryPreviewSheet(target: target)
                .rexSheetStyle()
        }
    }

    private func libraryRow(_ url: String) -> some View {
        let kind = IconLibraryKind(url: url)

        return HStack(spacing: RexSpacing.xs) {
            Button {
                previewing = IconLibraryTarget(url: url, kind: kind)
            } label: {
                HStack(spacing: RexSpacing.md) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(width: 34, height: 34)
                        .background(
                            RexColor.brandBlue.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(iconLibraryName(for: url))
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(RexColor.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(kind.summary)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: RexSpacing.xs)

                    if kind.hasPreview {
                        Image(systemName: "eye")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(RexColor.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isBusy)
            .accessibilityLabel("预览 \(iconLibraryName(for: url))")

            Button {
                RexHaptics.warning()
                Task { await remove(url) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isBusy)
            .accessibilityLabel("删除 \(url)")
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
    }

    private func load() async {
        guard let client = apiClient else {
            errorText = "登录状态已失效，请重新登录"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            theme.iconLibraryURLs = try await client.iconLibraries()
            errorText = nil
        } catch {
            // 拉取失败时保留本地缓存，离线也能看到上次的配置。
            guard (error as? APIError) != .cancelled else { return }
            errorText = (error as? LocalizedError)?.errorDescription ?? "读取失败，请重试"
        }
    }

    private func add() async {
        guard canAdd else { return }

        guard isValidLink(trimmed) else {
            errorText = "请输入以 http 或 https 开头的完整链接"
            return
        }

        guard !theme.iconLibraryURLs.contains(trimmed) else {
            errorText = "该链接已在列表中"
            return
        }

        let next = theme.iconLibraryURLs + [trimmed]
        draft = ""
        isFocused = false
        await save(next)
    }

    private func remove(_ url: String) async {
        guard !isBusy else { return }
        await save(theme.iconLibraryURLs.filter { $0 != url })
    }

    /// 先本地更新，再以服务端返回为准；失败回滚并提示。
    private func save(_ urls: [String]) async {
        guard let client = apiClient else {
            errorText = "登录状态已失效，请重新登录"
            return
        }

        let previous = theme.iconLibraryURLs
        withAnimation(.easeOut(duration: 0.15)) {
            theme.iconLibraryURLs = urls
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let saved = try await client.updateIconLibraries(urls)
            withAnimation(.easeOut(duration: 0.15)) {
                theme.iconLibraryURLs = saved
            }
            errorText = nil
        } catch {
            withAnimation(.easeOut(duration: 0.15)) {
                theme.iconLibraryURLs = previous
            }
            errorText = (error as? LocalizedError)?.errorDescription ?? "保存失败，请重试"
        }
    }
}

/// 列表与入口共用的显示名：优先展示仓库路径，没有路径时退回域名。
private func iconLibraryName(for urlString: String) -> String {
    guard let url = URL(string: urlString) else { return urlString }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path.isEmpty ? (url.host ?? urlString) : path
}

private func isValidLink(_ value: String) -> Bool {
    guard
        let url = URL(string: value),
        let scheme = url.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        url.host != nil
    else { return false }
    return true
}

// MARK: - 图标库预览

/// 内置预览规格，与 PWA 端的图标库预览保持一致。
private enum IconLibraryKind {
    case hdIcons
    case dashboardIcons
    case developerIcons
    case flatColorIcons
    case fluentEmoji
    case notoEmoji
    case openmoji
    case logos
    case unsupported

    init(url urlString: String) {
        let value = urlString.lowercased()

        if value.contains("hd-icons") || value.contains("xushier") {
            self = .hdIcons
        } else if value.contains("dashboard-icons") || value.contains("homarr") {
            self = .dashboardIcons
        } else if value.contains("developer-icons") || value.contains("xandemon") {
            self = .developerIcons
        } else if value.contains("flat-color-icons") {
            self = .flatColorIcons
        } else if value.contains("fluent-emoji-flat") {
            self = .fluentEmoji
        } else if value.contains("openmoji") {
            self = .openmoji
        } else if value.contains("noto") {
            self = .notoEmoji
        } else if value.contains("logos") {
            self = .logos
        } else {
            self = .unsupported
        }
    }

    /// 行内展示的一句话说明。
    var summary: String {
        switch self {
        case .hdIcons: return "影视 / 网盘服务图标 · PNG"
        case .dashboardIcons: return "Homarr 服务图标集 · SVG"
        case .developerIcons: return "开发语言与技术栈 · SVG"
        case .flatColorIcons: return "彩色扁平通用图标 · SVG"
        case .fluentEmoji: return "微软 Fluent 表情图标 · SVG"
        case .notoEmoji: return "Google Noto 表情图标 · SVG"
        case .openmoji: return "开源彩色表情图标 · SVG"
        case .logos: return "品牌与技术 Logo · SVG"
        case .unsupported: return "自定义图标库 · 暂不支持预览"
        }
    }

    var hasPreview: Bool { self != .unsupported }

    var samples: [String] {
        switch self {
        case .hdIcons:
            return ["115-drive-1", "baidu-drive-1", "onedrive-1", "google-drive-1", "quark-1", "alist-1",
                    "nextcloud-1", "seafile-1", "synology-1", "truenas-1", "docker-1", "jellyfin-1"]
        case .dashboardIcons:
            return ["docker", "nextcloud", "plex", "jellyfin", "synology", "truenas",
                    "alist", "immich", "qbittorrent", "portainer", "home-assistant", "google-drive"]
        case .developerIcons:
            return ["docker", "python", "swift", "nodejs", "reactjs", "typescript",
                    "go", "java", "php", "ruby", "kotlin"]
        case .flatColorIcons:
            return ["home", "search", "settings", "like", "folder", "calendar",
                    "download", "camera", "globe", "lock", "phone", "support"]
        case .fluentEmoji, .notoEmoji, .openmoji:
            return ["grinning-face", "red-heart", "star", "fire", "rocket", "party-popper",
                    "artist-palette", "light-bulb", "check-mark-button", "warning", "bell", "calendar"]
        case .logos:
            return ["github-icon", "google-icon", "apple", "figma", "docker-icon", "react",
                    "swift", "vue", "python", "java", "chrome", "nodejs-icon"]
        case .unsupported:
            return []
        }
    }

    func iconURL(name: String) -> String {
        switch self {
        case .hdIcons:
            return "https://gcore.jsdelivr.net/gh/xushier/HD-Icons@main/border-radius/\(name).png"
        case .dashboardIcons:
            return "https://gcore.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/\(name).svg"
        case .developerIcons:
            return "https://gcore.jsdelivr.net/gh/xandemon/developer-icons@main/icons/\(name).svg"
        case .flatColorIcons:
            return "https://api.iconify.design/flat-color-icons/\(name).svg"
        case .fluentEmoji:
            return "https://api.iconify.design/fluent-emoji-flat/\(name).svg"
        case .notoEmoji:
            return "https://api.iconify.design/noto/\(name).svg"
        case .openmoji:
            return "https://api.iconify.design/openmoji/\(name).svg"
        case .logos:
            return "https://api.iconify.design/logos/\(name).svg"
        case .unsupported:
            return ""
        }
    }
}

private struct IconLibraryTarget: Identifiable {
    let url: String
    let kind: IconLibraryKind

    var id: String { url }
}

/// 图标预览：内置示例图标网格，未知图标库给出说明而不是空白。
private struct IconLibraryPreviewSheet: View {
    let target: IconLibraryTarget

    @Environment(\.dismiss) private var dismiss

    private let columns = 4

    private var rows: Int {
        max(1, (target.kind.samples.count + columns - 1) / columns)
    }

    private var gridHeight: CGFloat {
        CGFloat(rows) * 76 + RexSpacing.xxxl
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iconLibraryName(for: target.url))
                            .font(.system(.headline, weight: .semibold))
                            .foregroundStyle(RexColor.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(target.kind.summary)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                    }

                    if target.kind.hasPreview {
                        IconGridWebView(kind: target.kind, samples: target.kind.samples)
                            .frame(height: gridHeight)
                            .background(
                                RexColor.surface,
                                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                                    .strokeBorder(RexColor.divider, lineWidth: 1)
                            }

                        RexNote(text: "预览为内置示例图标，实际使用时由服务端按库内全部图标自动匹配。")
                    } else {
                        RexStateCard(
                            symbol: "eye.slash",
                            title: "暂不支持预览该图标库",
                            message: "仍可作为图标源使用，服务端会按文件名自动匹配。",
                            tone: .neutral
                        )
                    }

                    Text(target.url)
                        .font(RexFont.monoSmall)
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(RexSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RexPageBackground())
            .navigationTitle("图标预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(.subheadline, weight: .semibold))
                }
            }
        }
        .rexSheetStyle()
    }
}

/// 图标库大量为 SVG，`AsyncImage` 无法直接渲染，这里用 `WKWebView` 画网格。
private struct IconGridWebView: UIViewRepresentable {
    let kind: IconLibraryKind
    let samples: [String]

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private var html: String {
        let cells = samples.map { name in
            """
            <figure><img src="\(kind.iconURL(name: name))" alt=""><figcaption>\(name)</figcaption></figure>
            """
        }.joined()

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html, body { margin: 0; background: transparent; }
        body { font-family: -apple-system, "PingFang SC", sans-serif; -webkit-font-smoothing: antialiased; }
        .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px 10px; padding: 16px 14px; }
        figure { margin: 0; display: flex; flex-direction: column; align-items: center; gap: 6px; }
        img { width: 42px; height: 42px; object-fit: contain; }
        figcaption { max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 9.5px; color: #8B8F98; }
        @media (prefers-color-scheme: dark) { figcaption { color: #8B93A1; } }
        </style>
        </head>
        <body><div class="grid">\(cells)</div></body>
        </html>
        """
    }
}
