import SwiftUI

// MARK: - 分类

/// 「分类」Hub：按标签组展示可点击的标签，选中后进入筛选列表。
struct MakerTagsBody: View {
    let category: MakerCategory
    let onOpenTag: (MakerTagGroup, MakerTag) -> Void

    @Environment(\.apiClient) private var apiClient
    @State private var groups: [MakerTagGroup] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.xl) {
            if isLoading {
                ForEach(0..<3, id: \.self) { _ in
                    RexSkeleton(width: .infinity, height: 96, cornerRadius: RexRadius.panel)
                }
                .padding(.horizontal, RexSpacing.xl)
            } else if let errorText {
                RexInlineNotice(
                    title: "分类加载失败",
                    message: errorText,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task { await load() }
                }
                .padding(.horizontal, RexSpacing.xl)
            } else if groups.isEmpty {
                RexInlineNotice(
                    title: "暂无分类",
                    message: "该类别暂未提供分类标签。",
                    tone: .neutral
                )
                .padding(.horizontal, RexSpacing.xl)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: RexSpacing.sm) {
                        Text(group.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RexColor.secondaryText)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 84), spacing: 8, alignment: .leading)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(group.tags) { tag in
                                Button {
                                    RexHaptics.tap()
                                    onOpenTag(group, tag)
                                } label: {
                                    Text(tag.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(RexColor.primaryText)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                        .background(
                                            RexColor.field,
                                            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                        )
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                    }
                    .padding(.horizontal, RexSpacing.xl)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: category.rawValue) { await load() }
    }

    private func load() async {
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            groups = try await apiClient.makerTags(category: category).categories
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 演员

/// 演员列表：按类别分页，点演员进入其作品列表。
struct MakerActorsView: View {
    let category: MakerCategory

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var actors: [MakerActor] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isScrolled = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: RexSpacing.md, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "演员·\(category.title)",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    if actors.isEmpty, isLoading {
                        LazyVGrid(columns: columns, spacing: RexSpacing.xl) {
                            ForEach(0..<9, id: \.self) { _ in
                                RexSkeleton(width: 96, height: 132, cornerRadius: RexRadius.panel)
                            }
                        }
                    } else if let errorText, actors.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "加载失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await load(reset: true) }
                        }
                    } else if actors.isEmpty {
                        RexStateCard(
                            symbol: "person.2",
                            title: "暂无演员",
                            message: "换个类别或稍后再试。",
                            tone: .neutral
                        )
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: RexSpacing.xl) {
                            ForEach(actors) { actor in
                                NavigationLink(
                                    value: MakerRoute.list(
                                        .actor(category, actorID: actor.id, name: actor.name)
                                    )
                                ) {
                                    actorCard(actor)
                                }
                                .buttonStyle(PressableButtonStyle())
                                .accessibilityHint("查看该演员的作品")
                                .onAppear {
                                    guard actor.id == actors.last?.id else { return }
                                    Task { await load(reset: false) }
                                }
                            }
                        }

                        if hasMore {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Button("加载更多") {
                                        Task { await load(reset: false) }
                                    }
                                    .font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(RexColor.brandBlue)
                                    .buttonStyle(PressableButtonStyle())
                                    .frame(minHeight: 44)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "makerActorsScroll"))
            }
            .rexScrollTracking("makerActorsScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load(reset: true) }
            .task { await load(reset: actors.isEmpty) }
        }
        .background(RexPageBackground())
    }

    private func actorCard(_ actor: MakerActor) -> some View {
        VStack(spacing: RexSpacing.sm) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    MakerArtwork(actor.avatarUrl, width: 240)
                }
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                }

            Text(actor.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            if actor.videosCount > 0 {
                Text("\(actor.videosCount) 部作品")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(actor.name)
    }

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
            let result = try await apiClient.makerActors(category: category, page: page)
            var seen = Set(actors.map(\.id))
            let fresh = result.items.filter { seen.insert($0.id).inserted }

            if reset {
                actors = fresh
            } else {
                actors.append(contentsOf: fresh)
            }

            hasMore = result.hasMore
            if hasMore { page += 1 }
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 最近浏览

struct MakerRecentViewedBody: View {
    @Environment(\.apiClient) private var apiClient

    @State private var movies: [MakerMovie] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: RexSpacing.xl) {
            if isLoading, movies.isEmpty {
                MakerCardSkeletons(posterWidth: 108, count: 3)
            } else if let errorText, movies.isEmpty {
                RexStateCard(
                    symbol: "wifi.exclamationmark",
                    title: "加载失败",
                    message: errorText,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task { await load() }
                }
            } else if movies.isEmpty {
                RexStateCard(
                    symbol: "clock.arrow.circlepath",
                    title: "暂无浏览记录",
                    message: "看过的影片会出现在这里。",
                    tone: .neutral
                )
            } else {
                MakerMovieGrid(movies: movies)
            }
        }
        .frame(maxWidth: .infinity)
        .task { await load() }
    }

    private func load() async {
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            movies = try await apiClient.makerRecentViewed()
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}
