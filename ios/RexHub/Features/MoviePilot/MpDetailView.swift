import SwiftUI

/// 影视详情：MoviePilot 元数据 + 在线片源（插件中心 MorePlay 能力）。
struct MpDetailView: View {
    let item: MpItem

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var detail: MpDetail?
    @State private var related: MpRelated?
    @State private var streams: [MediaStreamItem] = []
    @State private var streamReason = ""
    @State private var isLoading = true
    @State private var isLoadingStreams = false
    @State private var errorText: String?
    @State private var showsStreamSheet = false
    /// 流式拉取片源的任务：弹窗关掉就取消，别在后台空跑。
    @State private var streamTask: Task<Void, Never>?
    @State private var playing: MpPlayRequest?
    @State private var isScrolled = false
    /// 「影视搜索」跳转目标。
    @State private var searchTarget: MpSearchTarget?
    /// 「PT 搜索」选择方式弹窗。
    @State private var showsPtPicker = false
    /// 弹窗里选中的搜索方式，等 sheet 收起后再跳转。
    @State private var pendingPtArea: String?
    /// 「PT 搜索」跳转目标。
    @State private var ptTarget: MpPtSearchTarget?

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: detail?.title ?? item.title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                ZStack(alignment: .top) {
                    // 对齐 PWA：海报模糊铺底，向下淡出到页面背景。
                    wash

                    VStack(alignment: .leading, spacing: 0) {
                        hero

                        if let errorText, detail == nil {
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

                        if let detail, !detail.cast.isEmpty {
                            section("主演") {
                                castRow(detail.cast)
                            }
                        } else if isLoading {
                            section("主演") {
                                castSkeleton
                            }
                        }

                        if let detail, !detail.overviewSafe.isEmpty {
                            section("简介") {
                                RexExpandableText(text: detail.overviewSafe)
                            }
                        } else if isLoading {
                            section("简介") {
                                overviewSkeleton
                            }
                        }

                        actions
                            .padding(.top, 26)

                        if !relatedItems.isEmpty {
                            section("相似推荐") {
                                relatedRail(relatedItems)
                            }
                        } else if isLoading {
                            section("相似推荐") {
                                relatedSkeleton
                            }
                        }
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .background(RexScrollOffsetReader(space: "mpDetailScroll"))
                }
            }
            .rexScrollTracking("mpDetailScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load() }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 从二级页返回时保留已加载内容，不重新请求。
            if detail == nil { await load() }
        }
        .navigationDestination(item: $searchTarget) { target in
            ScopeSearchView(keyword: target.keyword, scope: .movie)
                .rexPushedScreen()
        }
        .navigationDestination(item: $ptTarget) { target in
            MpPtSearchView(target: target)
                .rexPushedScreen()
        }
        .sheet(isPresented: $showsPtPicker, onDismiss: commitPtArea) {
            MpPtPickSheet(
                keyword: ptKeyword,
                imdbId: (detail?.imdbId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ) { area in
                pendingPtArea = area
                showsPtPicker = false
            }
            .rexSheetStyle(detents: [.height(340)])
        }
        .sheet(isPresented: $showsStreamSheet, onDismiss: cancelStreamLoading) {
            MpStreamSheet(
                streams: streams,
                reason: streamReason,
                isLoading: isLoadingStreams,
                onSelect: { stream in
                    showsStreamSheet = false
                    play(stream)
                },
                onReload: { startStreamLoading() }
            )
            .rexSheetStyle()
        }
        .fullScreenCover(item: $playing) { request in
            RexPlayerView(item: request.item, playlist: [], directSource: request.info)
        }
    }

    // MARK: - 顶部铺底

    /// 海报固定尺寸：铺底高度按它推算，保证海报上下留白一致。
    private let posterSize = CGSize(width: 132, height: 198)

    private var wash: some View {
        ZStack(alignment: .bottom) {
            MpArtwork(url: posterURL, showsProgress: false)
                .scaleEffect(1.2)
                .blur(radius: 36)
                .saturation(1.35)
                .opacity(0.62)

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
        // 上留白 + 海报 + 等量下留白，和 hero 的 top 内边距对齐。
        .frame(height: RexSpacing.sm * 2 + posterSize.height)
        .frame(maxWidth: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 头部

    private var hero: some View {
        HStack(alignment: .top, spacing: RexSpacing.lg) {
            poster

            VStack(alignment: .leading, spacing: 0) {
                Text(displayTitle)
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !akaLine.isEmpty {
                    Text(akaLine.joined(separator: " · "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(2)
                        .padding(.top, 7)
                }

                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.top, 10)
                }

                metaTags
                    .padding(.top, 7)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.md)
    }

    private var poster: some View {
        MpArtwork(url: posterURL)
            .frame(width: posterSize.width, height: posterSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay(alignment: .topLeading) {
                if let rating = detail?.rating ?? item.rating, rating > 0 {
                    scoreBadge(rating)
                        .padding(8)
                }
            }
            .shadow(color: Color.black.opacity(0.16), radius: 10, y: 6)
            .shadow(color: Color.black.opacity(0.12), radius: 24, y: 14)
    }

    /// 海报左上角豆瓣式评分角标。
    private func scoreBadge(_ rating: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 9.5, weight: .bold))

            Text(String(format: "%.1f", rating))
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

    private var metaTags: some View {
        MpTagFlow(spacing: 6, lineSpacing: 6) {
            ForEach(Array((detail?.genres ?? []).prefix(4)), id: \.self) { genre in
                MpMetaTag(text: genre)
            }

            ForEach(Array((detail?.countries ?? []).prefix(2)), id: \.self) { country in
                MpMetaTag(text: Self.shortCountry(country), tone: .place)
            }

            if let imdb = detail?.imdbId, !imdb.isEmpty {
                MpMetaTag(text: imdb, tone: .imdb)
            }
        }
    }

    // MARK: - 操作

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                RexHaptics.tap()
                searchTarget = MpSearchTarget(keyword: searchKeyword)
            } label: {
                ctaLabel(symbol: "magnifyingglass", title: "影视搜索")
                    .foregroundStyle(RexColor.onBrand)
                    .background(RexColor.brandBlue, in: Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(displayTitle.isEmpty)

            Button {
                RexHaptics.tap()
                showsPtPicker = true
            } label: {
                ctaLabel(symbol: "externaldrive.fill", title: "PT搜索")
                    .foregroundStyle(ptAccent)
                    .background(ptBackground, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(ptBorder, lineWidth: 0.5)
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(ptKeyword.isEmpty)

            Button {
                guard !isLoadingStreams else { return }
                RexHaptics.tap()
                startStreamLoading()
            } label: {
                ctaLabel(symbol: isLoadingStreams ? nil : "play.rectangle.fill", title: "在线播放")
                    .foregroundStyle(streamAccent)
                    .background(streamBackground, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(streamBorder, lineWidth: 0.5)
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isLoadingStreams)
        }
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

    private var streamBackground: Color {
        colorScheme == .dark ? Color(hex: 0x2F2B48) : Color(hex: 0xE8E5FB)
    }

    private var streamAccent: Color {
        colorScheme == .dark ? Color(hex: 0xCFC7FF) : Color(hex: 0x3D358F)
    }

    private var streamBorder: Color {
        streamAccent.opacity(0.22)
    }

    /// 对齐 PWA `--pt` 配色。
    private var ptBackground: Color {
        colorScheme == .dark ? Color(hex: 0x24344D) : Color(hex: 0xE6ECF8)
    }

    private var ptAccent: Color {
        colorScheme == .dark ? Color(hex: 0xCFE0FB) : Color(hex: 0x22406E)
    }

    private var ptBorder: Color {
        colorScheme == .dark
            ? Color(hex: 0x6E96D2).opacity(0.28)
            : Color(hex: 0x3A5C96).opacity(0.22)
    }

    // MARK: - PT 搜索

    /// 原片名优先，空则回退主标题（对齐 PWA `defaultKeyword`）。
    private var ptKeyword: String {
        let candidates = [detail?.originalTitle, item.originalTitle, displayTitle]
        for candidate in candidates {
            let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        return displayTitle
    }

    private func commitPtArea() {
        guard let area = pendingPtArea else { return }
        pendingPtArea = nil

        ptTarget = MpPtSearchTarget(
            keyword: ptKeyword,
            area: area,
            source: detail?.source ?? item.source,
            mediaId: detail?.id ?? item.id,
            mediaType: detail?.mediaType ?? item.mediaType,
            title: displayTitle,
            originalTitle: detail?.originalTitle ?? item.originalTitle ?? "",
            year: detail?.year ?? item.year ?? "",
            posterUrl: posterURL ?? ""
        )
    }

    // MARK: - 其它区块

    private func castRow(_ cast: [MpCast]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(Array(cast.prefix(12))) { person in
                    NavigationLink(
                        value: MpRoute.person(
                            MpPersonRef(
                                source: detail?.source ?? item.source,
                                id: person.id,
                                name: person.name,
                                avatarUrl: person.avatarUrl
                            )
                        )
                    ) {
                        VStack(spacing: 6) {
                            MpArtwork(url: person.avatarUrl, fallbackSymbol: "person.fill")
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                                }

                            Text(person.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(RexColor.secondaryText)
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityHint("查看该影人的作品")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var castSkeleton: some View {
        // 骨架宽度会超出可视区域，必须放进横向 ScrollView 内，否则会把整页撑宽。
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

    /// 简介骨架：5 行，行高与正文对齐，避免正文出现时把下方按钮整体推下去。
    private var overviewSkeleton: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(0..<5, id: \.self) { index in
                RexSkeleton(width: index == 4 ? 200 : nil, height: 13, cornerRadius: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 相似推荐骨架：卡片总宽超出屏幕，同样放进横向 ScrollView 内。
    private var relatedSkeleton: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        RexSkeleton(width: 108, height: 162, cornerRadius: RexRadius.control)
                        RexSkeleton(width: 76, height: 11, cornerRadius: 5)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
    }

    private func relatedRail(_ items: [MpItem]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(items) { related in
                    NavigationLink(value: MpRoute.detail(related)) {
                        MpPosterCard(item: related, width: 108)
                    }
                    .buttonStyle(PressableButtonStyle())
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

    // MARK: - 展示数据

    private var posterURL: String? { detail?.posterUrl ?? item.posterUrl }

    private var displayTitle: String { detail?.title ?? item.title }

    /// 原片名 / 别名：去重、排除主标题，最多两条（对齐 PWA `pickAka`）。
    private var akaLine: [String] {
        var candidates: [String] = []
        if let original = detail?.originalTitle ?? item.originalTitle {
            candidates.append(original)
        }
        candidates.append(contentsOf: detail?.aka ?? item.aka)

        var seen = Set<String>()
        var out: [String] = []
        for raw in candidates {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != displayTitle, !seen.contains(text) else { continue }
            seen.insert(text)
            out.append(text)
            if out.count == 2 { break }
        }
        return out
    }

    /// 影视搜索关键词：主名 + 原名 / 别名（仅中英），去重最多两条，用「，」拼接（对齐 PWA `buildMediaSearchTerms`）。
    private var searchKeyword: String {
        var candidates: [String] = [displayTitle]
        if let original = detail?.originalTitle ?? item.originalTitle {
            candidates.append(original)
        }
        candidates.append(contentsOf: detail?.aka ?? item.aka)

        var seen = Set<String>()
        var terms: [String] = []
        for (index, raw) in candidates.enumerated() {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.count > 60 { text = String(text.prefix(60)) }
            guard text.count >= 2 else { continue }
            // 主名无条件保留；别名只取中英，日文假名 / 韩文会污染搜索。
            if index > 0, containsKanaOrHangul(text) { continue }
            guard seen.insert(text.lowercased()).inserted else { continue }
            terms.append(text)
            if terms.count == 2 { break }
        }
        return terms.joined(separator: "，")
    }

    /// 是否含日文假名 / 韩文（对齐 PWA `isZhEnSearchable` 的排除口径）。
    private func containsKanaOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,   // 平假名 + 片假名
                 0x1100...0x11FF,   // 韩文字母
                 0x3130...0x318F,   // 韩文兼容字母
                 0xAC00...0xD7AF:   // 韩文音节
                return true
            default:
                return false
            }
        }
    }

    /// `年份 · 电影/剧集 · N 分钟`
    private var metaLine: String {
        var parts: [String] = []
        if let year = detail?.year ?? item.year, !year.isEmpty {
            parts.append(year)
        }
        parts.append(item.isTV ? "剧集" : "电影")
        if let runtime = detail?.runtime, runtime > 0 {
            parts.append("\(runtime) 分钟")
        }
        return parts.joined(separator: " · ")
    }

    /// 相似推荐：合并并去重，排除自身，最多 12 条。
    private var relatedItems: [MpItem] {
        guard let related else { return [] }
        var seen = Set<String>()
        var out: [MpItem] = []
        for row in related.recommendations + related.similar {
            let key = "\(row.source)-\(row.id)"
            guard !seen.contains(key), row.id != item.id else { continue }
            seen.insert(key)
            out.append(row)
            if out.count >= 12 { break }
        }
        return out
    }

    /// 地区名转中文简称，对齐 PWA `shortCountry`。
    private static func shortCountry(_ name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return countryShort[key] ?? key
    }

    private static let countryShort: [String: String] = [
        "United States of America": "美国",
        "United States": "美国",
        "USA": "美国",
        "United Kingdom": "英国",
        "UK": "英国",
        "Japan": "日本",
        "China": "中国",
        "Hong Kong": "中国香港",
        "Taiwan": "中国台湾",
        "South Korea": "韩国",
        "Korea": "韩国",
        "France": "法国",
        "Germany": "德国",
        "Italy": "意大利",
        "Spain": "西班牙",
        "Canada": "加拿大",
        "Australia": "澳大利亚",
        "India": "印度",
        "Thailand": "泰国",
        "Russia": "俄罗斯"
    ]

    // MARK: - 数据

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
            async let detailTask = apiClient.mpDetail(
                source: item.source,
                id: item.id,
                mediaType: item.mediaType
            )
            async let relatedTask = apiClient.mpRelated(
                source: item.source,
                id: item.id,
                mediaType: item.mediaType
            )
            let value = try await detailTask
            detail = value
            related = try? await relatedTask
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    /// 点按钮先弹窗，再流式拉片源：命中一个站点就追加一批。
    private func startStreamLoading() {
        guard !isLoadingStreams else { return }
        streamTask = Task { await loadStreams() }
    }

    private func cancelStreamLoading() {
        streamTask?.cancel()
        streamTask = nil
        isLoadingStreams = false
    }

    private func loadStreams() async {
        guard let apiClient else { return }

        streams = []
        streamReason = ""
        isLoadingStreams = true
        showsStreamSheet = true

        let live = apiClient.mediaStreamsLive(
            title: detail?.title ?? item.title,
            year: detail?.year ?? item.year ?? "",
            mediaType: item.isTV ? "tv" : "movie"
        )

        do {
            for try await event in live {
                switch event {
                case .site(let items):
                    guard !items.isEmpty else { continue }
                    var known = Set(streams.map(\.id))
                    let fresh = items.filter { known.insert($0.id).inserted }
                    if !fresh.isEmpty { streams.append(contentsOf: fresh) }
                case .done(let reason):
                    streamReason = reason
                }
            }
        } catch {
            // 弹窗被关掉时的取消不当成失败。
            if !Task.isCancelled, (error as? APIError) != .cancelled {
                streamReason = error.localizedDescription
            }
        }

        isLoadingStreams = false
    }

    private func play(_ stream: MediaStreamItem) {
        guard let apiClient else { return }
        let raw = stream.url.isEmpty ? stream.externalUrl : stream.url
        // MorePlay 下发的是同源的 /api/media/moreplay-proxy，直接补全主机即可；
        // 其它外链仍走 stream-proxy 透传（防盗链）。
        let url: URL?
        if raw.hasPrefix("/") {
            url = apiClient.absoluteURL(forSameOriginPath: raw)
        } else {
            url = apiClient.mediaStreamProxyURL(raw: raw)
        }
        guard let url else { return }
        startPlayback(url, headers: apiClient.authorizationHeaders, stream: stream)
    }

    private func startPlayback(_ url: URL, headers: [String: String], stream: MediaStreamItem) {
        let key = "mp:\(item.source):\(item.id):\(stream.id)"
        let playerItem = PanItem(
            id: key,
            name: detail?.title ?? item.title,
            isDir: false,
            size: 0,
            pickcode: key,
            sha1: "",
            updatedAt: 0
        )
        playing = MpPlayRequest(
            item: playerItem,
            info: PanPlayInfo(url: url, headers: headers, expiresIn: 0)
        )
        RexHaptics.tap()
    }
}

private struct MpPlayRequest: Identifiable {
    let item: PanItem
    let info: PanPlayInfo

    var id: String { item.id }
}

// MARK: - 详情页小组件

/// 「影视搜索」的跳转参数。
private struct MpSearchTarget: Identifiable, Hashable {
    let keyword: String

    var id: String { keyword }
}

/// 元信息胶囊：类型 / 地区 / IMDb 三种色调。
private struct MpMetaTag: View {
    enum Tone {
        case genre
        case place
        case imdb
    }

    let text: String
    var tone: Tone = .genre

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RexColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(RexColor.fieldBorder, lineWidth: 0.5)
            }
    }

    private var foreground: Color {
        switch tone {
        case .genre: RexColor.secondaryText
        case .place: RexColor.tertiaryText
        case .imdb: Color(hex: 0xB07D00)
        }
    }
}

/// 标签流式布局：按容器宽度自动换行。
struct MpTagFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 片源选择

private struct MpStreamSheet: View {
    let streams: [MediaStreamItem]
    let reason: String
    let isLoading: Bool
    var onSelect: (MediaStreamItem) -> Void
    var onReload: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.md) {
                    if streams.isEmpty {
                        if isLoading {
                            HStack(spacing: RexSpacing.sm) {
                                ProgressView()
                                Text("正在聚合片源…")
                                    .font(RexFont.footnote)
                                    .foregroundStyle(RexColor.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            RexInlineNotice(
                                title: "没有可用的片源",
                                message: reason.isEmpty ? "该条目暂时没有在线播放源。" : reason,
                                tone: .warning,
                                actionTitle: "重新查找"
                            ) {
                                onReload()
                            }
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(streams) { stream in
                                row(stream)
                            }
                        }

                        if isLoading {
                            HStack(spacing: RexSpacing.sm) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在查找更多来源…")
                                    .font(RexFont.caption2)
                                    .foregroundStyle(RexColor.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }

                        if !reason.isEmpty {
                            RexNote(text: reason)
                        }
                    }
                }
                .padding(.bottom, RexSpacing.lg)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.xl)
        .frame(maxWidth: RexLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RexColor.sheetBackground)
    }

    private var header: some View {
        HStack(spacing: RexSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("在线播放")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Text(statusText)
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
            }

            Spacer(minLength: 0)

            Button("关闭") { dismiss() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RexColor.field, in: Capsule(style: .continuous))
                .buttonStyle(PressableButtonStyle())
        }
    }

    private var statusText: String {
        if isLoading {
            return streams.isEmpty ? "正在聚合片源…" : "已找到 \(streams.count) 个 · 继续查找中"
        }
        if streams.isEmpty { return "暂无可用来源" }
        return "共 \(streams.count) 个来源"
    }

    /// 一个资源只占一行：标题超长省略，来源名收在右侧小药丸里。
    private func row(_ stream: MediaStreamItem) -> some View {
        let raw = stream.url.isEmpty ? stream.externalUrl : stream.url
        let isPlayable = raw.hasPrefix("http://") || raw.hasPrefix("https://")

        return Button {
            RexHaptics.tap()
            onSelect(stream)
        } label: {
            HStack(spacing: RexSpacing.md) {
                Image(systemName: isPlayable ? "play.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isPlayable ? RexColor.brandBlue : RexColor.secondaryText)

                Text(stream.displayTitle)
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: RexSpacing.xs)

                Text(stream.provider)
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(RexColor.field, in: Capsule(style: .continuous))

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RexColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint(isPlayable ? "在线播放" : "下载")
    }
}

private extension MpDetail {
    var overviewSafe: String {
        (overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 「PT 搜索方式」选择卡：按标题 / 按 IMDb（对齐 PWA `media-pt-pick`）。
private struct MpPtPickSheet: View {
    let keyword: String
    let imdbId: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("PT 搜索方式")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: 0)

                Button {
                    RexHaptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RexColor.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(RexColor.field, in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
            }

            VStack(spacing: 9) {
                option(
                    title: "按标题搜索",
                    desc: "用「\(keyword)」在全部已启用站点模糊匹配",
                    area: "title"
                )

                option(
                    title: "按 IMDb 搜索",
                    desc: imdbId.isEmpty
                        ? "由 MoviePilot 解析该条目对应的 IMDb 编号后匹配"
                        : "按 \(imdbId) 精确匹配",
                    area: "imdbid"
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.xl)
        .padding(.bottom, RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RexColor.sheetBackground)
    }

    private func option(title: String, desc: String, area: String) -> some View {
        Button {
            RexHaptics.tap()
            onPick(area)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Text(desc)
                    .font(.system(size: 12.5))
                    .foregroundStyle(RexColor.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(optionFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var optionFill: Color {
        colorScheme == .dark
            ? Color(hex: 0x7C5CF0).opacity(0.18)
            : Color(hex: 0x7C5CF0).opacity(0.08)
    }
}

