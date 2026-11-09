import SwiftUI
import UIKit

/// 片商影片详情：封面信息、简介、演员、标签、磁力、在线播放源与相关影片。
struct MakerMovieDetailView: View {
    private let movieID: String
    private let initialMovie: MakerMovie?

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var detail: MakerMovieDetail?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var isScrolled = false

    /// 播放源
    @State private var streams: [MakerStream] = []
    @State private var streamReason = ""
    @State private var isLoadingStreams = false
    @State private var showsStreamSheet = false
    @State private var playingSource: MakerPlayRequest?
    @State private var alert: RexAlertInfo?

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
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    hero

                    if let detail {
                        actionRow(detail)
                        infoSection(detail)

                        if !detail.summarySafe.isEmpty {
                            section("简介") {
                                Text(detail.summarySafe)
                                    .font(RexFont.body)
                                    .foregroundStyle(RexColor.secondaryText)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !detail.actors.isEmpty {
                            section("演员") {
                                actorRow(detail.actors)
                            }
                        }

                        if !detail.tags.isEmpty {
                            section("标签") {
                                tagWrap(detail.tags)
                            }
                        }

                        if !detail.magnets.isEmpty {
                            section("磁力资源") {
                                magnetList(detail.magnets)
                            }
                        }

                        if !detail.relativeMovies.isEmpty {
                            section("相关影片") {
                                relativeRail(detail.relativeMovies)
                            }
                        }

                        if !detail.previews.isEmpty {
                            section("预览图") {
                                previewRail(detail.previews)
                            }
                        }
                    } else if isLoading {
                        VStack(spacing: RexSpacing.lg) {
                            RexSkeleton(width: 180, height: 16, cornerRadius: 8)
                            RexSkeleton(width: .infinity, height: 90, cornerRadius: 12)
                            RexSkeleton(width: .infinity, height: 90, cornerRadius: 12)
                        }
                        .padding(.top, RexSpacing.sm)
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
                .background(RexScrollOffsetReader(space: "makerDetailScroll"))
            }
            .rexScrollTracking("makerDetailScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load() }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
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

    // MARK: - 头部

    private var hero: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            ZStack(alignment: .bottomLeading) {
                MakerArtwork(movie?.heroURL, width: 780)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: RexRadius.largeCard, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: RexRadius.largeCard, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(movie?.displayTitle ?? "加载中…")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)

                    metaLine
                }
                .padding(RexSpacing.lg)
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: RexSpacing.sm) {
            if let number = movie?.number, !number.isEmpty {
                chipText(number)
            }
            if let date = movie?.releaseDate, !date.isEmpty {
                chipText(date)
            }
            if let duration = movie?.duration, duration > 0 {
                chipText("\(Int(duration)) 分钟")
            }
            if movie?.hasCnsub == true {
                chipText("中文字幕", tint: RexColor.success)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private func chipText(_ text: String, tint: Color = .white) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(.black.opacity(0.55), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
            }
    }

    // MARK: - 操作

    private func actionRow(_ detail: MakerMovieDetail) -> some View {
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

                    Text(detail.canPlay ? "播放" : "查找片源")
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
            .accessibilityLabel("查找在线播放源")

            if let magnet = detail.magnets.first {
                Button {
                    copy(magnet.url)
                } label: {
                    Label("磁力", systemImage: "link")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(RexColor.primaryText)
                        .frame(width: 92, height: 48)
                        .background(
                            RexColor.surface,
                            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                                .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                        }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("复制首个磁力链接")
            }
        }
    }

    // MARK: - 信息

    private func infoSection(_ detail: MakerMovieDetail) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            if let score = detail.score, score > 0 {
                infoRow("评分", String(format: "%.1f", score))
            }
            if !detail.makers.isEmpty {
                infoRow("片商", detail.makers.map(\.name).joined(separator: " / "))
            }
            if let director = detail.director, !director.isEmpty {
                infoRow("导演", director)
            }
            if let series = detail.series, !series.isEmpty {
                infoRow("系列", series)
            }
            infoRow("番号", movie?.number ?? "—")
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.md) {
            Text(title)
                .font(RexFont.footnote)
                .foregroundStyle(RexColor.tertiaryText)
                .frame(width: 44, alignment: .leading)

            Text(value)
                .font(RexFont.footnote)
                .foregroundStyle(RexColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actorRow(_ actors: [MakerActor]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.md) {
                ForEach(actors) { actor in
                    VStack(spacing: 5) {
                        MakerArtwork(actor.avatarUrl, width: 160)
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())

                        Text(actor.name)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: RexSpacing.sm, alignment: .leading)], alignment: .leading, spacing: RexSpacing.sm) {
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

    private func magnetList(_ magnets: [MakerMagnet]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(magnets.prefix(8).enumerated()), id: \.element.id) { index, magnet in
                if index > 0 { SettingsDivider() }

                HStack(spacing: RexSpacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(magnet.name)
                            .font(RexFont.footnote)
                            .foregroundStyle(RexColor.primaryText)
                            .lineLimit(2)

                        HStack(spacing: RexSpacing.sm) {
                            if let size = magnet.size, !size.isEmpty {
                                Text(size)
                            }
                            if magnet.filesCount > 0 {
                                Text("\(magnet.filesCount) 个文件")
                            }
                            if let createdAt = magnet.createdAt, !createdAt.isEmpty {
                                Text(createdAt)
                            }
                        }
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.tertiaryText)
                    }

                    Spacer(minLength: RexSpacing.sm)

                    Button {
                        copy(magnet.url)
                    } label: {
                        Text("复制")
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(RexColor.brandBlue)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(height: 34)
                            .background(RexColor.brandBlue.opacity(0.10), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(.horizontal, RexSpacing.lg)
                .padding(.vertical, RexSpacing.md)
            }
        }
        .rexCard()
    }

    private func relativeRail(_ movies: [MakerMovie]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(movies) { item in
                    NavigationLink(value: MakerRoute.movie(item)) {
                        MakerMovieCard(movie: item, width: 108)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityHint("查看影片详情")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func previewRail(_ previews: [MakerPreview]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: RexSpacing.sm) {
                ForEach(Array(previews.enumerated()), id: \.offset) { _, preview in
                    MakerArtwork(preview.thumb.isEmpty ? preview.large : preview.thumb, width: 360)
                        .frame(width: 140, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous))
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
        defer { isLoading = false }

        do {
            detail = try await apiClient.makerMovie(id: movieID)
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
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
                                            .font(.system(size: 20))
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
