import SwiftUI

/// 影视首页：以服务端 TMDB 插件的栏目为数据源，做成「精选横滑 + 海报栏」的海报墙。
///
/// 数据分两级：先取栏目清单，再按栏目各自取第一页海报。栏目之间相互独立，
/// 单个栏目失败只在该栏显示重试，不影响整页。
struct MediaHomeView: View {
    /// 点击顶栏搜索框：切到搜索页并聚焦输入框。
    var onOpenSearch: () -> Void

    @Environment(\.apiClient) private var apiClient
    /// 记住上次浏览的是电影还是剧集。
    @AppStorage("rexhub.media.type") private var mediaType = MediaHomeType.movie.rawValue

    @State private var catalogs: [MediaCatalog] = []
    @State private var isLoadingCatalogs = true
    @State private var catalogsError: String?
    @State private var rails: [String: MediaRailState] = [:]
    @State private var loadingIDs: Set<String> = []
    @State private var isScrolled = false
    @State private var router = MediaRouter()
    /// 精选横滑当前停在哪一张，用于底部指示点。
    @State private var heroPosition: String?
    /// 下拉刷新时递增，驱动各栏与精选区重新加载。
    @State private var refreshToken = 0

    @Namespace private var typePill

    var body: some View {
        NavigationStack(path: $router.path) {
            VStack(spacing: 0) {
                RexTopBar(
                    searchPlaceholder: "搜索影视",
                    isCollapsed: isScrolled,
                    onSearchTap: onOpenSearch
                ) {
                    mediaTypeSwitch
                }

                GeometryReader { proxy in
                    ScrollView {
                        content(width: min(proxy.size.width, RexLayout.contentMaxWidth))
                            .padding(.top, RexSpacing.sm)
                            .padding(.bottom, RexSpacing.huge)
                            .frame(maxWidth: RexLayout.contentMaxWidth)
                            .frame(maxWidth: .infinity)
                    }
                    .rexScrollTracking("mediaScroll", isScrolled: $isScrolled)
                    .scrollBounceBehavior(.basedOnSize)
                    .refreshable { await refresh() }
                }
            }
            .background(RexPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MediaRoute.self) { route in
                switch route {
                case .detail(let item):
                    MediaDetailView(item: item)
                        .toolbar(.hidden, for: .navigationBar)
                case .grid(let catalog):
                    MediaGridView(catalog: catalog)
                        .toolbar(.hidden, for: .navigationBar)
                case .search(let target):
                    SearchResultsView(keyword: target.keyword, sources: target.sources)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
            .task { await loadCatalogsIfNeeded() }
        }
        .environment(router)
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.xl) {
            if isLoadingCatalogs, catalogs.isEmpty {
                heroSkeleton(width: width)
                railSkeletons(posterWidth: posterWidth(for: width), count: 3)
            } else if let catalogsError, catalogs.isEmpty {
                RexStateCard(
                    symbol: "wifi.exclamationmark",
                    title: "影视数据加载失败",
                    message: catalogsError,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task { await reloadCatalogs() }
                }
                .padding(.horizontal, RexSpacing.xl)
            } else if typeCatalogs.isEmpty {
                RexStateCard(
                    symbol: "film.stack",
                    title: "影视栏目还没有配置",
                    message: "安装并启用影视插件后，电影与剧集的海报会显示在这里。",
                    tone: .brand
                )
                .padding(.horizontal, RexSpacing.xl)
            } else {
                heroSection(width: width)
                railsSection(posterWidth: posterWidth(for: width))
            }
        }
    }

    // MARK: - 电影 / 剧集切换（顶栏右侧）

    private var mediaTypeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(MediaHomeType.allCases) { type in
                typeButton(type)
            }
        }
        .padding(2)
        .frame(width: 112, height: 32)
        .background(RexColor.field, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(RexColor.fieldBorder, lineWidth: 0.75)
        }
        .animation(RexMotion.spring, value: mediaType)
    }

    private func typeButton(_ type: MediaHomeType) -> some View {
        let selected = mediaType == type.rawValue

        return Button {
            guard mediaType != type.rawValue else { return }
            RexHaptics.selection()
            withAnimation(RexMotion.spring) {
                mediaType = type.rawValue
            }
        } label: {
            Text(type.title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? RexColor.onBrand : RexColor.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(RexColor.brandGradient)
                            .matchedGeometryEffect(id: "mediaTypePill", in: typePill)
                            .shadow(color: RexColor.brandBlue.opacity(0.24), radius: 6, y: 2)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(type.title)
    }

    // MARK: - 精选横滑

    private func heroSection(width: CGFloat) -> some View {
        let cardWidth = heroCardWidth(for: width)

        return VStack(spacing: 0) {
            Group {
                if heroItems.isEmpty {
                    heroSkeleton(width: width)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: RexSpacing.md) {
                            ForEach(heroItems) { item in
                                heroCard(item, width: cardWidth)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $heroPosition)
                    .scrollIndicators(.hidden)
                    .contentMargins(.horizontal, RexSpacing.xl, for: .scrollContent)
                }
            }

            if heroItems.count > 1 {
                HStack(spacing: 5) {
                    ForEach(heroItems) { item in
                        Capsule(style: .continuous)
                            .fill(item.id == activeHeroID
                                  ? AnyShapeStyle(RexColor.brandGradient)
                                  : AnyShapeStyle(RexColor.tertiaryText.opacity(0.30)))
                            .frame(width: item.id == activeHeroID ? 16 : 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, RexSpacing.md)
                .animation(RexMotion.spring, value: activeHeroID)
                .accessibilityHidden(true)
            }
        }
        .task(id: "hero-\(mediaType)-\(refreshToken)") {
            guard let featuredCatalog else { return }
            await loadRail(featuredCatalog)
        }
    }

    /// 当前精选页：用户没滑过、或切换电影/剧集后都回落到第一张。
    private var activeHeroID: String? {
        if let heroPosition, heroItems.contains(where: { $0.id == heroPosition }) {
            return heroPosition
        }
        return heroItems.first?.id
    }

    private func heroCard(_ item: MediaItem, width: CGFloat) -> some View {
        let height = width * 9 / 16

        return Button {
            open(item)
        } label: {
            ZStack(alignment: .bottomLeading) {
                MediaArtwork(path: item.backdrop.isEmpty ? item.poster : item.backdrop, size: "w780")
                    .frame(width: width, height: height)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.18), .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 6) {
                    // 评分与年份、类型放在同一行，把纵向空间留给标题和简介。
                    HStack(spacing: 6) {
                        if let rating = item.rating {
                            MediaRatingBadge(rating: rating, compact: false)
                        }

                        heroChip(item.isMovie ? "电影" : "剧集")

                        if !item.year.isEmpty {
                            heroChip(item.year)
                        }
                    }

                    Text(item.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)

                    if !item.overview.isEmpty {
                        Text(item.overview)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineSpacing(2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(RexSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: RexRadius.largeCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.largeCard, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: RexRadius.largeCard, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(item.title)，\(item.isMovie ? "电影" : "剧集")")
        .accessibilityHint("查看详情")
    }

    private func heroChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.white.opacity(0.16), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
            }
    }

    private func heroSkeleton(width: CGFloat) -> some View {
        RexSkeleton(height: heroCardWidth(for: width) * 9 / 16, cornerRadius: RexRadius.largeCard)
            .padding(.horizontal, RexSpacing.xl)
            .accessibilityHidden(true)
    }

    // MARK: - 海报栏

    private func railsSection(posterWidth: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(typeCatalogs) { catalog in
                rail(catalog, posterWidth: posterWidth)
            }
        }
        .padding(.horizontal, RexSpacing.xl)
    }

    private func rail(_ catalog: MediaCatalog, posterWidth: CGFloat) -> some View {
        let state = rails[catalog.id]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: RexSpacing.sm) {
                Text(catalog.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    RexHaptics.tap()
                    router.push(.grid(catalog))
                } label: {
                    HStack(spacing: 2) {
                        Text("全部")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("查看\(catalog.title)全部")
            }

            if let state, !state.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(state.items) { item in
                            Button {
                                open(item)
                            } label: {
                                MediaPosterCard(item: item, width: posterWidth)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityHint("查看详情")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else if let error = state?.error, !error.isEmpty {
                RexInlineNotice(
                    title: "「\(catalog.title)」加载失败",
                    message: error,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task { await loadRail(catalog, force: true) }
                }
            } else {
                posterSkeletons(posterWidth: posterWidth)
            }
        }
        .task(id: "\(catalog.id)-\(refreshToken)") {
            await loadRail(catalog)
        }
    }

    private func posterSkeletons(posterWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RexSkeleton(width: posterWidth, height: posterWidth * 1.5, cornerRadius: 10)
                    RexSkeleton(width: posterWidth * 0.72, height: 11, cornerRadius: 5)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func railSkeletons(posterWidth: CGFloat, count: Int) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: RexSpacing.md) {
                    RexSkeleton(width: 96, height: 18, cornerRadius: 8)
                    posterSkeletons(posterWidth: posterWidth)
                }
            }
        }
        .padding(.horizontal, RexSpacing.xl)
    }

    // MARK: - 数据

    private var typeCatalogs: [MediaCatalog] {
        catalogs.filter { $0.mediaType == mediaType }
    }

    private var featuredCatalog: MediaCatalog? {
        typeCatalogs.first
    }

    private var heroItems: [MediaItem] {
        guard let id = featuredCatalog?.id else { return [] }
        return Array((rails[id]?.items ?? []).prefix(5))
    }

    private func heroCardWidth(for width: CGFloat) -> CGFloat {
        max(220, width - RexSpacing.xl * 2)
    }

    /// 一屏正好三张海报，右边缘再露出一点下一张；iPad 上限制最大宽度，避免海报过大。
    private func posterWidth(for width: CGFloat) -> CGFloat {
        min(140, max(100, (width - RexSpacing.xl * 2 - 20) / 3))
    }

    private func loadCatalogsIfNeeded() async {
        guard let apiClient, catalogs.isEmpty else { return }
        await reloadCatalogs(using: apiClient)
    }

    private func reloadCatalogs() async {
        guard let apiClient else { return }
        await reloadCatalogs(using: apiClient)
    }

    private func reloadCatalogs(using client: APIClient) async {
        isLoadingCatalogs = true
        do {
            catalogs = try await client.mediaCatalogs()
            catalogsError = nil
        } catch {
            if isCancelled(error) { return }
            catalogsError = error.localizedDescription
        }
        isLoadingCatalogs = false
    }

    private func loadRail(_ catalog: MediaCatalog, force: Bool = false) async {
        guard let apiClient else { return }
        if !force, rails[catalog.id]?.loaded == true { return }
        guard loadingIDs.insert(catalog.id).inserted else { return }
        defer { loadingIDs.remove(catalog.id) }

        rails[catalog.id, default: MediaRailState()].isLoading = true
        rails[catalog.id, default: MediaRailState()].error = nil

        do {
            let page = try await apiClient.mediaList(catalog: catalog.id, page: 1)
            // 插件按页取数，页内偶有重复，按 TMDB id 去重保证卡片不重复。
            var seen = Set<String>()
            let items = page.items.filter { seen.insert($0.id).inserted }
            rails[catalog.id] = MediaRailState(items: items, isLoading: false, loaded: true)
        } catch {
            if isCancelled(error) {
                rails[catalog.id]?.isLoading = false
                return
            }
            rails[catalog.id] = MediaRailState(
                items: [],
                isLoading: false,
                loaded: true,
                error: error.localizedDescription
            )
        }
    }

    private func refresh() async {
        refreshToken += 1
        rails = [:]
        loadingIDs = []

        if let apiClient {
            do {
                catalogs = try await apiClient.mediaCatalogs()
                catalogsError = nil
            } catch {
                if !isCancelled(error) {
                    catalogsError = error.localizedDescription
                }
            }
        }

        guard let featuredCatalog else { return }
        await loadRail(featuredCatalog, force: true)
    }

    private func open(_ item: MediaItem) {
        RexHaptics.tap()
        router.push(.detail(item))
    }

    private func isCancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? APIError) == .cancelled
    }
}

// MARK: - 辅助类型

private enum MediaHomeType: String, CaseIterable, Identifiable {
    case movie
    case series

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie: "电影"
        case .series: "剧集"
        }
    }
}

/// 单个栏目的加载状态；栏目之间互不影响。
private struct MediaRailState {
    var items: [MediaItem] = []
    var isLoading = false
    /// 已成功或已失败完成一次加载，避免视图重新出现时重复请求。
    var loaded = false
    var error: String?
}
