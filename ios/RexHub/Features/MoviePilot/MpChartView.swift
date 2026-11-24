import SwiftUI

/// 影视榜单列表：由货架的「全部」进入，整页翻页，对齐 PWA 的 `MediaChartBody`。
struct MpChartView: View {
    let shelf: MoviePilotShelf

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MpItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isScrolled = false

    /// 推荐接口不返回总页数，用「本页是否装满」判断还有没有下一页。
    private var pageSize: Int {
        Int(shelf.params["count"] ?? "") ?? 20
    }

    private var hasNext: Bool {
        items.count >= pageSize
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: shelf.title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: RexSpacing.xl) {
                        if isLoading, items.isEmpty {
                            skeletonWall
                        } else if let errorText, items.isEmpty {
                            RexStateCard(
                                symbol: "wifi.exclamationmark",
                                title: "加载失败",
                                message: errorText,
                                tone: .warning,
                                actionTitle: "重试"
                            ) {
                                Task { await load(page: page) }
                            }
                        } else if items.isEmpty {
                            RexStateCard(
                                symbol: "film",
                                title: "暂无条目",
                                message: "换个栏目或稍后再试。",
                                tone: .neutral
                            )
                        } else {
                            wall
                        }

                        if !isLoading, !items.isEmpty, page > 1 || (errorText == nil && hasNext) {
                            pager { target in
                                await load(page: target)
                                proxy.scrollTo("mpChartTop", anchor: .top)
                            }
                        }
                    }
                    .id("mpChartTop")
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .background(RexScrollOffsetReader(space: "mpChartScroll"))
                }
                .rexScrollTracking("mpChartScroll", isScrolled: $isScrolled)
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await load(page: page) }
            }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 重新出现时保留已加载内容与翻页位置。
            if items.isEmpty { await load(page: page) }
        }
    }

    // MARK: - 内容

    private var skeletonWall: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md), count: 3),
            spacing: RexSpacing.lg
        ) {
            ForEach(0..<9, id: \.self) { _ in
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        RexSkeleton(cornerRadius: RexRadius.control)
                    }
            }
        }
    }

    private var wall: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md), count: 3),
            spacing: RexSpacing.lg
        ) {
            ForEach(items) { item in
                NavigationLink(value: MpRoute.detail(item)) {
                    MpPosterCard(item: item)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private func pager(action: @escaping (Int) async -> Void) -> some View {
        HStack(spacing: RexSpacing.lg) {
            Button("上一页") {
                Task { await action(max(1, page - 1)) }
            }
            .disabled(page <= 1 || isLoading)

            Text("第 \(page) 页")
                .font(RexFont.caption)
                .foregroundStyle(RexColor.secondaryText)
                .monospacedDigit()

            Button("下一页") {
                Task { await action(page + 1) }
            }
            .disabled(!hasNext || isLoading)
        }
        .font(.system(.caption, weight: .semibold))
        .foregroundStyle(RexColor.brandBlue)
        .frame(maxWidth: .infinity)
        .padding(.top, RexSpacing.md)
        .padding(.bottom, RexSpacing.xl)
    }

    // MARK: - 数据

    private func load(page target: Int) async {
        guard let apiClient, !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        var params = shelf.params
        params["page"] = String(target)

        do {
            let result = try await apiClient.mpList(path: shelf.path, params: params)
            items = result.items
            page = target
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
            items = []
        }
    }
}
