import SwiftUI

/// 栏目全部海报：三列网格 + 滚动到底自动翻页。
struct MediaGridView: View {
    let catalog: MediaCatalog

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(MediaRouter.self) private var router

    @State private var items: [MediaItem] = []
    @State private var loadedPages = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isScrolled = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: RexSpacing.md, alignment: .top),
        count: 3
    )

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: catalog.title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: RexSpacing.xl) {
                    ForEach(items) { item in
                        Button {
                            RexHaptics.tap()
                            router.push(.detail(item))
                        } label: {
                            MediaPosterCard(item: item)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityHint("查看详情")
                        .task { await loadMoreIfNeeded(item) }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.lg)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)

                footer
            }
            .rexScrollTracking("mediaGridScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await reload() }
        }
        .background(RexPageBackground())
        .task { await loadNextPage() }
    }

    // MARK: - 底部状态

    @ViewBuilder
    private var footer: some View {
        if isLoading, !items.isEmpty {
            HStack(spacing: RexSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("正在加载更多")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)
            }
            .padding(.vertical, RexSpacing.xl)
        } else if let errorMessage {
            RexInlineNotice(
                title: "加载失败",
                message: errorMessage,
                tone: .warning,
                actionTitle: "重试"
            ) {
                Task { await loadNextPage() }
            }
            .padding(.horizontal, RexSpacing.xl)
            .padding(.bottom, RexSpacing.xl)
        } else if items.isEmpty, !isLoading {
            RexStateCard(
                symbol: "film.stack",
                title: "这个栏目还没有内容",
                message: "稍后再试，或换个栏目看看。",
                tone: .neutral
            )
            .padding(.horizontal, RexSpacing.xl)
        } else if !hasMore, !items.isEmpty {
            Text("已经到底了")
                .font(RexFont.caption)
                .foregroundStyle(RexColor.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RexSpacing.xl)
        }
    }

    // MARK: - 数据

    private func loadMoreIfNeeded(_ item: MediaItem) async {
        guard item.id == items.last?.id, hasMore, !isLoading else { return }
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard let apiClient, !isLoading, hasMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await apiClient.mediaList(catalog: catalog.id, page: loadedPages + 1)
            loadedPages += 1
            hasMore = page.hasMore

            // 页与页之间可能重复，按 TMDB id 去重。
            var seen = Set(items.map(\.id))
            items += page.items.filter { seen.insert($0.id).inserted }
        } catch {
            if !(error is CancellationError), (error as? APIError) != .cancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reload() async {
        items = []
        loadedPages = 0
        hasMore = true
        errorMessage = nil
        await loadNextPage()
    }
}
