import SwiftUI

/// 影视详情：全宽背景图 + 海报浮层 + 元信息，下面是简介、剧集、演职员（真实头像）、
/// 相关推荐与预告片，并提供一个直接跳到 RexHub 资源搜索的入口。
struct MediaDetailView: View {
    let item: MediaItem

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(MediaRouter.self) private var router

    @State private var detail: MediaDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isScrolled = false
    @State private var overviewExpanded = false
    @State private var selectedSeason = 1
    @State private var isPreparingSearch = false
    @State private var retryToken = 0

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: isScrolled ? displayTitle : "",
                leading: .back(action: { dismiss() }),
                actions: [searchNavAction],
                isScrolled: isScrolled
            )

            GeometryReader { proxy in
                ScrollView {
                    content(width: min(proxy.size.width, RexLayout.contentMaxWidth))
                        .padding(.bottom, RexSpacing.huge)
                        .frame(maxWidth: RexLayout.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                }
                .rexScrollTracking("mediaDetailScroll", isScrolled: $isScrolled)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(RexPageBackground())
        .task(id: retryToken) { await load() }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.xxl) {
            header

            actionSection

            if isLoading {
                loadingSkeleton
            } else if let errorMessage {
                failureCard(errorMessage)
            } else if let detail {
                overviewSection(detail)
                episodesSection(detail)
                castSection(detail)
                recommendationsSection(detail, width: width)
                trailerSection(detail)
            }
        }
    }

    // MARK: - 头图与信息

    private var displayTitle: String {
        if let detail, !detail.title.isEmpty { return detail.title }
        return item.title
    }

    private var heroBackdrop: String {
        if let detail {
            return detail.backdrop.isEmpty ? detail.poster : detail.backdrop
        }
        return item.backdrop.isEmpty ? item.poster : item.backdrop
    }

    private var heroPoster: String {
        if let detail, !detail.poster.isEmpty { return detail.poster }
        return item.poster
    }

    /// 背景图铺满整行，底部渐隐到页面背景；海报向上抬起压住图片下沿，
    /// 标题与元信息留在纯背景上，两种主题下都有稳定对比度。
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            backdrop

            VStack(alignment: .leading, spacing: RexSpacing.md) {
                HStack(alignment: .top, spacing: RexSpacing.lg) {
                    posterThumb
                        .padding(.top, -36)
                    titleBlock
                }

                metaChipsRow
                genresLine
            }
            .padding(.horizontal, RexSpacing.xl)
            .padding(.top, RexSpacing.md)
        }
    }

    private var backdrop: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                MediaArtwork(path: heroBackdrop, size: "w780")
            }
            .overlay {
                // 顶部薄遮罩，避免亮图与顶栏硬切。
                LinearGradient(
                    colors: [.black.opacity(0.26), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: RexColor.background.opacity(0), location: 0),
                        .init(color: RexColor.background.opacity(0.55), location: 0.4),
                        .init(color: RexColor.background, location: 0.85)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 72)
            }
            .clipped()
    }

    private var posterThumb: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: 92)
            .overlay {
                MediaArtwork(path: heroPoster, size: "w185")
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.26), radius: 12, y: 6)
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(displayTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let tagline = detail?.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.system(size: 12.5, weight: .medium))
                    .italic()
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metaChipsRow: some View {
        let isMovie = detail?.isMovie ?? item.isMovie
        let year = detail?.year.isEmpty == false ? (detail?.year ?? "") : item.year
        let rating = detail?.rating ?? item.rating
        let runtime = detail?.runtime ?? ""

        HStack(spacing: 6) {
            if let rating {
                MediaRatingBadge(rating: rating)
            }

            infoChip(isMovie ? "电影" : "剧集", symbol: isMovie ? "film" : "tv")

            if !year.isEmpty {
                infoChip(year)
            }

            if !runtime.isEmpty {
                infoChip(runtime, symbol: "clock")
            }
        }
    }

    private func infoChip(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .medium))
            }

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(RexColor.secondaryText)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RexColor.field, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(RexColor.fieldBorder, lineWidth: 0.75)
        }
    }

    @ViewBuilder
    private var genresLine: some View {
        let genres = detail?.genres ?? []

        if !genres.isEmpty {
            Text(genres.prefix(5).joined(separator: " · "))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RexColor.tertiaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 操作

    private var searchNavAction: RexNavAction {
        RexNavAction(systemImage: "magnifyingglass", label: "搜索资源", action: {
            Task { await prepareSearch() }
        })
    }

    private var actionSection: some View {
        let hasTrailer = (detail?.trailers ?? []).contains { URL(string: $0.url) != nil }

        return HStack(spacing: RexSpacing.md) {
            Button {
                Task { await prepareSearch() }
            } label: {
                HStack(spacing: RexSpacing.sm) {
                    if isPreparingSearch {
                        ProgressView()
                            .controlSize(.small)
                            .tint(RexColor.onBrand)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                    }

                    Text(isPreparingSearch ? "正在准备来源…" : "在 RexHub 搜索资源")
                }
            }
            .buttonStyle(RexPrimaryButtonStyle(height: 48))
            .disabled(isPreparingSearch)
            .accessibilityHint("用影片标题搜索已接入的资源库")

            if hasTrailer {
                Button {
                    RexHaptics.tap()
                    if let first = detail?.trailers.first(where: { URL(string: $0.url) != nil }),
                       let url = URL(string: first.url) {
                        openURL(url)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .frame(width: 48, height: 48)
                        .background(RexColor.surface, in: RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous)
                                .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("播放预告片")
            }
        }
        .padding(.horizontal, RexSpacing.xl)
    }

    private func prepareSearch() async {
        guard !isPreparingSearch else { return }
        isPreparingSearch = true
        defer { isPreparingSearch = false }

        var sources: [SearchSource] = []
        if let apiClient, let services = try? await apiClient.searchServices() {
            sources = services.map { SearchSource(id: $0.id, name: $0.name) }
        }
        RexHaptics.tap()
        router.push(.search(MediaSearchTarget(keyword: displayTitle, sources: sources)))
    }

    // MARK: - 状态

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            RexSkeleton(width: 150, height: 18, cornerRadius: 8)
            RexSkeleton(height: 12, cornerRadius: 6)
            RexSkeleton(height: 12, cornerRadius: 6)
            RexSkeleton(width: 220, height: 12, cornerRadius: 6)

            HStack(spacing: RexSpacing.lg) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(spacing: 6) {
                        RexSkeleton(width: 62, height: 62, cornerRadius: 31)
                        RexSkeleton(width: 52, height: 10, cornerRadius: 5)
                    }
                }
            }
            .padding(.top, RexSpacing.sm)
        }
        .padding(.horizontal, RexSpacing.xl)
        .accessibilityHidden(true)
    }

    private func failureCard(_ message: String) -> some View {
        RexStateCard(
            symbol: "exclamationmark.triangle",
            title: "详情加载失败",
            message: message,
            tone: .warning,
            actionTitle: "重试"
        ) {
            retryToken += 1
            isLoading = true
        }
        .padding(.horizontal, RexSpacing.xl)
    }

    // MARK: - 简介

    @ViewBuilder
    private func overviewSection(_ detail: MediaDetail) -> some View {
        if !detail.overview.isEmpty {
            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                RexSectionHeader(title: "简介")

                Text(detail.overview)
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineSpacing(4)
                    .lineLimit(overviewExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    RexHaptics.tap()
                    withAnimation(RexMotion.standard) {
                        overviewExpanded.toggle()
                    }
                } label: {
                    Text(overviewExpanded ? "收起" : "展开")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())

                if !detail.director.isEmpty || !detail.writer.isEmpty {
                    TagFlow(spacing: 6) {
                        if !detail.director.isEmpty {
                            RexBadge(
                                text: "导演 " + detail.director.joined(separator: "、"),
                                tint: RexColor.secondaryText
                            )
                        }

                        if !detail.writer.isEmpty {
                            RexBadge(
                                text: "编剧 " + detail.writer.joined(separator: "、"),
                                tint: RexColor.secondaryText
                            )
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, RexSpacing.xl)
        }
    }

    // MARK: - 演职员

    @ViewBuilder
    private func castSection(_ detail: MediaDetail) -> some View {
        let people = castPeople(detail)

        if !people.isEmpty {
            VStack(alignment: .leading, spacing: RexSpacing.md) {
                RexSectionHeader(title: "演职员")
                    .padding(.horizontal, RexSpacing.xl)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: RexSpacing.lg) {
                        ForEach(people) { person in
                            castCell(person)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, RexSpacing.xl, for: .scrollContent)
            }
        }
    }

    /// 优先用带头像的演员；老服务端只有姓名时退化成首字头像。
    private func castPeople(_ detail: MediaDetail) -> [MediaCastMember] {
        let people = detail.castPeople ?? []
        if !people.isEmpty { return people }
        return detail.cast.map { MediaCastMember(name: $0, character: "", profile: "") }
    }

    private func castCell(_ person: MediaCastMember) -> some View {
        VStack(spacing: 7) {
            castAvatar(person)
                .frame(width: 62, height: 62)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.14), radius: 6, y: 3)

            VStack(spacing: 2) {
                Text(person.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)
                    // 固定两行高度，长名字换行时角色仍对齐。
                    .frame(height: 30, alignment: .top)

                if !person.character.isEmpty {
                    Text(person.character)
                        .font(.system(size: 10.5))
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: 76)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func castAvatar(_ person: MediaCastMember) -> some View {
        if person.profile.isEmpty {
            ZStack {
                Circle()
                    .fill(RexColor.brandBlue.opacity(0.10))

                Text(initials(person.name))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(RexColor.brandBlue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else {
            MediaArtwork(path: person.profile, size: "w185")
        }
    }

    private func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        // 中文取首字，英文名取首字母。
        return String(first)
    }

    // MARK: - 相关推荐

    @ViewBuilder
    private func recommendationsSection(_ detail: MediaDetail, width: CGFloat) -> some View {
        let items = detail.recommendations ?? []

        if !items.isEmpty {
            VStack(alignment: .leading, spacing: RexSpacing.md) {
                RexSectionHeader(
                    title: "相关推荐",
                    detail: detail.isMovie ? "相似题材的电影" : "相似题材的剧集"
                )
                .padding(.horizontal, RexSpacing.xl)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(items) { related in
                            Button {
                                RexHaptics.tap()
                                router.push(.detail(related))
                            } label: {
                                MediaPosterCard(
                                    item: related,
                                    width: posterWidth(for: width)
                                )
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityHint("查看详情")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, RexSpacing.xl, for: .scrollContent)
            }
        }
    }

    /// 与首页海报墙一致：一屏三张，右侧留一点下一张的暗示。
    private func posterWidth(for width: CGFloat) -> CGFloat {
        min(140, max(100, (width - RexSpacing.xl * 2 - 20) / 3))
    }

    // MARK: - 预告片

    @ViewBuilder
    private func trailerSection(_ detail: MediaDetail) -> some View {
        let trailers = detail.trailers.filter { URL(string: $0.url) != nil }

        if !trailers.isEmpty {
            VStack(alignment: .leading, spacing: RexSpacing.md) {
                RexSectionHeader(title: "预告片")
                    .padding(.horizontal, RexSpacing.xl)

                ScrollView(.horizontal) {
                    HStack(spacing: RexSpacing.sm) {
                        ForEach(trailers, id: \.url) { trailer in
                            Button {
                                RexHaptics.tap()
                                if let url = URL(string: trailer.url) { openURL(url) }
                            } label: {
                                HStack(spacing: RexSpacing.sm) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(RexColor.onBrand)
                                        .frame(width: 24, height: 24)
                                        .background(RexColor.brandBlue, in: Circle())

                                    Text(trailer.name.isEmpty ? "观看预告" : trailer.name)
                                        .font(.system(.footnote, weight: .medium))
                                        .foregroundStyle(RexColor.primaryText)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, RexSpacing.md)
                                .frame(height: 44)
                                .rexCard(cornerRadius: 22, hasShadow: false)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, RexSpacing.xl, for: .scrollContent)
            }
        }
    }

    // MARK: - 剧集

    @ViewBuilder
    private func episodesSection(_ detail: MediaDetail) -> some View {
        let seasons = detail.seasons

        if !seasons.isEmpty {
            let current = seasons.first { $0.season == selectedSeason } ?? seasons[0]

            VStack(alignment: .leading, spacing: RexSpacing.md) {
                RexSectionHeader(
                    title: "剧集",
                    detail: "共 \(detail.videos.count) 集 · 第 \(current.season) 季"
                )
                .padding(.horizontal, RexSpacing.xl)

                if seasons.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: RexSpacing.sm) {
                            ForEach(seasons, id: \.season) { season in
                                seasonChip(season.season, count: season.episodes.count)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .contentMargins(.horizontal, RexSpacing.xl, for: .scrollContent)
                }

                VStack(spacing: RexSpacing.sm) {
                    ForEach(current.episodes) { episode in
                        episodeRow(episode)
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
            }
        }
    }

    private func seasonChip(_ season: Int, count: Int) -> some View {
        let selected = season == selectedSeason

        return Button {
            guard !selected else { return }
            RexHaptics.selection()
            withAnimation(RexMotion.spring) {
                selectedSeason = season
            }
        } label: {
            Text("第 \(season) 季 · \(count) 集")
                .font(.system(.footnote, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? RexColor.onBrand : RexColor.primaryText)
                .lineLimit(1)
                .padding(.horizontal, RexSpacing.md)
                .frame(height: 34)
                .background {
                    Capsule(style: .continuous)
                        .fill(selected
                              ? AnyShapeStyle(RexColor.brandGradient)
                              : AnyShapeStyle(RexColor.surface))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(selected ? Color.clear : RexColor.cardBorder, lineWidth: 0.75)
                }
                .contentShape(Capsule(style: .continuous))
                .frame(minHeight: RexLayout.minTouch)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func episodeRow(_ episode: MediaVideo) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.md) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 108)
                .overlay {
                    MediaArtwork(path: episode.still, size: "w300")
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(episode.code)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RexColor.brandBlue)

                    Text(episode.title.isEmpty ? "第 \(episode.episode) 集" : episode.title)
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let rating = episode.rating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color(hex: 0xFFC93C))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(RexColor.secondaryText)
                        }
                    }
                }

                if !episode.overview.isEmpty {
                    Text(episode.overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .rexCard(cornerRadius: 14, hasShadow: false)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 数据

    private func load() async {
        guard let apiClient else {
            isLoading = false
            errorMessage = "服务未连接，请稍后重试"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let loaded = try await apiClient.mediaDetail(id: item.id)
            guard !Task.isCancelled else { return }
            detail = loaded
            selectedSeason = loaded.seasons.first?.season ?? 1
        } catch {
            guard !(error is CancellationError), (error as? APIError) != .cancelled else { return }
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

/// 简易流式布局：类型、地区这类短标签数量不定，自动换行。
private struct TagFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            maxWidth = max(maxWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: proposal.width ?? maxWidth,
            height: y + rowHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
