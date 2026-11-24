import SwiftUI

// MARK: - 分类

/// 分类页的两段内容：挑选条件 / 查看结果。
enum MakerTagsPane: CaseIterable, Hashable {
    case pick
    case result

    var title: String {
        switch self {
        case .pick: "选择"
        case .result: "结果"
        }
    }
}

/// 「分类」Hub：标签分组多选，顶栏「确认」后跳到结果页。
struct MakerTagsBody: View {
    let category: MakerCategory
    @Binding var pane: MakerTagsPane
    /// 顶栏「确认」按钮的点击令牌，变化时应用当前选择。
    var confirmToken: Int = 0
    /// 当前是否有待应用的选择，回传给顶栏控制按钮状态。
    var onConfirmAvailabilityChange: (Bool) -> Void = { _ in }

    @Environment(\.apiClient) private var apiClient

    @State private var groups: [MakerTagGroup] = []
    @State private var isLoading = true
    @State private var errorText: String?

    /// 待确认的选择：分组 id → 选中标签 id，跨分组可以同时生效。
    @State private var draft: [String: [String]] = [:]

    /// 已生效的选择。
    @State private var applied: [String: [String]] = [:]

    @State private var movies: [MakerMovie] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoadingResults = false
    @State private var loadingMore = false
    @State private var resultsError: String?
    @State private var requestID = 0

    /// 单选分组：年份 / 月份 / 时长（其余分组可多选且跨组并存）。
    private static let singleGroups: Set<String> = ["year", "month", "duration"]
    /// 有独立查询参数的分组，不并入 tag_ids。
    private static let dimensionGroups: Set<String> = ["main", "year", "month", "duration"]

