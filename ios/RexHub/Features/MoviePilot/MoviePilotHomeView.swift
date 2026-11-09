import SwiftUI

// MARK: - 路由

enum MpRoute: Hashable {
    case detail(MpItem)
    case search
}

// MARK: - 影视首页（MoviePilot）

struct MoviePilotHomeView: View {
    @Environment(\.apiClient) private var apiClient
    @AppStorage("rexhub.mp.tab") private var tabRaw = MoviePilotTab.movie.rawValue

    @State private var path: [MpRoute] = []
    @State private var rails: [String: MpRailState] = [:]
    @State private var loadingIDs: Set<String> = []
    @State private var refreshToken = 0

    private var tab: MoviePilotTab {
        MoviePilotTab(rawValue: tabRaw) ?? .movie
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RexHubTitle(title: "影视") {
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

                ScrollView {
                    Group {
                        if tab == .explore {
                            MpExploreView()
                        } else {
                            railsSection(width: min(UIScreen.main.bounds.width, RexLayout.contentMaxWidth))
                                .padding(.top, RexSpacing.sm)
                        }
                    }
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await refresh() }
            }
            .background(RexPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MpRoute.self) { route in
                switch route {
                case .detail(let item):
                    MpDetailView(item: item)
                        .toolbar(.hidden, for: .navigationBar)
                case .search:
                    MpSearchView()
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }

    @ViewBuilder
    private func railsSection(width: CGFloat) -> some View {
        let posterWidth = min(140, max(100, (width - RexSpacing.xl * 2 - 20) / 3))

        LazyVStack(alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(tab.shelves) { shelf in
                let state = rails[shelf.id]

                VStack(alignment: .leading, spacing: 10) {
                    MakerShelfHeader(title: shelf.title)

                    if let state, !state.items.isEmpty {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(state.items) { item in
                                    NavigationLink(value: MpRoute.detail(item)) {
                                        MpPosterCard(item: item, width: posterWidth)
                                    }
                                    .buttonStyle(PressableButtonStyle())
                                }
                            }
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
                    } else {
                        MakerCardSkeletons(posterWidth: posterWidth)
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    MpArtwork(url: item.posterUrl)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .overlay(alignment: .topLeading) {
                    if let rating = item.rating {
                        MakerBadge(text: String(format: "%.1f", rating), tint: Color(hex: 0xFFC93C))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let year = item.year, !year.isEmpty {
                        MakerBadge(text: year, tint: Color.black.opacity(0.55))
                            .padding(6)
                    }
                }
                .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)

            Text(item.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
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

    var body: some View {
        ZStack {
            Rectangle().fill(RexColor.field)

            if let url, let value = URL(string: url) {
                AsyncImage(url: value) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: fallbackSymbol)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(RexColor.tertiaryText)
                    default:
                        ProgressView()
                            .controlSize(.small)
                            .tint(RexColor.tertiaryText)
                    }
                }
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(RexColor.tertiaryText)
            }
        }
        .clipped()
        .accessibilityHidden(true)
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
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)

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
                            .font(.system(size: 15))
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

            sourceChips
                .padding(.top, RexSpacing.sm)

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
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isFocused = true }
    }

    private var sourceChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                ForEach(sources, id: \.0) { item in
                    let selected = source == item.0
                    Button {
                        guard !selected else { return }
                        RexHaptics.selection()
                        source = item.0
                        if !submitted.isEmpty { Task { await search() } }
                    } label: {
                        Text(item.1)
                            .font(.system(.footnote, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? RexColor.onBrand : RexColor.secondaryText)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(height: 30)
                            .background(
                                selected ? AnyShapeStyle(RexColor.brandGradient) : AnyShapeStyle(RexColor.surface),
                                in: Capsule(style: .continuous)
                            )
                            .overlay {
                                if !selected {
                                    Capsule(style: .continuous)
                                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                                }
                            }
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, RexSpacing.xl)
        }
        .scrollIndicators(.hidden)
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
