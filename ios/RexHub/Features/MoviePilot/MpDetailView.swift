import SwiftUI

/// 影视详情：MoviePilot 元数据 + 在线片源（插件 / Stremio addon）。
struct MpDetailView: View {
    let item: MpItem

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var detail: MpDetail?
    @State private var related: MpRelated?
    @State private var streams: [MediaStreamItem] = []
    @State private var streamReason = ""
    @State private var isLoading = true
    @State private var isLoadingStreams = false
    @State private var errorText: String?
    @State private var showsStreamSheet = false
    @State private var playing: MpPlayRequest?
    @State private var isScrolled = false

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: detail?.title ?? item.title,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    hero
                    actionRow

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
                    }

                    if let detail {
                        if !detail.overviewSafe.isEmpty {
                            section("简介") {
                                Text(detail.overviewSafe)
                                    .font(RexFont.body)
                                    .foregroundStyle(RexColor.secondaryText)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !detail.cast.isEmpty {
                            section("演员") {
                                castRow(detail.cast)
                            }
                        }

                        if !detail.genres.isEmpty {
                            section("类型") {
                                tagWrap(detail.genres)
                            }
                        }
                    }

                    if let related, !related.recommendations.isEmpty || !related.similar.isEmpty {
                        section("相关推荐") {
                            relatedRail(Array((related.recommendations + related.similar).prefix(16)))
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "mpDetailScroll"))
            }
            .rexScrollTracking("mpDetailScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load() }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $showsStreamSheet) {
            MpStreamSheet(
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
        .fullScreenCover(item: $playing) { request in
            RexPlayerView(item: request.item, playlist: [], directSource: request.info)
        }
    }

    // MARK: - 头部

    private var hero: some View {
        HStack(alignment: .top, spacing: RexSpacing.lg) {
            MpArtwork(url: detail?.posterUrl ?? item.posterUrl)
                .frame(width: 112, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }

            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                Text(detail?.title ?? item.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(3)

                if let original = detail?.originalTitle ?? item.originalTitle, !original.isEmpty,
                   original != (detail?.title ?? item.title) {
                    Text(original)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(2)
                }

                HStack(spacing: RexSpacing.sm) {
                    if let year = detail?.year ?? item.year, !year.isEmpty {
                        MakerBadge(text: year, tint: RexColor.brandBlue)
                    }
                    if let rating = detail?.rating ?? item.rating {
                        MakerBadge(text: String(format: "%.1f", rating), tint: Color(hex: 0xFFC93C))
                    }
                    if let runtime = detail?.runtime, runtime > 0 {
                        MakerBadge(text: "\(runtime) 分钟", tint: RexColor.secondaryText)
                    }
                    if let imdb = detail?.imdbId, !imdb.isEmpty {
                        MakerBadge(text: imdb, tint: Color(hex: 0xF5C518))
                    }
                }

                if let countries = detail?.countries, !countries.isEmpty {
                    Text(countries.joined(separator: " · "))
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 操作

    private var actionRow: some View {
        HStack(spacing: RexSpacing.md) {
            Button {
                guard !isLoadingStreams else { return }
                RexHaptics.tap()
                Task { await loadStreams() }
            } label: {
                HStack(spacing: RexSpacing.sm) {
                    if isLoadingStreams {
                        ProgressView()
                            .controlSize(.small)
                            .tint(RexColor.onBrand)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text("在线播放")
                        .font(.system(.subheadline, weight: .semibold))
                }
                .foregroundStyle(RexColor.onBrand)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RexColor.brandGradient,
                    in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isLoadingStreams)
        }
    }

    // MARK: - 其它区块

    private func castRow(_ cast: [MpCast]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.md) {
                ForEach(Array(cast.prefix(16))) { person in
                    VStack(spacing: 5) {
                        MpArtwork(url: person.avatarUrl, fallbackSymbol: "person.fill")
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())

                        Text(person.name)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(1)
                            .frame(width: 64)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
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
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text(title)
                .font(RexFont.section)
                .foregroundStyle(RexColor.secondaryText)
                .padding(.leading, RexSpacing.xs)

            content()
        }
    }

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

    private func loadStreams() async {
        guard let apiClient, !isLoadingStreams else { return }
        isLoadingStreams = true
        defer { isLoadingStreams = false }

        do {
            let result = try await apiClient.mediaStreams(
                id: item.id,
                imdb: detail?.imdbId ?? "",
                mediaType: item.isTV ? "series" : "movie",
                title: detail?.title ?? item.title
            )
            streams = result.streams
            streamReason = result.reason

            if result.streams.count == 1, let only = result.streams.first {
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

    private func play(_ stream: MediaStreamItem) {
        guard let apiClient else { return }
        let raw = stream.url.isEmpty ? stream.externalUrl : stream.url
        guard raw.hasPrefix("http://") || raw.hasPrefix("https://") else {
            // 磁力/种子类片源不能直接播放，交给下载流程处理。
            return
        }
        guard let url = apiClient.mediaStreamProxyURL(raw: raw) else { return }
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

// MARK: - 片源选择

private struct MpStreamSheet: View {
    let streams: [MediaStreamItem]
    let reason: String
    let isLoading: Bool
    var onSelect: (MediaStreamItem) -> Void
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
                            message: reason.isEmpty ? "该条目暂时没有在线播放源。" : reason,
                            tone: .warning,
                            actionTitle: "重新查找"
                        ) {
                            onReload()
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(streams.enumerated()), id: \.element.id) { index, stream in
                                if index > 0 { SettingsDivider() }

                                let raw = stream.url.isEmpty ? stream.externalUrl : stream.url
                                let isPlayable = raw.hasPrefix("http://") || raw.hasPrefix("https://")

                                Button {
                                    RexHaptics.tap()
                                    onSelect(stream)
                                } label: {
                                    HStack(spacing: RexSpacing.md) {
                                        Image(systemName: isPlayable ? "play.circle.fill" : "arrow.down.circle")
                                            .font(.system(size: 20))
                                            .foregroundStyle(isPlayable ? RexColor.brandBlue : RexColor.secondaryText)
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
                                            .font(.system(size: 12, weight: .semibold))
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
            .navigationTitle("选择片源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private extension MpDetail {
    var overviewSafe: String {
        (overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
