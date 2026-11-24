import SwiftUI

/// 片商 / 导演 / 系列详情：实体头 + 作品墙，对齐 PWA `MakerEntityBody`。
struct MakerEntityDetailView: View {
    let kind: MakerEntityKind
    let entityID: String
    let entityName: String

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var entity: MakerEntity?
    @State private var movies: [MakerMovie] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoadingEntity = true
    @State private var isLoadingMovies = false
    @State private var entityError: String?
    @State private var moviesError: String?
    @State private var isScrolled = false

    private var title: String {
        entity?.name ?? entityName
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    if let entity {
                        header(entity)
                    } else if isLoadingEntity {
                        headerSkeleton
                    } else if let entityError {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "资料加载失败",
                            message: entityError,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await loadEntity() }
                        }
                    }

                    if isLoadingMovies, movies.isEmpty {
                        moviesSkeleton
                    } else if let moviesError, movies.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "作品加载失败",
                            message: moviesError,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await loadMovies(page: 1) }
                        }
                    } else if movies.isEmpty {
                        RexStateCard(
                            symbol: "film",
                            title: "暂无影片",
                            message: "这个\(kind.title)暂时没有收录作品。",
                            tone: .neutral
                        )
                    } else {
                        MakerMovieGrid(movies: movies)
                        pager
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "makerEntityScroll"))
            }
            .rexScrollTracking("makerEntityScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                await loadEntity()
                await loadMovies(page: 1)
            }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 从影片详情返回时保留已加载的作品与滚动位置。
            guard movies.isEmpty else { return }
            await loadEntity()
            await loadMovies(page: 1)
        }
    }

    // MARK: - 实体头

    private func header(_ info: MakerEntity) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text(kind.title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(RexColor.tertiaryText)

            Text(info.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(info.videosCount > 0 ? "\(info.videosCount) 部作品" : "暂无作品统计")
                .font(.system(size: 13))
                .foregroundStyle(RexColor.tertiaryText)

            if let share = info.shareUrl, let url = URL(string: share) {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: RexSpacing.xs) {
                        Text("在 AVDB 查看原始条目")
                        Image(systemName: "arrow.up.right")
                            .font(.system(.caption2, weight: .semibold))
                    }
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(minHeight: 32)
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, 2)
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    private var headerSkeleton: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            RexSkeleton(width: 40, height: 11, cornerRadius: 4)
            RexSkeleton(width: 180, height: 20, cornerRadius: 8)
            RexSkeleton(width: 90, height: 13, cornerRadius: 6)
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
        .accessibilityHidden(true)
    }

    // MARK: - 作品

    private var moviesSkeleton: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md), count: 3),
            spacing: RexSpacing.xl
        ) {
            ForEach(0..<6, id: \.self) { _ in
                RexSkeleton(cornerRadius: RexRadius.control)
                    .aspectRatio(16 / 10, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }

    private var pager: some View {
        HStack(spacing: RexSpacing.lg) {
            Button("上一页") {
                Task { await loadMovies(page: max(1, page - 1)) }
            }
            .disabled(page <= 1 || isLoadingMovies)

            Text("第 \(page) 页")
                .font(RexFont.caption)
                .foregroundStyle(RexColor.secondaryText)
                .monospacedDigit()

            Button("下一页") {
                Task { await loadMovies(page: page + 1) }
            }
            .disabled(!hasMore || isLoadingMovies)
        }
        .font(.system(.caption, weight: .semibold))
        .foregroundStyle(RexColor.brandBlue)
        .frame(maxWidth: .infinity)
        .padding(.top, RexSpacing.md)
        .padding(.bottom, RexSpacing.xl)
    }

    // MARK: - 数据

    private func loadEntity() async {
        guard let apiClient, !entityID.isEmpty else {
            isLoadingEntity = false
            return
        }
        isLoadingEntity = true
        entityError = nil
        defer { isLoadingEntity = false }

        do {
            entity = try await apiClient.makerEntity(kind: kind, id: entityID)
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            entityError = error.localizedDescription
        }
    }

    private func loadMovies(page target: Int) async {
        guard let apiClient, !isLoadingMovies, !entityID.isEmpty else { return }
        isLoadingMovies = true
        moviesError = nil
        defer { isLoadingMovies = false }

        // PWA 同口径：系列要先拿实体的 type 再查作品墙。
        let seriesType: String
        if kind == .series {
            seriesType = entity?.type.map { String($0) } ?? "0"
        } else {
            seriesType = ""
        }

        do {
            let result = try await apiClient.makerBrowse(
                category: .censored,
                makerID: kind == .maker ? entityID : "",
                directorID: kind == .director ? entityID : "",
                seriesID: kind == .series ? entityID : "",
                seriesType: seriesType,
                page: target
            )
            movies = result.items
            hasMore = result.hasMore
            page = target
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            moviesError = error.localizedDescription
            movies = []
        }
    }
}
