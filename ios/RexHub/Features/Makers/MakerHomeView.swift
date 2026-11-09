import SwiftUI

/// 「片商」Tab：片商（AVDB）Hub。
///
/// 与 PWA 的 `/makers` 对齐：顶部「热播 / 类别 / 分类」切换，
/// 类别下按榜单 / 最新 / TOP250 分架，点海报进影片详情。
struct MakerHomeView: View {
    @Environment(\.apiClient) private var apiClient

    @AppStorage("rexhub.maker.category") private var categoryRaw = MakerCategory.censored.rawValue
    @State private var hubMode: MakerHubMode = .category
    @State private var path: [MakerRoute] = []
    @State private var rails: [String: MakerRailState] = [:]
    @State private var loadingIDs: Set<String> = []
    @State private var refreshToken = 0

    private var category: MakerCategory {
        MakerCategory(rawValue: categoryRaw) ?? .censored
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RexHubTitle(title: "片商") {
                    HStack(spacing: RexSpacing.sm) {
                        RexCircleIconButton(symbol: "person.2", label: "演员") {
                            path.append(.actors(category))
                        }

                        RexCircleIconButton(symbol: "clock.arrow.circlepath", label: "最近浏览") {
                            hubMode = .recent
                        }

                        RexCircleIconButton(symbol: "magnifyingglass", label: "搜索片商") {
                            path.append(.search)
                        }
                    }
                }

                RexPillTabs(
                    items: hubTabs,
                    selection: Binding(
                        get: { hubMode.tab(category: category) },
                        set: { tab in
                            switch tab {
                            case .playback:
                                hubMode = .playback
                            case .tags:
                                hubMode = .tags
                            case .recent:
                                hubMode = .recent
                            case .category(let next):
                                categoryRaw = next.rawValue
                                hubMode = .category
                            }
                        }
                    ),
                    title: { $0.title }
                )

                GeometryReader { proxy in
                    ScrollView {
                        content(width: min(proxy.size.width, RexLayout.contentMaxWidth))
                            .id(hubKey)
                            .padding(.top, RexSpacing.sm)
                            .padding(.bottom, RexSpacing.huge)
                            .frame(maxWidth: RexLayout.contentMaxWidth)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .refreshable { await refresh() }
                }
            }
            .background(RexPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MakerRoute.self) { route in
                switch route {
                case .search:
                    MakerSearchView()
                        .toolbar(.hidden, for: .navigationBar)
                case .list(let query):
                    MakerListView(query: query)
                        .toolbar(.hidden, for: .navigationBar)
                case .movie(let movie):
                    MakerMovieDetailView(movie: movie)
                        .toolbar(.hidden, for: .navigationBar)
                case .movieID(let id):
                    MakerMovieDetailView(movieID: id)
                        .toolbar(.hidden, for: .navigationBar)
                case .actors(let category):
                    MakerActorsView(category: category)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }

    private var hubTabs: [MakerHubTab] {
        [.playback] + MakerCategory.allCases.map { MakerHubTab.category($0) } + [.tags]
    }

    /// 切换 Hub 内容 / 类别时重建内容，避免沿用上一个列表的滚动位置。
    private var hubKey: String {
        switch hubMode {
        case .playback: "playback"
        case .tags: "tags-\(category.rawValue)"
        case .recent: "recent"
        case .category: "category-\(category.rawValue)"
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch hubMode {
        case .playback:
            playbackContent(width: width)
        case .tags:
            MakerTagsBody(category: category) { group, tag in
                path.append(.list(.tag(category, group: group.id, tagId: tag.id, name: tag.name)))
            }
        case .recent:
            MakerRecentViewedBody()
        case .category:
            categoryContent(width: width)
        }
    }

    private func playbackContent(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(MakerPeriod.allCases) { period in
                shelf(
                    key: "playback-\(period.rawValue)",
                    title: "热播·\(period.playbackTitle)",
                    load: { [period] in
                        let page = try await requireClient().makerPlayback(period: period)
                        return page.items
                    },
                    route: .list(.playback(period)),
                    posterWidth: posterWidth(for: width)
                )
            }
        }
    }

    private func categoryContent(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.xl) {
            if category.hasRank {
                ForEach(MakerPeriod.allCases) { period in
                    shelf(
                        key: "rank-\(category.rawValue)-\(period.rawValue)",
                        title: "\(period.title)·\(category.title)",
                        load: { [category, period] in
                            let page = try await requireClient().makerRank(category: category, period: period)
                            return page.items
                        },
                        route: .list(.rank(category, period)),
                        posterWidth: posterWidth(for: width)
                    )
                }
            }

            shelf(
                key: "latest-\(category.rawValue)",
                title: "最新·\(category.title)",
                load: { [category] in
                    let page = try await requireClient().makerLatest(category: category)
                    return page.items
                },
                route: .list(.latest(category)),
                posterWidth: posterWidth(for: width)
            )

            if category.hasRank {
                shelf(
                    key: "top-\(category.rawValue)",
                    title: "TOP250·\(category.title)",
                    load: { [category] in
                        let page = try await requireClient().makerTop(category: category)
                        return page.items
                    },
                    route: .list(.top(category)),
                    posterWidth: posterWidth(for: width)
                )
            }
        }
    }

    @ViewBuilder
    private func shelf(
        key: String,
        title: String,
        load: @escaping () async throws -> [MakerMovie],
        route: MakerRoute,
        posterWidth: CGFloat
    ) -> some View {
        let state = rails[key]

        VStack(alignment: .leading, spacing: 10) {
            MakerShelfHeader(title: title, onOpenAll: { path.append(route) })

            if let state, !state.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(state.items) { movie in
                            Button {
                                RexHaptics.tap()
                                path.append(.movie(movie))
                            } label: {
                                MakerMovieCard(movie: movie, width: posterWidth)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityHint("查看影片详情")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else if let error = state?.error, !error.isEmpty {
                RexInlineNotice(
                    title: "「\(title)」加载失败",
                    message: error,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task { await loadShelf(key: key, load: load, force: true) }
                }
                .padding(.horizontal, RexSpacing.xl)
            } else {
                MakerCardSkeletons(posterWidth: posterWidth)
                    .padding(.horizontal, RexSpacing.xl)
            }
        }
        .task(id: "\(key)-\(refreshToken)") {
            await loadShelf(key: key, load: load)
        }
    }

    private func posterWidth(for width: CGFloat) -> CGFloat {
        min(140, max(100, (width - RexSpacing.xl * 2 - 20) / 3))
    }

    // MARK: - 数据

    private func requireClient() throws -> APIClient {
        guard let apiClient else { throw APIError.unauthorized }
        return apiClient
    }

    private func loadShelf(
        key: String,
        load: @escaping () async throws -> [MakerMovie],
        force: Bool = false
    ) async {
        if !force, rails[key]?.loaded == true { return }
        guard loadingIDs.insert(key).inserted else { return }
        defer { loadingIDs.remove(key) }

        if rails[key] == nil {
            rails[key] = MakerRailState()
        }
        rails[key]?.error = nil

        do {
            let items = try await load()
            rails[key] = MakerRailState(items: items, loaded: true)
        } catch {
            if isCancelled(error) { return }
            rails[key] = MakerRailState(loaded: true, error: error.localizedDescription)
        }
    }

    private func refresh() async {
        refreshToken += 1
        rails = [:]
        loadingIDs = []
    }

    private func isCancelled(_ error: Error) -> Bool {
        if let apiError = error as? APIError { return apiError == .cancelled }
        return error is CancellationError
    }
}

// MARK: - Hub Tab

private enum MakerHubMode {
    case playback
    case category
    case tags
    case recent

    func tab(category: MakerCategory) -> MakerHubTab {
        switch self {
        case .playback: .playback
        case .category: .category(category)
        case .tags: .tags
        // 最近浏览是顶栏图标进入的临时视图，不占顶部分类 tab。
        case .recent: .recent
        }
    }
}

private enum MakerHubTab: Hashable {
    case playback
    case category(MakerCategory)
    case tags
    case recent

    var title: String {
        switch self {
        case .playback: "热播"
        case .category(let category): category.title
        case .tags: "分类"
        case .recent: "最近浏览"
        }
    }
}

struct MakerRailState {
    var items: [MakerMovie] = []
    var loaded = false
    var error: String?
}
