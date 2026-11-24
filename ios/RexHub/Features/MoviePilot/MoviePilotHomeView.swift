import SwiftUI
import UIKit

// MARK: - 路由

enum MpRoute: Hashable {
    case detail(MpItem)
    case search
    /// 货架「全部」进入的榜单列表页。
    case chart(MoviePilotShelf)
    case person(MpPersonRef)
}

/// 影人页入参：`GET /moviepilot/person` 需要一个 `source`，而演员列表项里没有。
struct MpPersonRef: Hashable {
    let source: String
    let id: String
    let name: String
    let avatarUrl: String?
}

// MARK: - 海报墙入口

/// 「海报墙」入口内可切换的两个页面。
enum PosterWallSection: String, CaseIterable, Identifiable {
    case media
    case makers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: "影视"
        case .makers: "片商"
        }
    }

    /// 生成顶栏下拉菜单项；未注入绑定（单独使用时）返回空数组，标题保持纯文本。
    static func menuOptions(for section: Binding<PosterWallSection>?) -> [RexHubMenuOption] {
        guard let section else { return [] }
        return allCases.map { item in
            RexHubMenuOption(
                id: item.rawValue,
                title: item.title,
                isSelected: section.wrappedValue == item
            ) {
                section.wrappedValue = item
            }
        }
    }
}

/// 合并后的「海报墙」：顶栏标题下拉切换「影视 / 片商」，两页各自保留导航栈与滚动位置。
struct PosterWallHomeView: View {
    var reselectToken: Int = 0

    @AppStorage("rexhub.posterwall.section") private var sectionRaw = PosterWallSection.media.rawValue
    /// 已打开过的页面，避免首次进入时两个页面同时请求数据。
    @State private var visited: Set<PosterWallSection> = []

    private var section: PosterWallSection {
        PosterWallSection(rawValue: sectionRaw) ?? .media
    }

    private var sectionBinding: Binding<PosterWallSection> {
        Binding(
            get: { section },
            set: { next in
                guard next != section else { return }
                visited.insert(section)
                RexHaptics.selection()
                withAnimation(RexMotion.standard) {
                    sectionRaw = next.rawValue
                }
            }
        )
    }

    var body: some View {
        ZStack {
            if section == .media || visited.contains(.media) {
                MoviePilotHomeView(reselectToken: reselectToken, section: sectionBinding)
                    .opacity(section == .media ? 1 : 0)
                    .allowsHitTesting(section == .media)
                    .accessibilityHidden(section != .media)
            }

            if section == .makers || visited.contains(.makers) {
                MakerHomeView(reselectToken: reselectToken, section: sectionBinding)
                    .opacity(section == .makers ? 1 : 0)
                    .allowsHitTesting(section == .makers)
                    .accessibilityHidden(section != .makers)
            }
        }
        .onAppear { visited.insert(section) }
    }
}

// MARK: - 影视首页（MoviePilot）

struct MoviePilotHomeView: View {
    /// 外部每次递增表示重复点了「影视」标签，回到页面顶部。
    var reselectToken: Int = 0
    /// 与「片商」合并后由「海报墙」容器注入，用于顶栏下拉切换。
    var section: Binding<PosterWallSection>? = nil

    @Environment(\.apiClient) private var apiClient
    @AppStorage("rexhub.mp.tab") private var tabRaw = MoviePilotTab.movie.rawValue

    @State private var path: [MpRoute] = []
    @State private var rails: [String: MpRailState] = [:]
    @State private var loadingIDs: Set<String> = []
    @State private var refreshToken = 0

    private var tab: MoviePilotTab {
        MoviePilotTab(rawValue: tabRaw) ?? .movie
    }

