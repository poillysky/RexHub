import SwiftUI

/// 片商演员详情：资料 + 特色标签 + 作品墙，对齐 PWA 的 `MakerActorDetailBody`。
struct MakerActorDetailView: View {
    let actorID: String
    let actorName: String

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var detail: MakerActorDetail?
    @State private var movies: [MakerMovie] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoadingDetail = true
    @State private var isLoadingMovies = false
    @State private var detailError: String?
    @State private var moviesError: String?
    @State private var isScrolled = false

    private var title: String {
        detail?.name ?? actorName
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
                    if let detail {
                        profile(detail)
                    } else if isLoadingDetail {
                        profileSkeleton
                    } else if let detailError {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "资料加载失败",
                            message: detailError,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await loadDetail() }
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
                            message: "这位演员暂时没有收录作品。",
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
                .background(RexScrollOffsetReader(space: "makerActorScroll"))
            }
            .rexScrollTracking("makerActorScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                await loadDetail()
                await loadMovies(page: 1)
            }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 从影片详情返回时保留已加载的作品与滚动位置。
            guard movies.isEmpty else { return }
            await loadDetail()
            await loadMovies(page: 1)
        }
    }

    // MARK: - 资料

    private func profile(_ info: MakerActorDetail) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            HStack(alignment: .top, spacing: RexSpacing.lg) {
                MakerArtwork(info.avatarUrl, width: 240)
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(2)

                    if let zht = info.nameZht, !zht.isEmpty, zht != info.name {
                        Text(zht)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(2)
                    }

                    if let other = info.otherName, !other.isEmpty {
                        Text("曾用名：\(other)")
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.tertiaryText)
                            .lineLimit(2)
                    }

                    Text(info.videosCount > 0 ? "\(info.videosCount) 部作品" : "暂无作品统计")
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }

            if !facts(info).isEmpty {
                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    ForEach(facts(info), id: \.0) { item in
                        HStack(alignment: .top, spacing: RexSpacing.md) {
                            Text(item.0)
                                .font(RexFont.caption)
                                .foregroundStyle(RexColor.tertiaryText)
                                .frame(width: 44, alignment: .leading)

                            Text(item.1)
                                .font(RexFont.footnote)
                                .foregroundStyle(RexColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(RexSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rexCard()
            }

            if !info.filterTags.isEmpty {
                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    Text("特色标签")
                        .font(RexFont.section)
                        .foregroundStyle(RexColor.secondaryText)

                    tagWrap(info.filterTags.map(\.name))
                }
            }

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
            }
        }
    }

    private func facts(_ info: MakerActorDetail) -> [(String, String)] {
        [
            ("生日", info.birthday ?? ""),
            ("年龄", info.age > 0 ? "\(info.age) 岁" : ""),
            ("星座", info.constellation ?? ""),
            ("血型", info.bloodType ?? ""),
            ("身高", info.height > 0 ? "\(info.height) cm" : ""),
            ("胸围", info.bust > 0 ? "\(info.bust) cm" : ""),
            ("腰围", info.waist > 0 ? "\(info.waist) cm" : ""),
            ("臀围", info.hips > 0 ? "\(info.hips) cm" : ""),
            ("罩杯", info.cup ?? ""),
            ("出生地", info.birthplace ?? "")
        ].filter { !$0.1.isEmpty }
    }

    private var profileSkeleton: some View {
        HStack(alignment: .top, spacing: RexSpacing.lg) {
            RexSkeleton(width: 96, height: 96, cornerRadius: 48)
            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                RexSkeleton(width: 140, height: 18, cornerRadius: 8)
                RexSkeleton(width: 90, height: 13, cornerRadius: 6)
                RexSkeleton(width: 110, height: 13, cornerRadius: 6)
            }
        }
    }

    private func tagWrap(_ tags: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: RexSpacing.sm, alignment: .leading)],
            alignment: .leading,
            spacing: RexSpacing.sm
        ) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, RexSpacing.md)
                    .frame(height: 28)
                    .background(RexColor.field, in: Capsule(style: .continuous))
            }
        }
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

    private func loadDetail() async {
        guard let apiClient, actorID.isEmpty == false else {
            isLoadingDetail = false
            return
        }
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }

        do {
            detail = try await apiClient.makerActorDetail(id: actorID)
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            detailError = error.localizedDescription
        }
    }

    private func loadMovies(page target: Int) async {
        guard let apiClient, !isLoadingMovies, actorID.isEmpty == false else { return }
        isLoadingMovies = true
        moviesError = nil
        defer { isLoadingMovies = false }

        do {
            let result = try await apiClient.makerBrowse(
                category: .censored,
                actorID: actorID,
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
