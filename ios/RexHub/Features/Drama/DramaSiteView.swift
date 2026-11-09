import SwiftUI

/// 站点目录：标题 + 搜索/榜单按钮，下方剧集网格（对齐 PWA 的短剧目录页）。
struct DramaSiteView: View {
    let site: DramaSite

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var cards: [DramaCard] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var path: [DramaRoute] = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RexNavBar(
                    title: site.name,
                    leading: .back(action: { dismiss() }),
                    actions: [
                        RexNavAction(
                            systemImage: "chart.bar.xaxis",
                            label: "榜单",
                            action: { path.append(.ranks(site.id)) }
                        ),
                        RexNavAction(
                            systemImage: "magnifyingglass",
                            label: "搜索",
                            action: { path.append(.searchResults("", site.id)) }
                        )
                    ],
                    isScrolled: false
                )
            }

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    if isLoading, cards.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in
                            RexSkeleton(width: .infinity, height: 90, cornerRadius: RexRadius.card)
                        }
                    } else if let errorText, cards.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "加载失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await load(reset: true) }
                        }
                    } else if cards.isEmpty {
                        RexStateCard(
                            symbol: "popcorn",
                            title: "暂无短剧",
                            message: "当前站点没有可展示的内容。",
                            tone: .neutral
                        )
                    } else {
                        DramaCardGrid(cards: cards)

                        if hasMore {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                Text(isLoading ? "加载中…" : "加载更多")
                                    .font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(RexColor.brandBlue)
                                    .frame(minWidth: 120, minHeight: 44)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .disabled(isLoading)
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load(reset: true) }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: DramaRoute.self) { route in
            switch route {
            case .site(let value):
                DramaSiteView(site: value)
                    .toolbar(.hidden, for: .navigationBar)
            case .detail(let card):
                DramaDetailView(card: card)
                    .toolbar(.hidden, for: .navigationBar)
            case .ranks(let siteID):
                DramaRankView(site: siteID)
                    .toolbar(.hidden, for: .navigationBar)
            case .searchResults(let keyword, let siteID):
                DramaSearchResultsView(keyword: keyword, site: siteID)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard let apiClient, !isLoading else { return }
        if reset {
            page = 1
            hasMore = true
            errorText = nil
        } else {
            guard hasMore else { return }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.dramaCatalog(site: site.id, page: page)
            var seen = Set(cards.map(\.id))
            let fresh = response.items.filter { seen.insert($0.id).inserted }

            if reset {
                cards = fresh
            } else {
                cards.append(contentsOf: fresh)
            }
            hasMore = response.hasMore
            if hasMore { page += 1 }
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}
