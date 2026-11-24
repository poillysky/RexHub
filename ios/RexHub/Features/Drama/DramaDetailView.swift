import SwiftUI

// MARK: - 详情

struct DramaDetailView: View {
    let card: DramaCard

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    private let playerSettings = PlayerSettingsStore.shared

    @State private var series: DramaSeries?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var isScrolled = false
    @State private var playing: DramaPlayRequest?
    @State private var episodePage = 0
    @State private var preparingEpisodeID: String?
    @State private var playError: RexAlertInfo?

    /// 每页最多展示的集数。
    private let episodesPerPage = 50

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: card.title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    cover

                    VStack(alignment: .leading, spacing: RexSpacing.xl) {
                        hero

                        if !synopsisText.isEmpty {
                            VStack(alignment: .leading, spacing: RexSpacing.md) {
                                sectionHeader("简介")

                                RexExpandableText(text: synopsisText, collapsedLines: 3)
                            }
                        }

                        if let series, !series.episodes.isEmpty {
                            playButton(series)
                        }

                        if let series {
                            episodesSection(series)
                        } else if isLoading {
                            VStack(alignment: .leading, spacing: RexSpacing.md) {
                                sectionHeader("选集")

                                LazyVGrid(columns: episodeColumns, alignment: .leading, spacing: RexSpacing.sm) {
                                    ForEach(0..<12, id: \.self) { _ in
                                        RexSkeleton(width: .infinity, height: 42, cornerRadius: 11)
                                    }
                                }
                            }
                        } else if let errorText {
                            RexStateCard(
                                symbol: "wifi.exclamationmark",
                                title: "详情加载失败",
                                message: errorText,
                                tone: .warning,
                                actionTitle: "重试"
                            ) {
                                Task { await load() }
                            }
                        }
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .background(RexScrollOffsetReader(space: "dramaDetailScroll"))
            }
            .rexScrollTracking("dramaDetailScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load() }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 从播放器返回时保留已加载内容，不重新请求。
            if series == nil { await load() }
        }
        .fullScreenCover(item: $playing) { request in
            RexPlayerView(item: request.item, playlist: [], directSource: request.info)
        }
        .rexAlert($playError)
    }

    // MARK: - 顶部全宽封面

    /// 顶部封面：贴屏幕左右边，高度按原图比例，完整显示不裁切（竖图自然更高）。
    private var cover: some View {
        MakerFullWidthArtwork(coverURL, width: 1080)
    }

    private var coverURL: String? {
        for candidate in [series?.cover, card.cover] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: - 头部（标题 + 徽标）

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            DramaTitleRow(spacing: 8, lineSpacing: 10) {
                Text(card.title)
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !card.siteName.isEmpty {
                    MakerBadge(text: card.siteName, tint: RexColor.brandBlue)
                }
                if card.episodeCount > 0 {
                    MakerBadge(text: "\(card.episodeCount) 集", tint: RexColor.success)
                }
                if let series {
                    MakerBadge(text: series.complete ? "已完结" : "连载中", tint: RexColor.warning)
                }
            }
        }
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.sm)
    }

    /// 主播放入口：位于简介与选集之间。
    private func playButton(_ series: DramaSeries) -> some View {
        let target = resumeEpisode ?? series.episodes.first(where: { !$0.disabled })
        let isResume = resumeEpisode != nil

        return Group {
            if let target {
                Button {
                    play(target)
                } label: {
                    HStack(spacing: RexSpacing.sm) {
                        if preparingEpisodeID == target.id {
                            ProgressView()
                                .controlSize(.small)
                                .tint(RexColor.onBrand)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(.footnote, weight: .bold))
                        }

                        Text(isResume ? "继续观看 第 \(target.episode) 集" : "播放第一集")
                            .font(.system(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(RexColor.onBrand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    // MARK: - 播放进度

    /// 与播放器写入进度用的 key 保持一致。
    private func progressKey(_ episode: DramaEpisode) -> String {
        "drama:\(card.site):\(episode.id)"
    }

    /// 最近观看且未看完的一集，用于「继续观看」。
    private var resumeEpisode: DramaEpisode? {
        guard let series else { return nil }
        return resumeEpisode(in: series)
    }

    private func resumeEpisode(in series: DramaSeries) -> DramaEpisode? {
        series.episodes
            .filter { !$0.disabled && playerSettings.playbackProgress(for: progressKey($0)) != nil }
            .max {
                playerSettings.progressUpdatedAt(for: progressKey($0))
                    < playerSettings.progressUpdatedAt(for: progressKey($1))
            }
    }

    /// 选集方块底部的进度条。
    private func progressBar(_ ratio: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(RexColor.cardBorder.opacity(0.7))

                Capsule()
                    .fill(RexColor.brandBlue)
                    .frame(width: max(proxy.size.width * min(max(ratio, 0), 1), 3))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 9)
        .padding(.bottom, 6)
        .allowsHitTesting(false)
    }

    // MARK: - 简介

    private var synopsisText: String {
        for candidate in [series?.description, card.description] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x5AC8FA), RexColor.brandBlue],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3, height: 15)

            Text(title)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(RexColor.primaryText)
        }
    }

    // MARK: - 选集

    private var episodeColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 54), spacing: RexSpacing.sm, alignment: .leading)]
    }

    private func episodesSection(_ series: DramaSeries) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            sectionHeader("选集")

            if episodePages.count > 1 {
                episodeRangeChips
            }

            LazyVGrid(columns: episodeColumns, alignment: .leading, spacing: RexSpacing.sm) {
                ForEach(pagedEpisodes(series)) { episode in
                    Button {
                        play(episode)
                    } label: {
                        Text("\(episode.episode)")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(episode.disabled ? RexColor.tertiaryText : RexColor.primaryText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                episode.disabled ? RexColor.field : RexColor.surface,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                            }
                            .overlay(alignment: .bottom) {
                                if let progress = playerSettings.playbackProgress(for: progressKey(episode)) {
                                    progressBar(progress.ratio)
                                }
                            }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(episode.disabled)
                    .accessibilityLabel("第 \(episode.episode) 集")
                }
            }

            if series.episodes.isEmpty {
                RexNote(text: "该短剧暂无可用剧集。")
            }
        }
        .padding(.top, 10)
    }

    /// 按每页 50 集切分后的页码范围。
    private var episodePages: [Range<Int>] {
        let total = series?.episodes.count ?? 0
        guard total > 0 else { return [] }
        return stride(from: 0, to: total, by: episodesPerPage).map {
            $0..<min($0 + episodesPerPage, total)
        }
    }

    private func pagedEpisodes(_ series: DramaSeries) -> [DramaEpisode] {
        let pages = episodePages
        guard pages.indices.contains(episodePage) else { return series.episodes }
        return Array(series.episodes[pages[episodePage]])
    }

    private var episodeRangeChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                ForEach(Array(episodePages.enumerated()), id: \.offset) { index, range in
                    let selected = episodePage == index
                    Button {
                        guard !selected else { return }
                        RexHaptics.selection()
                        episodePage = index
                    } label: {
                        Text("\(range.lowerBound + 1)-\(range.upperBound)")
                            .font(.system(.caption, weight: selected ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(selected ? RexColor.brandBlue : RexColor.tertiaryText)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(height: 26)
                            .background(
                                selected ? RexColor.brandBlue.opacity(0.10) : RexColor.field,
                                in: Capsule(style: .continuous)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func load() async {
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await apiClient.dramaSeries(site: card.site, id: card.id)
            series = loaded
            errorText = nil

            // 有观看进度时，选集默认落在该集所在的分页。
            if let resume = resumeEpisode(in: loaded),
               let index = loaded.episodes.firstIndex(where: { $0.id == resume.id }) {
                episodePage = index / episodesPerPage
            }
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    /// 播放前先向服务端解析地址：服务端只返回 CDN 直链或插件端口，播放流量不经过服务端。
    private func play(_ episode: DramaEpisode) {
        guard let apiClient, preparingEpisodeID == nil else { return }
        preparingEpisodeID = episode.id
        RexHaptics.tap()

        Task {
            defer { preparingEpisodeID = nil }
            do {
                let resolved = try await apiClient.dramaPlayInfo(site: card.site, episodeID: episode.id)
                let key = progressKey(episode)
                let item = PanItem(
                    id: key,
                    name: "\(card.title) 第 \(episode.episode) 集",
                    isDir: false,
                    size: 0,
                    pickcode: key,
                    sha1: "",
                    updatedAt: 0
                )
                playing = DramaPlayRequest(
                    item: item,
                    info: PanPlayInfo(
                        url: resolved.url,
                        headers: resolved.headers,
                        expiresIn: 0,
                        kind: resolved.kind
                    )
                )
            } catch {
                if let apiError = error as? APIError, apiError == .cancelled { return }
                playError = .failure(error.localizedDescription, title: "播放失败")
            }
        }
    }
}

/// 标题与徽标同行排布：徽标紧跟在标题后面，宽度不够时自动换行。
private struct DramaTitleRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let title = subviews.first else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        let titleIdeal = title.sizeThatFits(.unspecified)

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        if titleIdeal.width <= maxWidth {
            x = titleIdeal.width
            rowHeight = titleIdeal.height
        } else {
            let titleSize = title.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            y = titleSize.height + lineSpacing
        }

        for subview in subviews.dropFirst() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }

        let width = maxWidth.isFinite ? maxWidth : max(0, x)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let title = subviews.first else { return }
        let titleIdeal = title.sizeThatFits(.unspecified)

        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        if titleIdeal.width <= bounds.width {
            title.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(titleIdeal)
            )
            x += titleIdeal.width
            rowHeight = titleIdeal.height
        } else {
            let titleSize = title.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            title.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: titleSize.height)
            )
            x = bounds.minX
            y += titleSize.height + lineSpacing
        }

        for subview in subviews.dropFirst() {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            if x > bounds.minX { x += spacing }
            let offset = max(0, (rowHeight - size.height) / 2)
            subview.place(
                at: CGPoint(x: x, y: y + offset),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct DramaPlayRequest: Identifiable {
    let item: PanItem
    let info: PanPlayInfo

    var id: String { item.id }
}

// MARK: - 榜单

struct DramaRankView: View {
    let site: String

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [DramaRankGroup] = []
    @State private var selectedRank: DramaRank?
    @State private var selectedGroup = ""
    @State private var selectedFilter = ""
    @State private var cards: [DramaCard] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isScrolled = false

    private var allRanks: [(group: DramaRankGroup, rank: DramaRank)] {
        groups.flatMap { group in group.ranks.map { (group, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "短剧榜单",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            rankChips

            if let selectedRank, !selectedRank.filters.isEmpty {
                filterChips(selectedRank)
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
                            Task { await loadRank(reset: true) }
                        }
                    } else if cards.isEmpty {
                        RexStateCard(
                            symbol: "chart.bar.xaxis",
                            title: "暂无榜单内容",
                            message: "换个榜单看看。",
                            tone: .neutral
                        )
                    } else {
                        DramaCardGrid(cards: cards)

                        if hasMore {
                            Button {
                                Task { await loadRank(reset: false) }
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
                .background(RexScrollOffsetReader(space: "dramaRankScroll"))
            }
            .rexScrollTracking("dramaRankScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task { await loadLists() }
    }

    private var rankChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                ForEach(Array(allRanks.enumerated()), id: \.offset) { _, entry in
                    let selected = selectedRank?.id == entry.rank.id && selectedGroup == entry.group.id
                    Button {
                        guard !selected else { return }
                        RexHaptics.selection()
                        selectedGroup = entry.group.id
                        selectedRank = entry.rank
                        selectedFilter = ""
                        Task { await loadRank(reset: true) }
                    } label: {
                        Text(entry.rank.title)
                            .font(.system(.footnote, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? RexColor.onBrand : RexColor.secondaryText)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(minHeight: 30)
                            .background(
                                selected ? AnyShapeStyle(RexColor.brandGradient) : AnyShapeStyle(RexColor.surface),
                                in: Capsule(style: .continuous)
                            )
                            .overlay {
                                if !selected {
                                    Capsule(style: .continuous)
                                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                                }
                            }
                            .rexTapTarget()
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, RexSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, RexSpacing.sm)
    }

    private func filterChips(_ rank: DramaRank) -> some View {
        let options = rank.filters.flatMap(\.items)

        return ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                filterChip(id: "", label: "全部")

                ForEach(options) { option in
                    filterChip(id: option.id, label: option.title)
                }
            }
            .padding(.horizontal, RexSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, RexSpacing.sm)
    }

    private func filterChip(id: String, label: String) -> some View {
        let selected = selectedFilter == id
        return Button {
            guard !selected else { return }
            RexHaptics.selection()
            selectedFilter = id
            Task { await loadRank(reset: true) }
        } label: {
            Text(label)
                .font(.system(.caption, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? RexColor.brandBlue : RexColor.tertiaryText)
                .padding(.horizontal, RexSpacing.md)
                .frame(height: 26)
                .background(
                    selected ? RexColor.brandBlue.opacity(0.10) : RexColor.field,
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func loadLists() async {
        guard let apiClient else { return }
        do {
            groups = try await apiClient.dramaRankLists(site: site)
            if let first = allRanks.first {
                selectedGroup = first.group.id
                selectedRank = first.rank
                await loadRank(reset: true)
            }
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    private func loadRank(reset: Bool) async {
        guard let apiClient, let rank = selectedRank, !isLoading else { return }
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
            let response = try await apiClient.dramaRank(
                site: site,
                group: selectedGroup,
                rank: rank.id,
                filter: selectedFilter,
                page: page
            )
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

// MARK: - 搜索结果

struct DramaSearchResultsView: View {
    let keyword: String
    let site: String?

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String
    @State private var active: String
    @State private var cards: [DramaCard] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isScrolled = false
    @FocusState private var isFocused: Bool

    init(keyword: String, site: String?) {
        self.keyword = keyword
        self.site = site
        _draft = State(initialValue: keyword)
        _active = State(initialValue: keyword)
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "搜索短剧",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            searchField
                .padding(.horizontal, RexSpacing.xl)
                .padding(.bottom, RexSpacing.md)

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    if active.isEmpty {
                        RexStateCard(
                            symbol: "text.magnifyingglass",
                            title: "搜索短剧",
                            message: site == nil ? "在所有站点中搜索标题。" : "在当前站点搜索标题。",
                            tone: .brand
                        )
                    } else if isLoading, cards.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in
                            RexSkeleton(width: .infinity, height: 90, cornerRadius: RexRadius.card)
                        }
                    } else if let errorText, cards.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "搜索失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await search(reset: true) }
                        }
                    } else if cards.isEmpty {
                        RexStateCard(
                            symbol: "magnifyingglass",
                            title: "没有找到短剧",
                            message: "换个关键词试试。",
                            tone: .neutral
                        )
                    } else {
                        DramaCardGrid(cards: cards)

                        if hasMore {
                            Button {
                                Task { await search(reset: false) }
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
                .background(RexScrollOffsetReader(space: "dramaSearchScroll"))
            }
            .rexScrollTracking("dramaSearchScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await search(reset: true) }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            if !active.isEmpty { await search(reset: true) }
        }
    }

    private var searchField: some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)

            TextField("搜索短剧标题", text: $draft)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit(commit)

            if !draft.isEmpty {
                Button {
                    draft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.subheadline))
                        .foregroundStyle(RexColor.tertiaryText)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空关键词")
            }
        }
        .padding(.horizontal, RexSpacing.md)
        .frame(height: 44)
        .background(RexColor.surface, in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                .strokeBorder(RexColor.fieldBorder, lineWidth: 0.75)
        }
        .onAppear {
            if active.isEmpty { isFocused = true }
        }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isFocused = false
        active = value
        Task { await search(reset: true) }
    }

    private func search(reset: Bool) async {
        guard !active.isEmpty, let apiClient, !isLoading else { return }
        if reset {
            page = 1
            hasMore = true
            errorText = nil
            cards = []
        } else {
            guard hasMore else { return }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.dramaSearch(keyword: active, page: page, site: site)
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
