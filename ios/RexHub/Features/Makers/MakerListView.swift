import SwiftUI

/// 片商列表：榜单 / 最新 / TOP250 / 搜索结果，统一分页网格。
struct MakerListView: View {
    let query: MakerListQuery

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var movies: [MakerMovie] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isScrolled = false
    /// 请求代号：切换年份等重置操作会自增，用于丢弃旧请求的返回。
    @State private var loadGeneration = 0
    /// TOP250 年份筛选；空串表示「年份不限」。
    @State private var year = ""
    @State private var years: [String] = []

    /// 是否为 TOP250 榜单页（只有它带年份下拉）。
    private var isTopList: Bool {
        if case .top = query { return true }
        return false
    }

    private var navTitle: String {
        guard case .top = query, !year.isEmpty else { return query.title }
        return "TOP250·\(year)"
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: navTitle,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled,
                trailing: isTopList ? AnyView(yearPill) : nil
            )

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    if movies.isEmpty, isLoading {
                        MakerCardSkeletons(posterWidth: 170, count: 2, aspect: 16 / 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let errorText, movies.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "加载失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await load(reset: true) }
                        }
                    } else if movies.isEmpty {
                        RexStateCard(
                            symbol: "film",
                            title: "暂无内容",
                            message: "换个类别或稍后再试。",
                            tone: .neutral
                        )
                    } else {
                        MakerMovieGrid(movies: movies, columnCount: 2)

                        if hasMore {
                            loadMoreFooter
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "makerListScroll"))
            }
            .rexScrollTracking("makerListScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load(reset: true) }
            // 从影片详情返回时保留已加载内容与滚动位置，不重新翻页。
            .task { if movies.isEmpty { await load(reset: true) } }
            .task { await loadYears() }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
    }

    /// 顶栏右侧的年份下拉胶囊（对齐 PWA `.maker-year-pill`）。
    private var yearPill: some View {
        Menu {
            Button("年份不限") { selectYear("") }
            ForEach(years, id: \.self) { value in
                Button(value) { selectYear(value) }
            }
        } label: {
            HStack(spacing: 2) {
                Text(year.isEmpty ? "年份不限" : year)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(RexColor.secondaryText)
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(RexColor.field)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(height: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("年份")
    }

    private func selectYear(_ value: String) {
        guard value != year else { return }
        year = value
        movies = []
        page = 1
        hasMore = true
        errorText = nil
        Task { await load(reset: true) }
    }

    private func loadYears() async {
        guard isTopList, years.isEmpty, let apiClient else { return }
        years = (try? await apiClient.makerYears()) ?? []
    }

    private var loadMoreFooter: some View {
        HStack(spacing: RexSpacing.sm) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载更多")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
            } else {
                Button {
                    Task { await load(reset: false) }
                } label: {
                    Text("加载更多")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minWidth: 120, minHeight: 44)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !isLoading, hasMore else { return }
            Task { await load(reset: false) }
        }
    }

    // MARK: - 数据

    private func load(reset: Bool) async {
        guard let apiClient else { return }
        if reset {
            page = 1
            hasMore = true
            errorText = nil
            // 重置请求直接覆盖进行中的旧请求（如切换年份），由代号丢弃旧结果。
            loadGeneration += 1
        } else {
            guard !isLoading, hasMore else { return }
        }

        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let response = try await fetch(using: apiClient, page: page)
            guard generation == loadGeneration else { return }
            var seen = Set(movies.map(\.id))
            let fresh = response.items.filter { seen.insert($0.id).inserted }

            if reset {
                movies = fresh
            } else {
                movies.append(contentsOf: fresh)
            }

            hasMore = response.hasMore
            if hasMore { page += 1 }
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            guard generation == loadGeneration else { return }
            errorText = error.localizedDescription
        }
    }

    private func fetch(using client: APIClient, page: Int) async throws -> MakerMoviePage {
        switch query {
        case .rank(let category, let period):
            let rank = try await client.makerRank(category: category, period: period)
            // 榜单接口一次返回整榜，没有分页。
            return MakerMoviePage(rank: rank)
        case .latest(let category):
            return try await client.makerLatest(category: category, page: page)
        case .top(let category):
            return try await client.makerTop(category: category, page: page, year: year.isEmpty ? nil : year)
        case .playback(let period):
            return try await client.makerPlayback(period: period)
        case .tag(let category, let group, let tagId, _):
            return try await client.makerBrowse(category: category, group: group, tagId: tagId, page: page)
        case .actor(let category, let actorID, _):
            return try await client.makerBrowse(category: category, actorID: actorID, page: page)
        case .collection(let id, _):
            return try await client.makerBrowse(category: .censored, listID: id, page: page)
        }
    }
}

private extension MakerMoviePage {
    /// 榜单接口没有分页字段，转换成统一的列表页结构。
    init(rank: MakerRankPage) {
        self.init(
            page: 1,
            items: rank.items,
            hasMore: false,
            filterLabel: rank.periodLabel,
            categoryLabel: rank.categoryLabel
        )
    }
}
