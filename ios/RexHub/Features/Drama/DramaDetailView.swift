import SwiftUI

// MARK: - 详情

struct DramaDetailView: View {
    let card: DramaCard

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var series: DramaSeries?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var isScrolled = false
    @State private var playing: DramaPlayRequest?

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: card.title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    hero

                    if let series, !series.description.isEmpty {
                        Text(series.description)
                            .font(RexFont.body)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let series {
                        episodesSection(series)
                    } else if isLoading {
                        ForEach(0..<3, id: \.self) { _ in
                            RexSkeleton(width: .infinity, height: 90, cornerRadius: RexRadius.card)
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
                .background(RexScrollOffsetReader(space: "dramaDetailScroll"))
            }
            .rexScrollTracking("dramaDetailScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load() }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .fullScreenCover(item: $playing) { request in
            RexPlayerView(item: request.item, playlist: [], directSource: request.info)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: RexSpacing.lg) {
            MakerArtwork(card.cover, width: 360)
                .frame(width: 108, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous))

            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                Text(card.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(3)

                HStack(spacing: RexSpacing.sm) {
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

                if let first = series?.episodes.first(where: { !$0.disabled }) {
                    Button {
                        play(first)
                    } label: {
                        HStack(spacing: RexSpacing.sm) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("播放第一集")
                                .font(.system(.subheadline, weight: .semibold))
                        }
                        .foregroundStyle(RexColor.onBrand)
                        .padding(.horizontal, RexSpacing.lg)
                        .frame(height: 40)
                        .background(
                            RexColor.brandGradient,
                            in: Capsule(style: .continuous)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.top, RexSpacing.xs)
                }
            }
        }
    }

    private func episodesSection(_ series: DramaSeries) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text("选集")
                .font(RexFont.section)
                .foregroundStyle(RexColor.secondaryText)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 68), spacing: RexSpacing.sm, alignment: .leading)],
                alignment: .leading,
                spacing: RexSpacing.sm
            ) {
                ForEach(series.episodes) { episode in
                    Button {
                        play(episode)
                    } label: {
                        Text(episode.title.isEmpty ? "第 \(episode.episode) 集" : episode.title)
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(episode.disabled ? RexColor.tertiaryText : RexColor.primaryText)
                            .lineLimit(1)
                            .padding(.horizontal, RexSpacing.sm)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(
                                RexColor.surface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
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
            series = try await apiClient.dramaSeries(site: card.site, id: card.id)
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    private func play(_ episode: DramaEpisode) {
        guard let apiClient,
              let url = apiClient.dramaStreamURL(site: card.site, episodeID: episode.id) else { return }

        let key = "drama:\(card.site):\(episode.id)"
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
            info: PanPlayInfo(url: url, headers: [:], expiresIn: 0)
        )
        RexHaptics.tap()
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
        .toolbar(.hidden, for: .navigationBar)
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
                            .frame(height: 30)
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
                            .contentShape(Capsule(style: .continuous))
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
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if !active.isEmpty { await search(reset: true) }
        }
    }

    private var searchField: some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
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
                        .font(.system(size: 15))
                        .foregroundStyle(RexColor.tertiaryText)
                        .frame(width: 30, height: 30)
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
