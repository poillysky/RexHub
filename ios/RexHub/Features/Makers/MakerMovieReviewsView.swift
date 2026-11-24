import SwiftUI

/// 影片全部评论：分页拉取，对齐 PWA `MakerMovieReviewsBody`。
struct MakerMovieReviewsView: View {
    let movieID: String
    let title: String

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    private let pageSize = 20

    @State private var items: [MakerReview] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var isFetching = false
    @State private var errorText: String?
    @State private var isScrolled = false

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.md) {
                    if isLoading {
                        skeleton
                    } else if let errorText, items.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "评论加载失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await load(page: 1) }
                        }
                    } else if items.isEmpty {
                        RexStateCard(
                            symbol: "bubble.left",
                            title: "暂无评论",
                            message: "这部影片还没有人评论。",
                            tone: .neutral
                        )
                    } else {
                        ForEach(items) { review in
                            MakerReviewRow(review: review)
                        }

                        pager
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "makerReviewsScroll"))
            }
            .rexScrollTracking("makerReviewsScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                await load(page: 1)
            }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            guard items.isEmpty else { return }
            await load(page: 1)
        }
    }

    // MARK: - 区块

    private var skeleton: some View {
        VStack(spacing: RexSpacing.md) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    RexSkeleton(width: 120, height: 13, cornerRadius: 6)
                    RexSkeleton(width: nil, height: 12, cornerRadius: 6)
                    RexSkeleton(width: 220, height: 12, cornerRadius: 6)
                }
                .padding(RexSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rexCard()
            }
        }
        .accessibilityHidden(true)
    }

    private var pager: some View {
        HStack(spacing: RexSpacing.lg) {
            Button("上一页") {
                Task { await load(page: max(1, page - 1)) }
            }
            .disabled(page <= 1 || isFetching)

            Text("第 \(page) 页")
                .font(RexFont.caption)
                .foregroundStyle(RexColor.secondaryText)
                .monospacedDigit()

            Button("下一页") {
                Task { await load(page: page + 1) }
            }
            .disabled(!hasMore || isFetching)
        }
        .font(.system(.caption, weight: .semibold))
        .foregroundStyle(RexColor.brandBlue)
        .frame(maxWidth: .infinity)
        .padding(.top, RexSpacing.md)
        .padding(.bottom, RexSpacing.xl)
    }

    // MARK: - 数据

    private func load(page target: Int) async {
        guard let apiClient, movieID.isEmpty == false else {
            isLoading = false
            return
        }
        guard !isFetching else { return }

        isFetching = true
        errorText = nil
        if target == 1 { isLoading = items.isEmpty }
        defer {
            isFetching = false
            isLoading = false
        }

        do {
            let result = try await apiClient.makerReviews(movieID: movieID, page: target, limit: pageSize)
            items = result.items
            hasMore = result.hasMore
            page = max(1, result.page)
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}
