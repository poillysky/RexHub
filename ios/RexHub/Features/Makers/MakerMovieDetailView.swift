import SwiftUI
import UIKit

/// 片商影片详情：封面信息、简介、演员、标签、磁力、在线播放源与相关影片。
struct MakerMovieDetailView: View {
    private let movieID: String
    private let initialMovie: MakerMovie?

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var detail: MakerMovieDetail?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var isScrolled = false

    /// 评论（首屏 10 条）与相关片单，随详情并行拉取。
    @State private var reviews: [MakerReview] = []
    @State private var relatedLists: [MakerRelatedList] = []

    /// 播放源
    @State private var streams: [MakerStream] = []
    @State private var streamReason = ""
    @State private var isLoadingStreams = false
    @State private var showsStreamSheet = false
    @State private var playingSource: MakerPlayRequest?
    @State private var alert: RexAlertInfo?

    /// 正在转存到 115 的链接，用于行内按钮进度。
    @State private var savingLink: String?

    init(movie: MakerMovie) {
        movieID = movie.id
        initialMovie = movie
    }

    init(movieID: String) {
        self.movieID = movieID
        initialMovie = nil
    }

    private var movie: MakerMovie? {
        detail?.movie ?? initialMovie
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: movie?.number.isEmpty == false ? movie?.number ?? "" : "影片详情",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    if let detail {
                        if !detail.summarySafe.isEmpty {
                            section("简介") {
                                RexExpandableText(text: detail.summarySafe)
                            }
                        }

                        actionRow()

                        if !detail.actors.isEmpty {
                            section("演员") {
                                actorChips(Array(detail.actors.prefix(12)))
                            }
                        }

                        if hasTags(detail) {
                            section("标签") {
                                tagChips(detail)
                            }
                        }

                        if !detail.previews.isEmpty {
                            section("图片") {
                                previewRail(Array(detail.previews.prefix(12)))
                            }
                        }

                        if !detail.magnets.isEmpty {
                            section("磁力链接") {
                                VStack(spacing: RexSpacing.sm) {
                                    ForEach(detail.magnets) { magnet in
                                        magnetRow(magnet)
                                    }
                                }
                            }
                        }

                        if !detail.resources.isEmpty {
                            section("共享资源") {
                                VStack(spacing: RexSpacing.sm) {
                                    ForEach(detail.resources) { resource in
                                        resourceRow(resource)
                                    }
                                }
                            }
                        }

                        if !detail.avdbTorrents.isEmpty {
                            section("AVDB 资源（\(detail.avdbTorrents.count)）") {
                                VStack(spacing: RexSpacing.sm) {
                                    ForEach(detail.avdbTorrents) { torrent in
                                        torrentRow(torrent)
                                    }
                                }
                            }
                        }

                        if !reviews.isEmpty {
                            section(reviewSectionTitle(detail)) {
                                VStack(spacing: RexSpacing.sm) {
                                    ForEach(reviews) { review in
                                        MakerReviewRow(review: review)
                                    }
                                }

                                if detail.reviewsCount > reviews.count {
                                    NavigationLink(
                                        value: MakerRoute.movieReviews(
                                            id: movieID,
                                            title: heroTitle
                                        )
                                    ) {
                                        Text("查看全部 \(detail.reviewsCount) 条评论")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(RexColor.brandBlue)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .buttonStyle(PressableButtonStyle())
                                }
                            }
                        }

                        if !detail.relativeMovies.isEmpty {
                            section("相关影片") {
                                posterRail(Array(detail.relativeMovies.prefix(12)))
                            }
                        }

                        if !detail.actorMovies.isEmpty {
                            section("同演员作品") {
                                posterRail(Array(detail.actorMovies.prefix(12)))
                            }
                        }

                        if !detail.topRankings.isEmpty {
                            section("榜单排名") {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)],
                                    alignment: .leading,
                                    spacing: 6
                                ) {
                                    ForEach(Array(detail.topRankings.enumerated()), id: \.offset) { _, entry in
                                        Text(entry.label)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(RexColor.secondaryText)
                                            .lineLimit(1)
                                            .padding(.horizontal, 11)
                                            .frame(height: 28)
                                            .background(RexColor.field, in: Capsule(style: .continuous))
                                    }
                                }
                            }
                        }