    private var titleMenuOptions: [RexHubMenuOption] {
        PosterWallSection.menuOptions(for: section)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RexHubTitle(title: section?.wrappedValue.title ?? "影视", menuOptions: titleMenuOptions) {
                    RexCircleIconButton(symbol: "magnifyingglass", label: "搜索影视") {
                        path.append(.search)
                    }
                }

                RexPillTabs(
                    items: MoviePilotTab.allCases,
                    selection: Binding(
                        get: { tab },
                        set: { tabRaw = $0.rawValue }
                    ),
                    title: { $0.title }
                )

                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if tab == .explore {
                                MpExploreView()
                            } else {
                                railsSection(width: min(UIScreen.main.bounds.width, RexLayout.contentMaxWidth))
                                    .padding(.top, RexSpacing.sm)
                            }
                        }
                        .id("mpHomeTop")
                        .padding(.bottom, RexSpacing.huge)
                        .frame(maxWidth: RexLayout.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .refreshable { await refresh() }
                    .onChange(of: reselectToken) { _, _ in
                        if !path.isEmpty {
                            path.removeAll()
                        }
                        withAnimation(RexMotion.standard) {
                            proxy.scrollTo("mpHomeTop", anchor: .top)
                        }
                    }
                }
            }
            .background(RexPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MpRoute.self) { route in
                switch route {
                case .detail(let item):
                    MpDetailView(item: item)
                        .rexPushedScreen()
                case .search:
                    MpSearchView()
                        .rexPushedScreen()
                case .chart(let shelf):
                    MpChartView(shelf: shelf)
                        .rexPushedScreen()
                case .person(let person):
                    MpPersonView(person: person)
                        .rexPushedScreen()
                }
            }
        }
    }

    @ViewBuilder
    private func railsSection(width: CGFloat) -> some View {
        // 一屏三张，整体尺寸再缩 20%，让下一张露出提示可横滑。
        let posterWidth = min(140, max(100, (width - RexSpacing.xl * 2 - 20) / 3)) * 0.8

        LazyVStack(alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(tab.shelves) { shelf in
                let state = rails[shelf.id]

                VStack(alignment: .leading, spacing: 10) {
                    MakerShelfHeader(title: shelf.title, onOpenAll: { path.append(.chart(shelf)) })
                        .padding(.horizontal, RexSpacing.xl)

                    if let state, !state.items.isEmpty {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(state.items.prefix(12)) { item in
                                    NavigationLink(value: MpRoute.detail(item)) {
                                        MpPosterCard(item: item, width: posterWidth)
                                    }
                                    .buttonStyle(PressableButtonStyle())
                                }
                            }
                            // 左留页面边距，右侧不留白，货架可以贴边划出。
                            .padding(.leading, RexSpacing.xl)
                            .padding(.trailing, 0)
                        }
                        .scrollIndicators(.hidden)
                    } else if let error = state?.error, !error.isEmpty {
                        RexInlineNotice(
                            title: "「\(shelf.title)」加载失败",
                            message: error,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await load(shelf, force: true) }
                        }
                        .padding(.horizontal, RexSpacing.xl)
                    } else {
                        MakerCardSkeletons(posterWidth: posterWidth)
                            .padding(.leading, RexSpacing.xl)
                    }
                }
                .task(id: "\(shelf.id)-\(refreshToken)") {
                    await load(shelf)
                }
            }
        }
    }

    // MARK: - 数据

    private func load(_ shelf: MoviePilotShelf, force: Bool = false) async {
        guard let apiClient else { return }
        if !force, rails[shelf.id]?.loaded == true { return }
        guard loadingIDs.insert(shelf.id).inserted else { return }
        defer { loadingIDs.remove(shelf.id) }

        do {
            let result = try await apiClient.mpList(path: shelf.path, params: shelf.params)
            rails[shelf.id] = MpRailState(items: result.items, loaded: true)
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            rails[shelf.id] = MpRailState(loaded: true, error: error.localizedDescription)
        }
    }

    private func refresh() async {
        refreshToken += 1
        rails = [:]
        loadingIDs = []
    }
}

struct MpRailState {
    var items: [MpItem] = []
    var loaded = false
    var error: String?
}

// MARK: - 海报卡

struct MpPosterCard: View {
    let item: MpItem
    var width: CGFloat?

