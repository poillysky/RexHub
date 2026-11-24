import SwiftUI
import UIKit

/// 片商搜索：对齐 PWA，支持影片 / 片商 / 演员 / 片单 / 系列 / 导演 / 番号 / 资源八种范围。
struct MakerSearchView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case movie
        case maker
        case actor
        case list
        case series
        case director
        case code
        case resource

        var id: String { rawValue }

        var title: String {
            switch self {
            case .movie: "影片"
            case .maker: "片商"
            case .actor: "演员"
            case .list: "片单"
            case .series: "系列"
            case .director: "导演"
            case .code: "番号"
            case .resource: "资源"
            }
        }

        var placeholder: String {
            switch self {
            case .movie: "番号或标题，如 IPZZ-991"
            case .maker: "片商名，如 S1 / MOODYZ / Brazzers"
            case .actor: "演员名，如 三上悠亜"
            case .list: "片单名，如 SSIS"
            case .series: "系列名，如 Kissing Sis"
            case .director: "导演名"
            case .code: "番号前缀，如 SSIS / IPZZ"
            case .resource: "资源关键词，如 IPZZ-991 / MOODYZ"
            }
        }

        var emptyTitle: String {
            switch self {
            case .movie: "输入番号或标题搜索"
            case .maker: "输入片商名搜索"
            case .actor: "输入演员名搜索"
            case .list: "输入片单名搜索"
            case .series: "输入系列名搜索"
            case .director: "输入导演名搜索"
            case .code: "输入番号前缀搜索"
            case .resource: "输入番号或片商名检索资源"
            }
        }

        var noHitTitle: String {
            switch self {
            case .movie: "没有匹配的影片"
            case .maker: "没有匹配的片商"
            case .actor: "没有匹配的演员"
            case .list: "没有匹配的片单"
            case .series: "没有匹配的系列"
            case .director: "没有匹配的导演"
            case .code: "没有匹配的番号"
            case .resource: "没有匹配的资源"
            }
        }

        /// 站内搜索（AVDB）还是自有数据（影片 / 资源）。
        var isEntity: Bool {
            self != .movie && self != .resource
        }

        var emptyHint: String {
            isEntity ? "AVDB 站内搜索，支持中英日文" : "数据来自 AVDB，支持中英日文"
        }
    }

    private enum MovieFilter: String, CaseIterable, Identifiable {
        case subtitle
        case magnets
        case playable

        var id: String { rawValue }

        var title: String {
            switch self {
            case .subtitle: "有中文字幕"
            case .magnets: "有磁力"
            case .playable: "可播放"
            }
        }
    }

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .movie
    @State private var keyword = ""
    @State private var submitted = ""
    @State private var filter: MovieFilter?
    @State private var exact = false

    @State private var movies: [MakerMovie] = []
    @State private var moviePage = 1
    @State private var movieHasMore = false

    @State private var hits: [MakerSearchItem] = []

    @State private var torrents: [MakerTorrent] = []
    @State private var torrentPage = 1
    @State private var torrentHasMore = false
    @State private var torrentTotal = 0

    @State private var isLoading = false
    @State private var errorText: String?
    @State private var copiedText: String?
    @FocusState private var isFocused: Bool

    init(initialKeyword: String = "", initialMode: Mode = .movie) {
        let trimmed = initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        _keyword = State(initialValue: trimmed)
        _submitted = State(initialValue: trimmed)
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "搜索",
                leading: .back(action: { dismiss() }),
                isScrolled: true
            )

            scopeTabs
                .padding(.bottom, 10)

            searchBar
                .padding(.horizontal, RexSpacing.xl)
                .padding(.bottom, 10)

            conditionalChips

            ScrollView {
                VStack(spacing: 10) {
                    results
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .onAppear { isFocused = submitted.isEmpty }
        .task {
            guard !submitted.isEmpty, isEmptyResult else { return }
            await reload()
        }
        .alert(
            "已复制",
            isPresented: Binding(
                get: { copiedText != nil },
                set: { if !$0 { copiedText = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(copiedText ?? "")
        }
    }

    // MARK: - 顶部

    /// 八个搜索范围，横向可滚动（PWA `.media-source-switch`）。
    private var scopeTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(Mode.allCases) { item in
                    let selected = mode == item
                    Button {
                        guard !selected else { return }
                        RexHaptics.selection()
                        withAnimation(RexMotion.spring) {
                            changeMode(item)
                        }
                    } label: {
                        Text(item.title)
                            .font(.system(.footnote, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? RexColor.primaryText : RexColor.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(minHeight: 32)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(RexColor.surface)
                                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                                }
                            }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
        }
        .scrollIndicators(.hidden)
        .background(RexColor.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, RexSpacing.xl)
    }

    private var searchBar: some View {
        HStack(spacing: RexSpacing.sm) {
            HStack(spacing: RexSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)

                TextField(mode.placeholder, text: $keyword)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                    .onSubmit { submit() }

                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        submitted = ""
                        clearResults()
                        errorText = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.subheadline))
                            .foregroundStyle(RexColor.tertiaryText)
                            .frame(width: 30, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空关键词")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RexColor.field, in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    .strokeBorder(RexColor.fieldBorder, lineWidth: 0.75)
            }

            Button(action: submit) {
                Text("搜索")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 64)
                    .frame(height: 44)
                    .padding(.horizontal, RexSpacing.xl)
                    .background(
                        RexColor.brandBlue.opacity(canSubmit ? 1 : 0.45),
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canSubmit)
            .accessibilityLabel("搜索")
        }
    }

    @ViewBuilder
    private var conditionalChips: some View {
        if mode == .movie {
            chipRow {
                ForEach(MovieFilter.allCases) { item in
                    chip(item.title, selected: filter == item) {
                        toggleFilter(item)
                    }
                }
            }
        } else if mode == .resource {
            chipRow {
                chip("仅番号完全匹配", selected: exact) {
                    exact.toggle()
                    guard !submitted.isEmpty else { return }
                    clearResults()
                    Task { await reload() }
                }
            }
        }
    }

    private func chipRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                content()
            }
            .padding(.horizontal, RexSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, RexSpacing.sm)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            RexHaptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? RexColor.onBrand : RexColor.secondaryText)
                .padding(.horizontal, 11)
                .frame(height: 28)
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

    // MARK: - 结果

    @ViewBuilder
    private var results: some View {
        if isLoading, isEmptyResult {
            skeleton
        } else if let errorText, isEmptyResult {
            RexStateCard(
                symbol: "wifi.exclamationmark",
                title: "搜索失败",
                message: errorText,
                tone: .warning,
                actionTitle: "重试"
            ) {
                Task { await reload() }
            }
        } else if submitted.isEmpty {
            hintBlock(mode.emptyTitle, hint: mode.emptyHint, symbol: "text.magnifyingglass")
        } else if isEmptyResult {
            hintBlock(mode.noHitTitle, hint: mode.emptyHint, symbol: "magnifyingglass")
        } else {
            resultList
        }
    }

    @ViewBuilder
    private var resultList: some View {
        switch mode {
        case .movie:
            MakerMovieGrid(movies: movies)
                .padding(.top, RexSpacing.xs)
            if movieHasMore { pager }
        case .resource:
            Text("共 \(torrentTotal) 条资源")
                .font(RexFont.caption)
                .foregroundStyle(RexColor.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                ForEach(torrents) { torrent in
                    torrentRow(torrent)
                }
            }
            if torrentHasMore { pager }
        case .actor:
            actorGrid
        default:
            VStack(spacing: RexSpacing.sm) {
                ForEach(hits) { item in
                    hitRow(item)
                }
            }
            .padding(.top, RexSpacing.xs)
        }
    }

    private var actorGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 88), spacing: 10, alignment: .top)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(hits) { item in
                NavigationLink(value: MakerRoute.actorDetail(id: item.id, name: item.name)) {
                    actorCard(item)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("查看演员资料与作品")
            }
        }
        .padding(.top, RexSpacing.xs)
    }

    /// 对齐 PWA `ActorGrid`：64pt 圆头像 + 名字 + 作品数。
    private func actorCard(_ item: MakerSearchItem) -> some View {
        VStack(spacing: 7) {
            Color.clear
                .frame(width: 64, height: 64)
                .overlay {
                    MakerArtwork(item.avatarUrl, width: 240)
                }
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                }

            Text(item.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            if item.count > 0 {
                Text("\(item.count) 部")
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
        .accessibilityLabel(item.name)
    }

    /// 对齐 PWA `.maker-hit`：名字 + 作品数 + chevron。
    @ViewBuilder
    private func hitRow(_ item: MakerSearchItem) -> some View {
        if let route = route(for: item) {
            NavigationLink(value: route) {
                hitRowBody(item)
            }
            .buttonStyle(PressableButtonStyle())
        } else {
            Button {
                openCode(item)
            } label: {
                hitRowBody(item)
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private func hitRowBody(_ item: MakerSearchItem) -> some View {
        HStack(spacing: RexSpacing.sm) {
            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            Spacer(minLength: RexSpacing.sm)

            if item.count > 0 {
                Text("\(item.count) 部")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RexColor.tertiaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RexColor.cardBorder, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 对齐 PWA `TorrentRow`：64pt 封面 + 站点 / 复制 + 标记 + 标题 + 元信息。
    private func torrentRow(_ torrent: MakerTorrent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear
                .frame(width: 64, height: 64)
                .overlay {
                    MakerArtwork(torrent.previewImage, width: 320)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: RexSpacing.sm) {
                    Text(torrent.sourceLabel)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: RexSpacing.sm)

                    Button {
                        copy(torrent.downloadUrl)
                    } label: {
                        Text(torrent.isMagnet ? "复制磁力" : "复制链接")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RexColor.brandBlue)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(RexColor.brandBlue.opacity(0.10), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                let flags = torrentFlags(torrent)
                if !flags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(flags, id: \.self) { flag in
                            Text(flag)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(RexColor.secondaryText)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(RexColor.field, in: Capsule(style: .continuous))
                        }
                    }
                }

                Text(torrent.title)
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(2)

                let meta = torrentMeta(torrent)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RexColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func torrentFlags(_ torrent: MakerTorrent) -> [String] {
        var flags: [String] = []
        if torrent.free { flags.append("免费") }
        if torrent.chinese { flags.append("中字") }
        if torrent.uncensored { flags.append("无码") }
        if torrent.uhd { flags.append("4K") }
        else if torrent.hd { flags.append("HD") }
        return flags
    }

    private func torrentMeta(_ torrent: MakerTorrent) -> String {
        var parts: [String] = []
        if !torrent.number.isEmpty { parts.append(torrent.number) }
        if !torrent.sizeLabel.isEmpty { parts.append(torrent.sizeLabel) }
        if torrent.seeders > 0 { parts.append("\(torrent.seeders) 做种") }
        if let postTime = torrent.postTime, !postTime.isEmpty { parts.append(postTime) }
        return parts.joined(separator: " · ")
    }

    private var pager: some View {
        HStack(spacing: RexSpacing.sm) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
            } else {
                Button {
                    Task { await loadMore() }
                } label: {
                    Text("加载更多")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minWidth: 120, minHeight: 44)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !isLoading else { return }
            Task { await loadMore() }
        }
    }

    private func hintBlock(_ title: String, hint: String, symbol: String) -> some View {
        VStack(spacing: RexSpacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(RexColor.tertiaryText)
                .padding(.bottom, RexSpacing.xs)

            Text(title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)

            Text(hint)
                .font(RexFont.caption)
                .foregroundStyle(RexColor.tertiaryText)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, RexSpacing.huge)
    }

    @ViewBuilder
    private var skeleton: some View {
        switch mode {
        case .movie, .resource:
            MakerCardSkeletons(posterWidth: 108, count: 3, aspect: 16 / 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, RexSpacing.xs)
        case .actor:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: 10, alignment: .top)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(0..<8, id: \.self) { _ in
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
            .padding(.top, RexSpacing.xs)
        default:
            VStack(spacing: RexSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    RexSkeleton(width: nil, height: 50, cornerRadius: 14)
                }
            }
            .padding(.top, RexSpacing.xs)
        }
    }

    // MARK: - 状态

    private var canSubmit: Bool {
        !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEmptyResult: Bool {
        switch mode {
        case .movie: movies.isEmpty
        case .resource: torrents.isEmpty
        default: hits.isEmpty
        }
    }

    private func route(for item: MakerSearchItem) -> MakerRoute? {
        switch item.kind {
        case MakerSearchType.maker.rawValue:
            return .entity(kind: .maker, id: item.id, name: item.name)
        case MakerSearchType.list.rawValue:
            return .list(.collection(id: item.id, name: item.name))
        case MakerSearchType.series.rawValue:
            return .entity(kind: .series, id: item.id, name: item.name)
        case MakerSearchType.director.rawValue:
            return .entity(kind: .director, id: item.id, name: item.name)
        case MakerSearchType.actor.rawValue:
            return .actorDetail(id: item.id, name: item.name)
        default:
            return nil
        }
    }

    /// 番号前缀：切到影片搜索继续查。
    private func openCode(_ item: MakerSearchItem) {
        guard !item.name.isEmpty else { return }
        isFocused = false
        mode = .movie
        keyword = item.name
        submitted = item.name
        clearResults()
        errorText = nil
        Task { await reload() }
    }

    private func changeMode(_ next: Mode) {
        mode = next
        clearResults()
        errorText = nil
        guard !submitted.isEmpty else { return }
        Task { await reload() }
    }

    private func toggleFilter(_ item: MovieFilter) {
        filter = filter == item ? nil : item
        guard !submitted.isEmpty else { return }
        clearResults()
        Task { await reload() }
    }

    private func submit() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isFocused = false
        submitted = trimmed
        clearResults()
        errorText = nil
        Task { await reload() }
    }

    private func clearResults() {
        movies = []
        moviePage = 1
        movieHasMore = false
        hits = []
        torrents = []
        torrentPage = 1
        torrentHasMore = false
        torrentTotal = 0
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        RexHaptics.success()
        copiedText = text.hasPrefix("magnet:") ? "已复制磁力链接" : "已复制下载链接"
    }

    // MARK: - 数据

    private func reload() async {
        guard !submitted.isEmpty, let apiClient else { return }

        let requestMode = mode
        isLoading = true
        errorText = nil
        defer { if requestMode == mode { isLoading = false } }

        do {
            switch requestMode {
            case .movie:
                let response = try await apiClient.makerMovieSearch(
                    keyword: submitted,
                    page: 1,
                    filter: filter?.rawValue ?? "all"
                )
                guard requestMode == mode else { return }
                movies = response.items
                movieHasMore = response.hasMore
                moviePage = 2
            case .resource:
                let response = try await apiClient.makerTorrents(
                    keyword: submitted,
                    page: 1,
                    exact: exact
                )
                guard requestMode == mode else { return }
                torrents = response.items
                torrentTotal = response.total
                torrentHasMore = response.hasMore
                torrentPage = 2
            default:
                let items = try await apiClient.makerSearch(
                    keyword: submitted,
                    type: requestMode.rawValue
                )
                guard requestMode == mode else { return }
                hits = items
            }
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            guard requestMode == mode else { return }
            errorText = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoading, !submitted.isEmpty, let apiClient else { return }

        let requestMode = mode
        isLoading = true
        defer { if requestMode == mode { isLoading = false } }

        do {
            switch requestMode {
            case .movie:
                guard movieHasMore else { return }
                let response = try await apiClient.makerMovieSearch(
                    keyword: submitted,
                    page: moviePage,
                    filter: filter?.rawValue ?? "all"
                )
                guard requestMode == mode else { return }
                var seen = Set(movies.map(\.id))
                movies.append(contentsOf: response.items.filter { seen.insert($0.id).inserted })
                movieHasMore = response.hasMore
                if response.hasMore { moviePage += 1 }
            case .resource:
                guard torrentHasMore else { return }
                let response = try await apiClient.makerTorrents(
                    keyword: submitted,
                    page: torrentPage,
                    exact: exact
                )
                guard requestMode == mode else { return }
                var seen = Set(torrents.map(\.id))
                torrents.append(contentsOf: response.items.filter { seen.insert($0.id).inserted })
                torrentTotal = response.total
                torrentHasMore = response.hasMore
                if response.hasMore { torrentPage += 1 }
            default:
                return
            }
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            guard requestMode == mode else { return }
            errorText = error.localizedDescription
        }
    }
}
