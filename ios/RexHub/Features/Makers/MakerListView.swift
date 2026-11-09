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

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: query.title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    if movies.isEmpty, isLoading {
                        MakerCardSkeletons(posterWidth: 108, count: 3)
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
                        MakerMovieGrid(movies: movies)

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
            .task { await load(reset: movies.isEmpty) }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
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
        guard !isLoading, let apiClient else { return }
        if reset {
            page = 1
            hasMore = true
            errorText = nil
        }
        guard hasMore || reset else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await fetch(using: apiClient, page: page)
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
            return try await client.makerTop(category: category, page: page)
        case .playback(let period):
            return try await client.makerPlayback(period: period)
        case .tag(let category, let group, let tagId, _):
            return try await client.makerBrowse(category: category, group: group, tagId: tagId, page: page)
        case .actor(let category, let actorID, _):
            return try await client.makerBrowse(category: category, actorID: actorID, page: page)
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