    private let radius = RexRadius.control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    MpArtwork(url: item.posterUrl)
                }
                .overlay { PosterBottomShade() }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .overlay(alignment: .topLeading) {
                    MakerBadge(text: item.categoryMark, tint: Color.black.opacity(0.55))
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if let rating = item.rating, rating > 0 {
                        MakerBadge(
                            text: String(format: "%.1f", rating),
                            tint: Color(hex: 0xF5C518),
                            foreground: Color(hex: 0x1A1200)
                        )
                        .padding(6)
                    }
                }
                .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
                .shadow(color: Color.black.opacity(0.10), radius: 24, y: 8)

            Text(item.title)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}

struct MpArtwork: View {
    let url: String?
    var fallbackSymbol: String = "film"
    /// 铺底等大面积模糊场景关掉转圈，避免加载时中间出现亮斑。
    var showsProgress: Bool = true

    @Environment(\.apiClient) private var apiClient
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(RexColor.field)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if failed {
                Image(systemName: fallbackSymbol)
                    .font(.system(.title2, weight: .light))
                    .foregroundStyle(RexColor.tertiaryText)
            } else if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(RexColor.tertiaryText)
            }
        }
        .clipped()
        .animation(RexMotion.standard, value: image != nil)
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        // 外站封面统一经服务端代理，豆瓣等图床会拒绝客户端直连。
        guard let url, let target = apiClient?.mediaCoverURL(raw: url) else {
            failed = true
            return
        }
        if let hit = MakerImageStore.shared.cached(target) {
            image = hit
            failed = false
            return
        }
        let loaded = await MakerImageStore.shared.image(for: target, bearerToken: apiClient?.token)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

// MARK: - 搜索

struct MpSearchView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var submitted = ""
    @State private var source = "tmdb"
    @State private var items: [MpItem] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @FocusState private var isFocused: Bool

    private let sources = [
        ("tmdb", "TMDB"),
        ("douban", "豆瓣"),
        ("bangumi", "Bangumi"),
        ("anilist", "AniList")
    ]

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "搜索影视",
                leading: .back(action: { dismiss() }),
                isScrolled: true
            )

            HStack(spacing: RexSpacing.sm) {
                Menu {
                    ForEach(sources, id: \.0) { item in
                        Button {
                            guard source != item.0 else { return }
                            RexHaptics.selection()
                            source = item.0
                            if !submitted.isEmpty { Task { await search() } }
                        } label: {
                            if source == item.0 {
                                Label(item.1, systemImage: "checkmark")
                            } else {
                                Text(item.1)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sourceLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(RexColor.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RexColor.field, in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
                }
                .fixedSize()
                .accessibilityLabel("数据源")

                TextField("片名、剧名或演员", text: $keyword)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                    .onSubmit { Task { await search() } }

                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        items = []
                        submitted = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.subheadline))
                            .foregroundStyle(RexColor.tertiaryText)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RexSpacing.md)
            .frame(height: 44)
            .background(RexColor.surface, in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    .strokeBorder(RexColor.fieldBorder, lineWidth: 0.75)
            }
            .padding(.horizontal, RexSpacing.xl)

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    if isLoading, items.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in
                            RexSkeleton(width: .infinity, height: 90, cornerRadius: RexRadius.card)
                        }
                    } else if let errorText, items.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "搜索失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await search() }
                        }
                    } else if items.isEmpty {
                        RexStateCard(
                            symbol: "film",
                            title: submitted.isEmpty ? "搜索影视" : "没有找到结果",
                            message: submitted.isEmpty ? "输入片名或剧名后回车。" : "换个数据源或关键词试试。",
                            tone: .neutral
                        )
                    } else {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md, alignment: .top), count: 3),
                            alignment: .leading,
                            spacing: RexSpacing.xl
                        ) {
                            ForEach(items) { item in
                                NavigationLink(value: MpRoute.detail(item)) {
                                    MpPosterCard(item: item)
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .onAppear { isFocused = true }
    }

    private var sourceLabel: String {
        sources.first(where: { $0.0 == source })?.1 ?? "TMDB"
    }

    private func search() async {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let apiClient, !isLoading else { return }
        isLoading = true
        errorText = nil
        submitted = value
        defer { isLoading = false }

        do {
            let result = try await apiClient.mpMediaSearch(source: source, keyword: value)
            items = result.items
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}