                        if !relatedLists.isEmpty {
                            section("相关片单") {
                                VStack(spacing: RexSpacing.sm) {
                                    ForEach(relatedLists) { list in
                                        NavigationLink(value: MakerRoute.list(.collection(id: list.id, name: list.name))) {
                                            relatedListRow(list)
                                        }
                                        .buttonStyle(PressableButtonStyle())
                                    }
                                }
                            }
                        }

                        if let shareUrl = detail.shareUrl, let url = URL(string: shareUrl) {
                            Button {
                                RexHaptics.tap()
                                openURL(url)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("在 AVDB 查看原始条目")
                                        .font(.system(size: 14, weight: .semibold))

                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(RexColor.brandBlue)
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    } else if isLoading {
                        section("简介") {
                            overviewSkeleton
                        }

                        section("演员") {
                            actorSkeleton
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
                        .padding(.top, RexSpacing.xl)
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .background(alignment: .top) { wash }
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "makerDetailScroll"))
            }
            .rexScrollTracking("makerDetailScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load() }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 从演员详情等二级页返回时保留已加载内容，不重新请求。
            if detail == nil { await load() }

            async let reviewsTask: Void = loadReviews()
            async let listsTask: Void = loadRelatedLists()
            _ = await (reviewsTask, listsTask)
        }
        .sheet(isPresented: $showsStreamSheet) {
            MakerPlaySourceSheet(
                streams: streams,
                reason: streamReason,
                isLoading: isLoadingStreams,
                onSelect: { stream in
                    showsStreamSheet = false
                    play(stream)
                },
                onReload: { Task { await loadStreams() } }
            )
            .rexSheetStyle()
        }
        .fullScreenCover(item: $playingSource) { request in
            RexPlayerView(
                item: request.item,
                playlist: [],
                directSource: request.info
            )
        }
        .rexAlert($alert)
    }

    // MARK: - 头部（对齐 PWA：模糊底 wash + 左封面右信息）

    /// 主标题：番号优先，其次片名。
    private var heroTitle: String {
        if let number = movie?.number, !number.isEmpty { return number }
        if let title = movie?.title, !title.isEmpty { return title }
        return "影片详情"
    }

    /// 副标题：片名（与主标题不同时展示，对应 PWA 的 aka）。
    private var heroSubtitle: String {
        guard let title = movie?.title, !title.isEmpty, title != heroTitle else { return "" }
        return title
    }

    /// 搜索关键词：番号优先，其次片名。
    private var searchQuery: String {
        if let number = movie?.number, !number.isEmpty { return number }
        return movie?.title ?? ""
    }

    /// 一行元信息，顺序与 PWA 一致：日期 · 时长 · 磁力 · 中文字幕 · 评分 · 观看数。
    private var heroMetaLine: String {
        var parts: [String] = []
        if let date = movie?.releaseDate, !date.isEmpty { parts.append(date) }
        if let duration = movie?.duration, duration > 0 { parts.append("\(Int(duration)) 分钟") }
        if let count = movie?.magnetsCount, count > 0 { parts.append("\(count) 个磁力") }
        if movie?.hasCnsub == true { parts.append("中文字幕") }
        if let score = detail?.score, score > 0 { parts.append("评分 \(formatScore(score))") }
        if let watched = detail?.watchedCount, watched > 0 { parts.append("\(watched) 次观看") }
        return parts.joined(separator: " · ")
    }

    /// 封面 / 模糊底统一用入口卡片的同一张图（cover → thumb → preview），列表与详情保持一致。
    private var heroImageURL: String? {
        movie?.artworkURL
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner

            Text(heroTitle)
                .font(.system(size: 25, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            if !heroSubtitle.isEmpty {
                Text(heroSubtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(2)
                    .padding(.top, 7)
            }

            if !heroMetaLine.isEmpty {
                Text(heroMetaLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 10)
            }
        }
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.md)
    }

    /// 顶部横图：与入口卡片同图，16:10 横幅铺满内容宽度。
    private var banner: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                MakerArtwork(heroImageURL, width: 1080)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay(alignment: .topLeading) {
                if let score = detail?.score, score > 0 {
                    scoreBadge(score)
                        .padding(9)
                }
            }
            .shadow(color: Color.black.opacity(0.16), radius: 10, y: 6)
            .shadow(color: Color.black.opacity(0.12), radius: 24, y: 14)
            .accessibilityHidden(true)
    }

    /// 模糊铺底（对齐影视详情 `wash`）：用同一张横图铺底，向下渐隐到页面背景。
    private var wash: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                if let url = heroImageURL {
                    MakerArtwork(url, width: 900)
                        .scaleEffect(1.2)
                        .blur(radius: 36)
                        .saturation(1.35)
                        .opacity(0.62)
                }

                LinearGradient(
                    stops: [
                        .init(color: RexColor.background.opacity(0), location: 0),
                        .init(color: RexColor.background.opacity(0.3), location: 0.42),
                        .init(color: RexColor.background.opacity(0.8), location: 0.78),
                        .init(color: RexColor.background, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // 顶部留白 + 16:10 横图高度，和 hero 的顶部内边距对齐。
            .frame(height: RexSpacing.sm * 2 + (proxy.size.width - RexSpacing.xl * 2) * 10 / 16)
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 海报左上角豆瓣式评分角标。
    private func scoreBadge(_ score: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 9.5, weight: .bold))

            Text(formatScore(score))
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(Color(hex: 0x1A1200))
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            Color(hex: 0xF5C518).opacity(0.96),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    // MARK: - 操作（对齐影视详情：胶囊按钮行）

    private func actionRow() -> some View {
        HStack(spacing: 10) {
            NavigationLink(value: MakerRoute.resourceSearch(searchQuery)) {
                ctaLabel(symbol: "magnifyingglass", title: "资源搜索")
                    .foregroundStyle(searchAccent)
                    .background(searchBackground, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(searchAccent.opacity(0.22), lineWidth: 0.5)
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHint("走服务端资源搜索，直接看资源列表")

            Button {
                guard !isLoadingStreams else { return }
                RexHaptics.tap()
                Task { await loadStreams() }
            } label: {
                ctaLabel(
                    symbol: isLoadingStreams ? nil : "play.rectangle.fill",
                    title: "在线播放"
                )
                .foregroundStyle(RexColor.onBrand)
                .background(RexColor.brandBlue, in: Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isLoadingStreams)
            .accessibilityLabel("在线播放")
            .accessibilityHint("走插件中心的片商插件播放")
        }
        .padding(.top, 22)
    }

    private func ctaLabel(symbol: String?, title: String) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(RexColor.tertiaryText)
            }

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Capsule(style: .continuous))
    }

    /// 搜索按钮配色：与影视详情的蓝色次要操作同调。
    private var searchBackground: Color {
        colorScheme == .dark ? Color(hex: 0x24344D) : Color(hex: 0xE6ECF8)
    }

    private var searchAccent: Color {
        colorScheme == .dark ? Color(hex: 0xCFE0FB) : Color(hex: 0x22406E)
    }

    // MARK: - 演员

    /// 头像在上、名字在下，一行横向滚动；无卡片底、无描边。
    private func actorChips(_ actors: [MakerActor]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(Array(actors.enumerated()), id: \.offset) { _, actor in
                    NavigationLink(value: MakerRoute.actorDetail(id: actor.id, name: actor.name)) {
                        VStack(spacing: 6) {
                            Color.clear
                                .frame(width: 42, height: 42)
                                .overlay {
                                    MakerArtwork(actor.avatarUrl, width: 126)
                                }
                                .clipShape(Circle())

                            Text(actor.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(RexColor.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(width: 62)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityHint("查看演员资料与作品")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - 标签

    private func hasTags(_ detail: MakerMovieDetail) -> Bool {
        !detail.makers.isEmpty
            || !detail.tags.isEmpty
            || isFilled(detail.director)
            || isFilled(detail.series)
            || isFilled(detail.publisher)
    }

    /// PWA `__tag`：片商 / 导演 / 系列可点进作品墙，publisher 与普通标签为纯文本；一行横向滚动。
    private func tagChips(_ detail: MakerMovieDetail) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(detail.makers.prefix(4).enumerated()), id: \.offset) { _, maker in
                    NavigationLink(value: MakerRoute.entity(kind: .maker, id: maker.id, name: maker.name)) {
                        tagPill(maker.name, interactive: true)
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                if let director = detail.director, isFilled(detail.directorId) {
                    NavigationLink(
                        value: MakerRoute.entity(kind: .director, id: detail.directorId ?? "", name: director)
                    ) {
                        tagPill("导演 \(director)", interactive: true)
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                if let series = detail.series, isFilled(detail.seriesId) {
                    NavigationLink(
                        value: MakerRoute.entity(kind: .series, id: detail.seriesId ?? "", name: series)
                    ) {
                        tagPill("系列 \(series)", interactive: true)
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                if let publisher = detail.publisher, isFilled(publisher) {
                    tagPill(publisher, interactive: false)
                }

                ForEach(Array(detail.tags.prefix(6).enumerated()), id: \.offset) { _, tag in
                    tagPill(tag, interactive: false)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func tagPill(_ text: String, interactive: Bool) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(interactive ? RexColor.primaryText : RexColor.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RexColor.field, in: Capsule(style: .continuous))
    }

    // MARK: - 磁力 / 共享资源 / AVDB 资源

    private func magnetRow(_ magnet: MakerMagnet) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(magnet.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)

                if !magnetMeta(magnet).isEmpty {
                    Text(magnetMeta(magnet))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: RexSpacing.sm)

            HStack(spacing: 6) {
                copyButton("复制") { copy(magnet.url) }
                saveButton(magnet.url)
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    private func magnetMeta(_ magnet: MakerMagnet) -> String {
        var parts: [String] = []
        if let size = magnet.size, !size.isEmpty { parts.append(size) }
        if let createdAt = magnet.createdAt, !createdAt.isEmpty { parts.append(createdAt) }
        if magnet.filesCount > 1 { parts.append("\(magnet.filesCount) 个文件") }
        return parts.joined(separator: " · ")
    }

    private func resourceRow(_ resource: MakerResource) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(resourceTitle(resource))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)

                let meta = resourceMeta(resource)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: RexSpacing.sm)

            copyButton("复制") { copy(resource.url) }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    private func resourceTitle(_ resource: MakerResource) -> String {
        let type = resource.type.isEmpty ? "资源" : resource.type.uppercased()
        let suffix = resource.hd ? " · HD" : ""
        return "\(type)\(suffix) · \(resource.name.isEmpty ? "资源" : resource.name)"
    }

    private func resourceMeta(_ resource: MakerResource) -> String {
        var parts: [String] = []
        if resource.sizeBytes > 0 {
            parts.append(String(format: "%.2f GB", Double(resource.sizeBytes) / 1_073_741_824))
        }
        if let label = resource.sourceLabel, !label.isEmpty { parts.append(label) }
        if let hash = resource.hash, !hash.isEmpty { parts.append(hash) }
        return parts.joined(separator: " · ")
    }

    /// 对齐 PWA `TorrentRow`：卡片内不再放预览图，动作统一为「复制」+「转存」。
    private func torrentRow(_ torrent: MakerTorrent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: RexSpacing.sm) {
                    Text(torrent.sourceLabel)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: RexSpacing.sm)

                    if !torrent.downloadUrl.isEmpty {
                        HStack(spacing: 6) {
                            copyButton("复制") { copy(torrent.downloadUrl) }
                            saveButton(torrent.downloadUrl)
                        }
                    }
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

                if !torrent.title.isEmpty {
                    Text(torrent.title)
                        .font(.system(size: 12))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(2)
                }

                let meta = torrentMeta(torrent)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    private func torrentFlags(_ torrent: MakerTorrent) -> [String] {
        var flags: [String] = []
        if torrent.chinese { flags.append("中文") }
        if torrent.uncensored { flags.append("无码") }
        if torrent.uhd { flags.append("4K") }
        else if torrent.hd { flags.append("HD") }
        if torrent.free { flags.append("免费") }
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

    // MARK: - 评论

    private func reviewSectionTitle(_ detail: MakerMovieDetail) -> String {
        detail.reviewsCount > 0 ? "评论（\(detail.reviewsCount)）" : "评论"
    }

    // MARK: - 相关片单

    private func relatedListRow(_ list: MakerRelatedList) -> some View {
        HStack(spacing: RexSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)

                Text("\(list.moviesCount) 部 · \(list.collectionsCount) 收藏")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RexColor.tertiaryText)
            }

            Spacer(minLength: RexSpacing.sm)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.tertiaryText)
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    // MARK: - 海报横滑

    private func posterRail(_ movies: [MakerMovie]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(Array(movies.enumerated()), id: \.offset) { _, item in
                    NavigationLink(value: MakerRoute.movie(item)) {
                        MakerMovieCard(movie: item, width: 168)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityHint("查看影片详情")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// 一行横滑；竖图缩放到与横图同高（90pt），宽度按原图比例，不裁切。
    private func previewRail(_ previews: [MakerPreview]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: RexSpacing.sm) {
                ForEach(Array(previews.enumerated()), id: \.offset) { _, preview in
                    MakerPreviewArtwork(
                        preview.large.isEmpty ? preview.thumb : preview.large,
                        width: 480,
                        height: 90
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
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

            content()
        }
        .padding(.top, 26)
    }

    // MARK: - 骨架

    /// 简介骨架：5 行，行高与正文对齐，避免正文出现时把下方内容整体推下去。
    private var overviewSkeleton: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(0..<5, id: \.self) { index in
                RexSkeleton(width: index == 4 ? 200 : nil, height: 13, cornerRadius: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 演员骨架：放进横向 ScrollView 内，避免骨架把整页撑宽。
    private var actorSkeleton: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(spacing: 6) {
                        RexSkeleton(width: 56, height: 56, cornerRadius: 28)
                        RexSkeleton(width: 48, height: 9, cornerRadius: 4.5)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
    }

    // MARK: - 小组件

    private func copyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.brandBlue)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RexColor.brandBlue.opacity(0.10), in: Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// 转存按钮：磁力 / 种子直存 115 片商目录（`source=maker`），提交中显示进度。
    private func saveButton(_ link: String) -> some View {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSaving = savingLink == trimmed

        return Button {
            Task { await saveTo115(trimmed) }
        } label: {
            HStack(spacing: 4) {
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(RexColor.onBrand)
                }

                Text(isSaving ? "转存中" : "转存")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(RexColor.onBrand)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RexColor.brandGradient, in: Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(savingLink != nil)
        .accessibilityLabel("转存到 115")
    }

    private func isFilled(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 评分去掉多余的 `.0`，与 PWA 原样展示保持一致。
    private func formatScore(_ score: Double) -> String {
        score == score.rounded() ? String(Int(score)) : String(format: "%.1f", score)
    }

    // MARK: - 数据

    private func load() async {
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            detail = try await apiClient.makerMovie(id: movieID)
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    /// 首屏评论（10 条）；失败静默，不打断详情主流程。
    private func loadReviews() async {
        guard let apiClient, reviews.isEmpty else { return }
        do {
            let page = try await apiClient.makerReviews(movieID: movieID, page: 1, limit: 10)
            reviews = page.items
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
        }
    }

    /// 相关片单；失败静默。
    private func loadRelatedLists() async {
        guard let apiClient, relatedLists.isEmpty else { return }
        do {
            relatedLists = try await apiClient.makerRelatedLists(movieID: movieID)
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
        }
    }

    private func loadStreams() async {
        guard let apiClient, let movie, !isLoadingStreams else { return }
        isLoadingStreams = true
        defer { isLoadingStreams = false }

        do {
            let result = try await apiClient.makerPlaySources(
                movieID: movie.id,
                number: movie.number,
                title: movie.title
            )
            streams = result.streams
            streamReason = result.reason

            if result.streams.count == 1, let only = result.streams.first, only.playable {
                play(only)
                return
            }
            showsStreamSheet = true
        } catch {
            streams = []
            streamReason = error.localizedDescription
            showsStreamSheet = true
        }
    }

    private func play(_ stream: MakerStream) {
        guard stream.playable else {
            if !stream.url.isEmpty, let url = URL(string: stream.url) {
                openURL(url)
            }
            return
        }
        guard let url = URL(string: stream.url) else { return }

        let key = "maker:\(movieID):\(stream.id)"
        let item = PanItem(
            id: key,
            name: movie?.displayTitle ?? "在线播放",
            isDir: false,
            size: 0,
            pickcode: key,
            sha1: "",
            updatedAt: 0
        )
        playingSource = MakerPlayRequest(
            item: item,
            info: PanPlayInfo(url: url, headers: [:], expiresIn: 0)
        )
        RexHaptics.tap()
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        RexHaptics.success()
        alert = .success("已复制链接")
    }

    /// 转存到 115 片商目录。
    private func saveTo115(_ link: String) async {
        guard let apiClient, savingLink == nil, !link.isEmpty else { return }
        savingLink = link
        defer { savingLink = nil }

        do {
            let result = try await apiClient.panTransfer(urls: [link], source: "maker")
            if result.added > 0 {
                RexHaptics.success()
                let dest = result.destName.isEmpty ? "" : "（\(result.destName)）"
                alert = .success("已转存到 115\(dest)")
            } else {
                RexHaptics.error()
                let detail = result.failed.map(\.message).joined(separator: "；")
                alert = .failure(detail.isEmpty ? "转存失败" : detail)
            }
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }
}

// MARK: - 评论行

/// PWA `ReviewRow`：用户名 + 星星评分 + 点赞数 + 正文。
struct MakerReviewRow: View {
    let review: MakerReview

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: RexSpacing.sm) {
                Text(review.username)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                if let score = review.score, score > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .bold))

                        Text(score == score.rounded() ? String(Int(score)) : String(format: "%.1f", score))
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundStyle(RexColor.warning)
                }

                if review.likesCount > 0 {
                    Text("\(review.likesCount) 赞")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RexColor.tertiaryText)
                }

                Spacer(minLength: 0)
            }

            Text(review.content)
                .font(.system(size: 13.5))
                .foregroundStyle(RexColor.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }
}

// MARK: - 播放请求

private struct MakerPlayRequest: Identifiable {
    let item: PanItem
    let info: PanPlayInfo

    var id: String { item.id }
}

// MARK: - 播放源选择

private struct MakerPlaySourceSheet: View {
    let streams: [MakerStream]
    let reason: String
    let isLoading: Bool
    var onSelect: (MakerStream) -> Void
    var onReload: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    if isLoading {
                        HStack(spacing: RexSpacing.sm) {
                            ProgressView()
                            Text("正在聚合片源…")
                                .font(RexFont.footnote)
                                .foregroundStyle(RexColor.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 80)
                    } else if streams.isEmpty {
                        RexInlineNotice(
                            title: "没有可用的片源",
                            message: reason.isEmpty ? "该影片暂时没有在线播放源，可以复制磁力链接离线观看。" : reason,
                            tone: .warning,
                            actionTitle: "重新查找"
                        ) {
                            onReload()
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(streams.enumerated()), id: \.element.id) { index, stream in
                                if index > 0 { SettingsDivider() }

                                Button {
                                    RexHaptics.tap()
                                    onSelect(stream)
                                } label: {
                                    HStack(spacing: RexSpacing.md) {
                                        Image(systemName: stream.playable ? "play.circle.fill" : "arrow.up.right.circle")
                                            .font(.system(.title3))
                                            .foregroundStyle(stream.playable ? RexColor.brandBlue : RexColor.secondaryText)
                                            .frame(width: 26)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stream.displayTitle)
                                                .font(RexFont.row)
                                                .foregroundStyle(RexColor.primaryText)
                                                .lineLimit(2)

                                            Text(stream.provider)
                                                .font(RexFont.caption2)
                                                .foregroundStyle(RexColor.tertiaryText)
                                        }

                                        Spacer(minLength: RexSpacing.sm)

                                        Image(systemName: "chevron.right")
                                            .font(.system(.caption, weight: .semibold))
                                            .foregroundStyle(RexColor.tertiaryText)
                                    }
                                    .padding(.horizontal, RexSpacing.lg)
                                    .frame(minHeight: RexLayout.rowHeight)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RexRowButtonStyle())
                            }
                        }
                        .rexCard()

                        if !reason.isEmpty {
                            RexNote(text: reason)
                        }
                    }
                }
                .padding(RexSpacing.xl)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(RexPageBackground())
            .navigationTitle("选择播放源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private extension MakerMovieDetail {
    var summarySafe: String {
        (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