    private var isDirty: Bool {
        draft != applied
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md, alignment: .top), count: 2)
    }

    private var appliedSummary: String {
        let parts: [String] = groups.compactMap { group in
            let ids = applied[group.id] ?? []
            guard !ids.isEmpty else { return nil }
            let names = group.tags.filter { ids.contains($0.id) }.map(\.name)
            return ([group.name] + names).joined(separator: " ")
        }
        return parts.isEmpty ? "全部影片" : parts.joined(separator: " / ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.xl) {
            switch pane {
            case .pick:
                filterSection
            case .result:
                resultsSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(RexMotion.spring, value: pane)
        .task(id: category.rawValue) {
            draft = [:]
            applied = [:]
            movies = []
            page = 1
            hasMore = false
            resultsError = nil
            await loadGroups()
            await loadResults(reset: true)
        }
        .onChange(of: isDirty) { _, newValue in
            onConfirmAvailabilityChange(newValue)
        }
        .onChange(of: confirmToken) { _, _ in
            applySelection()
        }
        .onAppear {
            onConfirmAvailabilityChange(isDirty)
        }
    }

    // MARK: - 筛选

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            if isLoading {
                ForEach(0..<3, id: \.self) { _ in
                    RexSkeleton(width: nil, height: 64, cornerRadius: RexRadius.panel)
                }
            } else if let errorText {
                RexInlineNotice(
                    title: "分类加载失败",
                    message: errorText,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task {
                        await loadGroups()
                        await loadResults(reset: true)
                    }
                }
            } else if groups.isEmpty {
                RexInlineNotice(
                    title: "暂无分类",
                    message: "该类别暂未提供分类标签。",
                    tone: .neutral
                )
            } else {
                ForEach(groups) { group in
                    groupRow(group)
                }
            }

            if isDirty || !applied.isEmpty {
                clearRow
            }
        }
        .padding(.horizontal, RexSpacing.xl)
    }

    private func groupRow(_ group: MakerTagGroup) -> some View {
        let selected = draft[group.id] ?? []
        return HStack(alignment: .center, spacing: RexSpacing.sm) {
            Text(group.name)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)
                .fixedSize()

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("全部", isActive: selected.isEmpty) {
                        draft[group.id] = nil
                    }

                    ForEach(group.tags) { tag in
                        chip(tag.name, isActive: selected.contains(tag.id)) {
                            toggle(group: group, tag: tag)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Text(title)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(isActive ? RexColor.onBrand : RexColor.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    isActive ? RexColor.brandBlue : RexColor.field,
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func toggle(group: MakerTagGroup, tag: MakerTag) {
        var selected = draft[group.id] ?? []
        if Self.singleGroups.contains(group.id) {
            selected = selected.contains(tag.id) ? [] : [tag.id]
        } else if let index = selected.firstIndex(of: tag.id) {
            selected.remove(at: index)
        } else {
            selected.append(tag.id)
        }
        draft[group.id] = selected.isEmpty ? nil : selected
    }

    /// 页内的次要操作：清空当前筛选。确认按钮在顶栏。
    private var clearRow: some View {
        HStack {
            Button {
                RexHaptics.tap()
                draft = [:]
                applied = [:]
                Task { await loadResults(reset: true) }
            } label: {
                Text("清空筛选")
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
                    .background(RexColor.field, in: Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())

            Spacer(minLength: 0)
        }
    }

    private func applySelection() {
        guard isDirty else { return }
        RexHaptics.tap()
        applied = draft
        withAnimation(RexMotion.spring) {
            pane = .result
        }
        Task { await loadResults(reset: true) }
    }

    // MARK: - 结果

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            Text(appliedSummary)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, RexSpacing.xl)

            if isLoadingResults && movies.isEmpty {
                skeletonGrid
            } else if let resultsError, movies.isEmpty {
                RexInlineNotice(
                    title: "作品加载失败",
                    message: resultsError,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    Task { await loadResults(reset: true) }
                }
                .padding(.horizontal, RexSpacing.xl)
            } else if movies.isEmpty {
                Text("暂无影片")
                    .font(.system(.subheadline))
                    .foregroundStyle(RexColor.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                MakerMovieGrid(movies: movies, columnCount: 2)
                    .padding(.horizontal, RexSpacing.xl)

                if hasMore {
                    Button {
                        RexHaptics.tap()
                        Task { await loadResults(reset: false) }
                    } label: {
                        HStack(spacing: 6) {
                            if loadingMore {
                                ProgressView().controlSize(.small).tint(RexColor.secondaryText)
                            }
                            Text(loadingMore ? "加载中" : "加载更多")
                                .font(.system(.subheadline, weight: .semibold))
                        }
                        .foregroundStyle(RexColor.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RexColor.field, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(loadingMore)
                    .padding(.horizontal, RexSpacing.xl)
                }
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RexSkeleton(width: nil, height: 110, cornerRadius: RexRadius.control)
                    RexSkeleton(width: 72, height: 11, cornerRadius: 5)
                }
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .accessibilityHidden(true)
    }

    // MARK: - 数据

    private func loadGroups() async {
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

    private func loadResults(reset: Bool) async {
        guard let apiClient else {
            resultsError = "登录状态已失效，请重新登录"
            return
        }
        if reset {
            requestID += 1
            page = 1
            resultsError = nil
            isLoadingResults = true
        } else {
            guard !loadingMore, hasMore else { return }
            loadingMore = true
        }
        defer {
            if reset { isLoadingResults = false } else { loadingMore = false }
        }

        let currentRequest = requestID
        let target = reset ? 1 : page + 1
        let mainFilters = applied["main"] ?? []
        let contentTagIDs = applied
            .filter { $0.key != "main" && !Self.dimensionGroups.contains($0.key) }
            .flatMap { $0.value }
        do {
            let result = try await apiClient.makerBrowse(
                category: category,
                tagIds: contentTagIDs,
                mainFilters: mainFilters,
                year: applied["year"]?.first ?? "",
                month: applied["month"]?.first ?? "",
                duration: applied["duration"]?.first ?? "",
                page: target
            )
            guard currentRequest == requestID else { return }
            if reset {
                movies = result.items
            } else {
                movies.append(contentsOf: result.items)
            }
            page = target
            hasMore = result.hasMore
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            guard currentRequest == requestID else { return }
            resultsError = error.localizedDescription
        }
    }
}

// MARK: - 分类页

/// 顶栏「分类」入口打开的独立页面：筛选面板 + 作品墙。
struct MakerTagsView: View {
    let category: MakerCategory

    @Environment(\.dismiss) private var dismiss

    @State private var isScrolled = false
    @State private var canConfirm = false
    @State private var confirmToken = 0
    @State private var pane: MakerTagsPane = .pick

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "分类·\(category.title)",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled,
                trailing: AnyView(
                    Button {
                        confirmToken += 1
                    } label: {
                        Text("确认")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(canConfirm ? RexColor.brandBlue : RexColor.tertiaryText)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canConfirm)
                )
            )

            RexPillTabs(items: MakerTagsPane.allCases, selection: $pane) { $0.title }

            ScrollViewReader { proxy in
                ScrollView {
                    MakerTagsBody(
                        category: category,
                        pane: $pane,
                        confirmToken: confirmToken,
                        onConfirmAvailabilityChange: { canConfirm = $0 }
                    )
                    .padding(.top, RexSpacing.sm)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .background(RexScrollOffsetReader(space: "makerTagsScroll"))
                    .id("makerTagsTop")
                }
                .scrollBounceBehavior(.basedOnSize)
                .rexScrollTracking("makerTagsScroll", isScrolled: $isScrolled)
                .onChange(of: pane) { _, _ in
                    proxy.scrollTo("makerTagsTop", anchor: .top)
                }
            }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 演员

/// 演员总入口：推荐（新人 / 月榜 / FANZA 推荐）+ 有码 / 无码 / 欧美，对齐 PWA。
struct MakerActorsView: View {
    let category: MakerCategory

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var tab: ActorTab
    @State private var actors: [MakerActor] = []
    @State private var recommend: MakerActorRecommend?
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isScrolled = false

    init(category: MakerCategory) {
        self.category = category
        _tab = State(initialValue: .recommend)
    }

    /// 顶部切换：推荐 + 三个演员分类（对应 PWA 的 media-source-switch）。
    private enum ActorTab: Hashable {
        case recommend
        case category(MakerCategory)

        var title: String {
            switch self {
            case .recommend: "推荐"
            case .category(let category): category.title
            }
        }
    }

    private struct ActorGroup: Identifiable {
        let id: String
        let title: String
        let actors: [MakerActor]
    }

    private var tabs: [ActorTab] {
        [.recommend, .category(.censored), .category(.uncensored), .category(.western)]
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 84), spacing: 10, alignment: .top)]
    }

    /// 切 tab 时清掉上一个分类的分页状态，避免沿用旧列表。
    private var tabSelection: Binding<ActorTab> {
        Binding(
            get: { tab },
            set: { next in
                guard next != tab else { return }
                tab = next
                if case .category = next {
                    actors = []
                    page = 1
                    hasMore = true
                }
                errorText = nil
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "演员·\(tab.title)",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            RexPillTabs(items: tabs, selection: tabSelection, title: { $0.title })

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    content
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.sm)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "makerActorsScroll"))
            }
            .rexScrollTracking("makerActorsScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await reload() }
            // 从详情返回时保留已加载内容与滚动位置，不重复请求。
            .task(id: tab) {
                guard errorText == nil else { return }
                switch tab {
                case .recommend:
                    if recommend == nil { await loadRecommend() }
                case .category(let category):
                    if actors.isEmpty { await loadActors(category: category, reset: true) }
                }
            }
        }
        .background(RexPageBackground())
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .recommend:
            recommendContent
        case .category(let category):
            categoryContent(category)
        }
    }

    @ViewBuilder
    private var recommendContent: some View {
        if let recommend {
            let groups = [
                ActorGroup(id: "new", title: "新人", actors: recommend.newActors),
                ActorGroup(id: "monthly", title: "月榜", actors: recommend.monthlyActors),
                ActorGroup(id: "fanza", title: "FANZA(DMM)推荐", actors: recommend.recommendActors)
            ]
            .filter { !$0.actors.isEmpty }

            if groups.isEmpty {
                RexStateCard(
                    symbol: "person.2",
                    title: "暂无演员",
                    message: "稍后再试。",
                    tone: .neutral
                )
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(group.title)
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(RexColor.primaryText)
                            Text("\(group.actors.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(RexColor.tertiaryText)
                            Spacer(minLength: 0)
                        }
                        actorGrid(group.actors, paged: false)
                    }
                }
            }
        } else if isLoading {
            actorSkeleton
        } else if let errorText {
            RexStateCard(
                symbol: "wifi.exclamationmark",
                title: "加载失败",
                message: errorText,
                tone: .warning,
                actionTitle: "重试"
            ) {
                Task { await reload() }
            }
        }
    }

    @ViewBuilder
    private func categoryContent(_ category: MakerCategory) -> some View {
        if actors.isEmpty, isLoading {
            actorSkeleton
        } else if let errorText, actors.isEmpty {
            RexStateCard(
                symbol: "wifi.exclamationmark",
                title: "加载失败",
                message: errorText,
                tone: .warning,
                actionTitle: "重试"
            ) {
                Task { await loadActors(category: category, reset: true) }
            }
        } else if actors.isEmpty {
            RexStateCard(
                symbol: "person.2",
                title: "暂无演员",
                message: "换个类别或稍后再试。",
                tone: .neutral
            )
        } else {
            actorGrid(actors, paged: true)

            if hasMore {
                HStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("加载更多") {
                            Task { await loadActors(category: category, reset: false) }
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

    private func actorGrid(_ list: [MakerActor], paged: Bool) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(list) { actor in
                NavigationLink(value: MakerRoute.actorDetail(id: actor.id, name: actor.name)) {
                    actorCard(actor)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("查看演员资料与作品")
                .onAppear {
                    guard paged, actor.id == list.last?.id else { return }
                    guard case .category(let category) = tab else { return }
                    Task { await loadActors(category: category, reset: false) }
                }
            }
        }
    }

    /// 卡片对齐 PWA：64pt 圆头像 + 名字 + 作品数，带浅底圆角卡片。
    private func actorCard(_ actor: MakerActor) -> some View {
        VStack(spacing: 7) {
            Color.clear
                .frame(width: 64, height: 64)
                .overlay {
                    MakerArtwork(actor.avatarUrl, width: 240)
                }
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                }

            Text(actor.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            if actor.videosCount > 0 {
                Text("\(actor.videosCount) 部")
                    .font(.system(size: 11))
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(RexColor.cardBorder, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(actor.name)
    }

    private var actorSkeleton: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(0..<12, id: \.self) { _ in
                VStack(spacing: 7) {
                    RexSkeleton(width: 64, height: 64, cornerRadius: 32)
                    RexSkeleton(width: 46, height: 10, cornerRadius: 5)
                    RexSkeleton(width: 30, height: 8, cornerRadius: 4)
                }
                .padding(.top, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RexColor.surface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
    }

    private func reload() async {
        errorText = nil
        switch tab {
        case .recommend:
            recommend = nil
            await loadRecommend()
        case .category(let category):
            actors = []
            await loadActors(category: category, reset: true)
        }
    }

    private func loadRecommend() async {
        guard let apiClient, !isLoading else {
            if apiClient == nil { errorText = "登录状态已失效，请重新登录" }
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            recommend = try await apiClient.makerActorRecommend()
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    private func loadActors(category: MakerCategory, reset: Bool) async {
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            return
        }
        guard !isLoading else { return }
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
                MakerCardSkeletons(posterWidth: 108, count: 3, aspect: 16 / 10)
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
