import SwiftUI
import UIKit

/// PT 搜索跳转参数：详情页选好搜索方式后带入，页面内不再切换。
struct MpPtSearchTarget: Identifiable, Hashable {
    /// 标题关键词（原片名优先）。
    let keyword: String
    /// `title` 或 `imdbid`。
    let area: String
    let source: String
    let mediaId: String
    let mediaType: String
    let title: String
    let originalTitle: String
    let year: String
    let posterUrl: String

    var id: String { "\(area)|\(source)|\(mediaId)|\(keyword)" }
}

/// PT 资源搜索结果：对齐 PWA 的 `MediaPtSearchBody`。
struct MpPtSearchView: View {
    let target: MpPtSearchTarget

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MpTorrentItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var isScrolled = false

    @State private var sort: PtSort = .relevance
    @State private var filters: [PtFacet: Set<String>] = [:]
    @State private var openFacet: PtFacet?
    @State private var confirming: MpTorrentItem?
    @State private var sourcesFor: MpTorrentItem?
    @State private var submittingID: String?
    @State private var toast: RexToastInfo?
    @State private var alert: RexAlertInfo?

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "PT 搜索",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.lg) {
                    if isLoading, items.isEmpty {
                        RexStateCard(
                            symbol: "antenna.radiowaves.left.and.right",
                            title: "正在搜索 PT 站点…",
                            message: "MoviePilot 会并发请求全部已启用站点，通常需要几秒",
                            tone: .brand,
                            isLoading: true
                        )
                    } else if items.isEmpty {
                        if let errorText {
                            RexStateCard(
                                symbol: "wifi.exclamationmark",
                                title: "搜索失败",
                                message: errorText,
                                tone: .warning,
                                actionTitle: "重试"
                            ) {
                                Task { await load() }
                            }
                        } else {
                            RexStateCard(
                                symbol: "tray",
                                title: "没有找到资源",
                                message: "换个关键词，或稍后再试。",
                                tone: .neutral
                            )
                        }
                    } else {
                        panel
                        facetGrid

                        if visibleItems.isEmpty {
                            RexInlineNotice(
                                title: "当前筛选条件下没有资源",
                                message: "可以减少筛选条件后再看看。",
                                tone: .neutral
                            )
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(visibleItems) { torrent in
                                    torrentCard(torrent)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "mpPtScroll"))
            }
            .rexScrollTracking("mpPtScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load() }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 重新出现时保留已加载内容，不重新请求。
            if items.isEmpty { await load() }
        }
        .sheet(item: $openFacet) { facet in
            PtFacetSheet(
                facet: facet,
                options: facetOptions[facet] ?? [],
                totalCount: items.count,
                selection: selectionBinding(facet)
            )
            .rexSheetStyle()
        }
        .sheet(item: $sourcesFor) { torrent in
            PtSourcesSheet(
                torrent: torrent,
                submittingID: submittingID,
                onPick: { source in
                    sourcesFor = nil
                    Task { await submitVariant(source, of: torrent) }
                }
            )
            .rexSheetStyle()
        }
        .overlay {
            if let torrent = confirming {
                PtConfirmDialog(
                    torrent: torrent,
                    isSubmitting: submittingID != nil,
                    onCancel: { confirming = nil },
                    onConfirm: { Task { await submit(torrent) } }
                )
            }
        }
        .animation(RexMotion.standard, value: confirming?.id)
        .rexToast($toast)
        .rexAlert($alert)
    }

    // MARK: - 统计与筛选

    private var panel: some View {
        HStack(spacing: RexSpacing.md) {
            Text(countText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .monospacedDigit()
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(PtPalette.solid, in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            Menu {
                ForEach(PtSort.allCases) { option in
                    Button {
                        RexHaptics.tap()
                        sort = option
                    } label: {
                        if option == sort {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10.5, weight: .semibold))

                    Text(sort.title)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(RexColor.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RexColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("排序方式")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .rexCard(cornerRadius: 16)
    }

    private var facetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
            spacing: 7
        ) {
            ForEach(PtFacet.allCases) { facet in
                let options = facetOptions[facet] ?? []
                if !options.isEmpty {
                    facetButton(facet)
                }
            }
        }
    }

    private func facetButton(_ facet: PtFacet) -> some View {
        let active = !(filters[facet] ?? []).isEmpty

        return Button {
            RexHaptics.tap()
            openFacet = facet
        } label: {
            VStack(spacing: 4) {
                Image(systemName: facet.symbol)
                    .font(.system(size: 16, weight: .semibold))

                Text(facet.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.white : PtPalette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                active ? PtPalette.solid : PtPalette.fill,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        active ? Color.white.opacity(0.2) : PtPalette.accent.opacity(0.22),
                        lineWidth: active ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(facet.title)筛选")
    }

    private var countText: String {
        visibleItems.count == items.count
            ? "\(items.count) 个资源"
            : "\(visibleItems.count) / \(items.count) 个资源"
    }

    private var facetOptions: [PtFacet: [PtFacetOption]] {
        var out: [PtFacet: [PtFacetOption]] = [:]

        for facet in PtFacet.allCases {
            var counts: [String: Int] = [:]
            var order: [String] = []

            for torrent in items {
                for value in PtFacet.values(of: torrent, facet: facet) {
                    if counts[value] == nil { order.append(value) }
                    counts[value, default: 0] += 1
                }
            }

            var options = order.map { PtFacetOption(value: $0, count: counts[$0] ?? 0) }
            if facet == .season {
                options.sort { PtFacet.seasonRank($0.value, $1.value) }
            } else {
                options.sort { $0.count > $1.count }
            }
            out[facet] = options
        }

        return out
    }

    private var visibleItems: [MpTorrentItem] {
        let list = items.filter { torrent in
            for facet in PtFacet.allCases {
                let want = filters[facet] ?? []
                guard !want.isEmpty else { continue }
                let values = PtFacet.values(of: torrent, facet: facet)
                if !values.contains(where: { want.contains($0) }) { return false }
            }
            return true
        }

        switch sort {
        case .relevance:
            // 保持服务端下发顺序：MoviePilot 已按相关度排好，最相关在最前。
            return list
        case .seeders:
            return list.sorted { $0.seeders > $1.seeders }
        case .size:
            return list.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .date:
            return list.sorted { ($0.pubdate ?? "") > ($1.pubdate ?? "") }
        }
    }

    private func selectionBinding(_ facet: PtFacet) -> Binding<Set<String>> {
        Binding(
            get: { filters[facet] ?? [] },
            set: { filters[facet] = $0 }
        )
    }

    // MARK: - 资源卡

    private func torrentCard(_ torrent: MpTorrentItem) -> some View {
        return VStack(spacing: 0) {
            Button {
                RexHaptics.tap()
                confirming = torrent
            } label: {
                mainContent(torrent)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHint("确认后提交到下载器")

            if torrent.variants.count > 1 {
                moreSourcesRow(torrent)
            }
        }
        .rexCard(cornerRadius: 16)
    }

    /// 资源卡主体：点击进入下载确认。
    private func mainContent(_ torrent: MpTorrentItem) -> some View {
        let name = PtMeta.splitName(torrent.title)
        let sizeText = PtMeta.formatSize(torrent.size)
        let tags = PtMeta.releaseTags(torrent.title)

        return VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    Text(name.title)
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    promoTags(torrent)
                }

                HStack(spacing: 6) {
                    // 卡片只显示主站点，其余站点数量由底部「更多来源」入口体现
                    ForEach(torrent.siteNames.prefix(1), id: \.self) { site in
                        Text(site)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(RexColor.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RexColor.field,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                    }

                    Text("做种 \(torrent.seeders)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PtPalette.seeders)
                        .monospacedDigit()
                        .padding(.leading, 2)

                    Spacer(minLength: 0)
                }

                if !name.rest.isEmpty {
                    Text(name.rest)
                        .font(.system(size: 12.5))
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let description = torrent.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if let time = nonEmpty(torrent.dateElapsed) ?? nonEmpty(torrent.pubdate) {
                        Text(time)
                            .font(.system(size: 11.5))
                            .foregroundStyle(RexColor.tertiaryText)
                    }

                    if let category = nonEmpty(torrent.category) {
                        Text(category)
                            .font(.system(size: 11.5))
                            .foregroundStyle(RexColor.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                if !tags.isEmpty || !sizeText.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(tags) { tag in
                            Text(tag.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tag.tone.foreground)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    tag.tone.background,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                        }

                        Spacer(minLength: 0)

                        if !sizeText.isEmpty {
                            Text(sizeText)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(PtPalette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    PtPalette.soft,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 合并资源的「更多来源」入口：显示除默认站点外的站点数，点开可单站下载。
    private func moreSourcesRow(_ torrent: MpTorrentItem) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RexColor.fieldBorder)
                .frame(height: 0.5)
                .padding(.horizontal, 13)

            Button {
                RexHaptics.tap()
                sourcesFor = torrent
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))

                    Text("更多来源 (\(torrent.variants.count - 1))")
                        .font(.system(size: 12, weight: .semibold))

                    Spacer(minLength: 0)

                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(PtPalette.accent)
                .padding(.horizontal, 13)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHint("查看其他站点并可单独下载")
        }
    }

    @ViewBuilder
    private func promoTags(_ torrent: MpTorrentItem) -> some View {
        HStack(spacing: 5) {
            if let factor = nonEmpty(torrent.volumeFactor) {
                Text(factor)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(
                        factor.contains("免费") ? PtPalette.free : PtPalette.promo,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }

            if torrent.hitAndRun {
                Text("H&R")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(
                        PtPalette.hitAndRun,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - 数据

    private func load() async {
        guard let apiClient else {
            isLoading = false
            errorText = "登录状态已失效，请重新登录"
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let isImdb = target.area == "imdbid"
            let result = try await apiClient.mpPtSearch(
                keyword: isImdb ? "" : target.keyword,
                source: target.source,
                id: isImdb ? target.mediaId : "",
                mediaType: target.mediaType,
                area: isImdb ? "imdbid" : "title"
            )
            items = result.items
            filters = [:]
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
            items = []
        }
    }

    private func submit(_ torrent: MpTorrentItem) async {
        guard let apiClient, submittingID == nil else { return }

        let key = (torrent.downloadKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            toast = .warning("资源信息已过期，请重新搜索后再提交")
            return
        }

        submittingID = torrent.id
        defer { submittingID = nil }
        confirming = nil
        toast = .notice("已提交下载，正在等待下载器响应：\(torrent.title)")

        do {
            let task = try await apiClient.mpSubmitDownload(
                key: key,
                source: target.source,
                mediaId: target.mediaId,
                mediaType: target.mediaType,
                title: target.title.isEmpty ? target.keyword : target.title,
                originalTitle: target.originalTitle,
                year: target.year,
                posterUrl: target.posterUrl
            )

            if let status = await waitForDownload(downloadId: task.downloadId, title: torrent.title) {
                toast = .success("\(PtMeta.downloadStateText(status.state))：\(torrent.title)")
            }
        } catch {
            alert = RexAlertInfo(title: "提交下载失败", message: error.localizedDescription)
        }
    }

    /// 从指定站点单独提交下载：合并资源弹窗里点「下载」时走这里。
    private func submitVariant(_ source: MpTorrentSource, of torrent: MpTorrentItem) async {
        guard let apiClient, submittingID == nil else { return }

        let key = (source.downloadKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            toast = .warning("资源信息已过期，请重新搜索后再提交")
            return
        }

        submittingID = source.id
        defer { submittingID = nil }
        toast = .notice("正在从 \(source.site) 提交下载…")

        do {
            let task = try await apiClient.mpSubmitDownload(
                key: key,
                source: target.source,
                mediaId: target.mediaId,
                mediaType: target.mediaType,
                title: target.title.isEmpty ? target.keyword : target.title,
                originalTitle: target.originalTitle,
                year: target.year,
                posterUrl: target.posterUrl
            )

            if let status = await waitForDownload(downloadId: task.downloadId, title: torrent.title) {
                toast = .success("\(PtMeta.downloadStateText(status.state))：\(source.site)")
            }
        } catch {
            alert = RexAlertInfo(title: "提交下载失败", message: error.localizedDescription)
        }
    }

    /// 对齐 PWA：最多轮询 30 次，前 5 次间隔 1s，之后 2s。
    private func waitForDownload(downloadId: String, title: String) async -> MpDownloadStatus? {
        guard let apiClient else { return nil }

        for attempt in 0..<30 {
            guard !Task.isCancelled else { return nil }
            let seconds = attempt < 5 ? 1 : 2
            try? await Task.sleep(for: .seconds(seconds))

            guard let status = try? await apiClient.mpDownloadStatus(
                downloadId: downloadId,
                title: title
            ) else { continue }

            if status.found { return status }
        }

        return nil
    }
}

// MARK: - 筛选项

private struct PtFacetOption: Identifiable {
    let value: String
    let count: Int

    var id: String { value }
}

private enum PtSort: String, CaseIterable, Identifiable {
    case relevance
    case seeders
    case size
    case date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: "相关性"
        case .seeders: "做种优先"
        case .size: "体积最大"
        case .date: "最新发布"
        }
    }
}

/// 9 个筛选维度，顺序与 PWA 一致。
private enum PtFacet: String, CaseIterable, Identifiable {
    case site
    case season
    case web
    case sub
    case promo
    case codec
    case edition
    case res
    case team

    var id: String { rawValue }

    var title: String {
        switch self {
        case .site: "站点"
        case .season: "季集"
        case .web: "源"
        case .sub: "字幕"
        case .promo: "促销状态"
        case .codec: "视频编码"
        case .edition: "质量"
        case .res: "分辨率"
        case .team: "制作组"
        }
    }

    var symbol: String {
        switch self {
        case .site: "server.rack"
        case .season: "tv"
        case .web: "globe"
        case .sub: "captions.bubble"
        case .promo: "gift"
        case .codec: "video"
        case .edition: "checkmark.seal"
        case .res: "display"
        case .team: "person.2"
        }
    }

    /// MP 只把这两个标签订为字幕维度。
    private static let subtitleLabels: Set<String> = ["中字", "特效"]

    /// 一条资源在某个维度上的取值，直接取 MP 的 meta_info。
    static func values(of torrent: MpTorrentItem, facet: PtFacet) -> [String] {
        switch facet {
        case .site:
            return torrent.siteNames
        case .season:
            return single(torrent.seasonEpisode)
        case .web:
            return single(torrent.webSource)
        case .sub:
            return torrent.labels.filter { subtitleLabels.contains($0) }
        case .promo:
            return single(torrent.volumeFactor)
        case .codec:
            return single(torrent.videoCode)
        case .edition:
            return single(torrent.edition)
        case .res:
            return single(torrent.resolution)
        case .team:
            return single(torrent.releaseGroup)
        }
    }

    private static func single(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return [value]
    }

    /// 季集按季、集降序排列（返回负数表示前者在前）。
    static func seasonRank(_ lhs: String, _ rhs: String) -> Bool {
        let x = seasonKey(lhs)
        let y = seasonKey(rhs)
        if x.s1 != y.s1 { return x.s1 > y.s1 }
        if x.s2 != y.s2 { return x.s2 > y.s2 }
        if x.e1 != y.e1 { return x.e1 > y.e1 }
        return x.e2 > y.e2
    }

    private static func seasonKey(_ text: String) -> (s1: Int, s2: Int, e1: Int, e2: Int) {
        let seasons = numbers(in: text, pattern: "S(\\d+)(?:-S(\\d+))?")
        let episodes = numbers(in: text, pattern: "E(\\d+)(?:-E(\\d+))?")
        return (
            seasons.first ?? 0,
            seasons.count > 1 ? seasons[1] : 0,
            episodes.first ?? 0,
            episodes.count > 1 ? episodes[1] : 0
        )
    }

    private static func numbers(in text: String, pattern: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return []
        }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return 0 }
            return Int(ns.substring(with: range)) ?? 0
        }
    }
}

// MARK: - 文件名解析

/// 资源名拆解：对齐 PWA 的 `formatSize` / `splitName` / `releaseTags`。
private enum PtMeta {
    /// 体积友好展示：B/KB/MB/GB/TB，超过 100 不保留小数。
    static func formatSize(_ bytes: Double?) -> String {
        guard let bytes, bytes > 0 else { return "" }

        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }

        let text = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(text) \(units[index])"
    }

    private static let releaseCut: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?:^|[\\s._\\-\\[(])((?:19|20)\\d{2}|2160p|1080p|1080i|720p|576p|480p|4k|uhd|blu-?ray|remux|web-?dl|web-?rip|hdtv|hdrip|bdrip|dvdrip|hevc|h\\.?26[45]|x26[45]|avc)\\b",
        options: [.caseInsensitive]
    )

    /// 把资源名拆成「片名 + 完整文件名」。
    static func splitName(_ name: String) -> (title: String, rest: String) {
        let ns = name as NSString
        var cut = name

        if let regex = releaseCut,
           let match = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
           match.range.location > 1 {
            cut = ns.substring(to: match.range.location)
        }

        var head = cut
        for separator in ["|", "｜"] {
            if let range = head.range(of: separator) {
                head = String(head[..<range.lowerBound])
            }
        }
        if let range = head.range(of: " / ") {
            head = String(head[..<range.lowerBound])
        }

        head = head
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        while let last = head.last, " \t\n-–—()[]】".contains(last) {
            head.removeLast()
        }
        head = head.split(separator: " ").joined(separator: " ")

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.count < 2 || head == trimmedName {
            return (name, "")
        }
        return (head, name)
    }

    /// 从文件名提取发行标签，最多 4 个。
    static func releaseTags(_ name: String) -> [PtReleaseTag] {
        var out: [PtReleaseTag] = []
        func add(_ label: String, _ tone: PtReleaseTone) {
            guard !label.isEmpty, out.count < 4 else { return }
            out.append(PtReleaseTag(label: label, tone: tone))
        }

        add(sourceOf(name), .source)
        add(resolutionOf(name), .res)
        add(codecOf(name), .codec)
        add(groupOf(name), .group)
        add(audioOf(name), .audio)
        return out
    }

    static func resolutionOf(_ text: String) -> String {
        let lower = text.lowercased()
        for value in ["2160p", "1080p", "1080i", "720p", "576p", "480p"] where lower.contains(value) {
            return value
        }
        if lower.contains("4k") || lower.contains("uhd") { return "2160p" }
        return ""
    }

    static func sourceOf(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("uhd bluray") || lower.contains("uhd blu-ray") { return "UHD BluRay" }
        if lower.contains("remux") { return "REMUX" }
        if lower.contains("bluray") || lower.contains("blu-ray") { return "BluRay" }
        if lower.contains("web-dl") || lower.contains("webdl") { return "WEB-DL" }
        if lower.contains("webrip") || lower.contains("web-rip") { return "WEBRip" }
        if lower.contains("hdtv") { return "HDTV" }
        if lower.contains("bdrip") { return "BDRip" }
        if lower.contains("dvdrip") { return "DVDRip" }
        return ""
    }

    static func codecOf(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("hevc") || lower.contains("h.265") || lower.contains("h265")
            || lower.contains("x265") {
            return "HEVC"
        }
        if lower.contains("avc") || lower.contains("h.264") || lower.contains("h264")
            || lower.contains("x264") {
            return "AVC"
        }
        if lower.contains("av1") { return "AV1" }
        return ""
    }

    static func audioOf(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("atmos") { return "Atmos" }
        if lower.contains("dts-hd") || lower.contains("dts hd") { return "DTS-HD" }
        if lower.contains("truehd") || lower.contains("true-hd") { return "TrueHD" }
        if lower.contains("dts") { return "DTS" }
        if lower.contains("flac") { return "FLAC" }
        if lower.contains("aac") { return "AAC" }
        if lower.contains("ac-3") || lower.contains("eac3") || lower.contains("ddp") { return "AC3" }
        return ""
    }

    /// 末尾的制作组：最后一个分隔符之后、以字母开头的 2~25 位标识。
    static func groupOf(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = trimmed.endIndex

        while index > trimmed.startIndex {
            let previous = trimmed.index(before: index)
            let character = trimmed[previous]
            if character.isLetter || character.isNumber || "._@-".contains(character) {
                index = previous
            } else {
                break
            }
        }

        var token = String(trimmed[index...])
        while let first = token.first, ".-".contains(first) {
            token.removeFirst()
        }

        guard token.count >= 3, token.count <= 25, let first = token.first, first.isLetter else {
            return ""
        }
        return token
    }

    /// 下载器状态转中文描述。
    static func downloadStateText(_ state: String?) -> String {
        let text = (state ?? "").lowercased()

        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }

        if matches("error|fail|失败") { return "下载任务异常" }
        if matches("finish|complete|完成") { return "下载已完成" }
        if matches("seed|做种") { return "已下载完成，正在做种" }
        if matches("pause|暂停") { return "任务已暂停" }
        if matches("stop|停止") { return "任务已停止" }
        return "已开始下载"
    }
}

private struct PtReleaseTag: Identifiable {
    let label: String
    let tone: PtReleaseTone

    var id: String { "\(tone.rawValue)-\(label)" }
}

private enum PtReleaseTone: String {
    case source
    case res
    case codec
    case group
    case audio

    var background: Color {
        switch self {
        case .source: PtPalette.dynamic(light: 0xFDECEB, dark: 0x3A211E)
        case .res: PtPalette.dynamic(light: 0xFBE9F4, dark: 0x3A1F33)
        case .codec: PtPalette.dynamic(light: 0xFDF1E2, dark: 0x3A2C1A)
        case .group: PtPalette.dynamic(light: 0xE6F6F1, dark: 0x17332C)
        case .audio: PtPalette.dynamic(light: 0xEAF0FD, dark: 0x1B2740)
        }
    }

    var foreground: Color {
        switch self {
        case .source: PtPalette.dynamic(light: 0xD4462F, dark: 0xFF8F7A)
        case .res: PtPalette.dynamic(light: 0xB32D8A, dark: 0xFF86C8)
        case .codec: PtPalette.dynamic(light: 0xB56500, dark: 0xFFB559)
        case .group: PtPalette.dynamic(light: 0x0A7A63, dark: 0x4FD1A5)
        case .audio: PtPalette.dynamic(light: 0x2A5BD7, dark: 0x7DA2FF)
        }
    }
}

// MARK: - PT 配色

private enum PtPalette {
    /// PT 页面主强调色（对齐 PWA 的 `--pt-accent`）。
    static let solid = Color(hex: 0x7C5CF0)

    static let accent = dynamic(light: 0x7C5CF0, dark: 0xB9A5FF)
    static let fill = dynamic(light: 0xF2EDFF, dark: 0x2A2340)
    static let soft = dynamic(light: 0xF2EDFF, dark: 0x2A2340)

    static let seeders = dynamic(light: 0x0A7A3D, dark: 0x4CD07D)

    static let free = Color(hex: 0x34C759)
    static let promo = Color(hex: 0xFF9F0A)
    static let hitAndRun = Color(hex: 0xFF3B30)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

// MARK: - 筛选弹窗

private struct PtFacetSheet: View {
    let facet: PtFacet
    let options: [PtFacetOption]
    let totalCount: Int
    @Binding var selection: Set<String>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            HStack(spacing: RexSpacing.md) {
                Image(systemName: facet.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PtPalette.accent)

                Text(facet.title)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: 0)

                Button("完成") { dismiss() }
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(
                        PtPalette.solid,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .buttonStyle(PressableButtonStyle())
            }

            ScrollView {
                MpTagFlow(spacing: 8, lineSpacing: 8) {
                    chip(
                        text: facet == .site ? "全部 \(totalCount)" : "全部",
                        active: selection.isEmpty
                    ) {
                        selection.removeAll()
                    }

                    ForEach(options) { option in
                        chip(
                            text: "\(option.value) \(option.count)",
                            active: selection.contains(option.value)
                        ) {
                            if selection.contains(option.value) {
                                selection.remove(option.value)
                            } else {
                                selection.insert(option.value)
                            }
                        }
                    }
                }
                .padding(.bottom, RexSpacing.lg)
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.xl)
        .padding(.bottom, RexSpacing.lg)
        .frame(maxWidth: RexLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .background(RexColor.sheetBackground)
    }

    private func chip(text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.white : RexColor.secondaryText)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(
                    active ? PtPalette.solid : RexColor.field,
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            active ? Color.clear : RexColor.fieldBorder,
                            lineWidth: 0.5
                        )
                }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - 更多来源

private struct PtSourcesSheet: View {
    let torrent: MpTorrentItem
    let submittingID: String?
    var onPick: (MpTorrentSource) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 默认站点已在卡片主区域展示，这里只列其余站点。
    private var others: [MpTorrentSource] {
        Array(torrent.variants.dropFirst())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            HStack(spacing: RexSpacing.md) {
                Text("其他来源")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: 0)

                Button("关闭") { dismiss() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(RexColor.field, in: Capsule(style: .continuous))
                    .buttonStyle(PressableButtonStyle())
            }

            Text(PtMeta.splitName(torrent.title).title)
                .font(.system(size: 12))
                .foregroundStyle(RexColor.tertiaryText)
                .lineLimit(2)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(others) { source in
                        row(source)
                    }
                }
                .padding(.bottom, RexSpacing.lg)
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.xl)
        .padding(.bottom, RexSpacing.lg)
        .frame(maxWidth: RexLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .background(RexColor.sheetBackground)
    }

    private func row(_ source: MpTorrentSource) -> some View {
        HStack(spacing: RexSpacing.sm) {
            Text(source.site)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            if let factor = source.volumeFactor?.trimmingCharacters(in: .whitespacesAndNewlines),
               !factor.isEmpty {
                Text(factor)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(
                        factor.contains("免费") ? PtPalette.free : PtPalette.promo,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }

            Spacer(minLength: 0)

            let sizeText = PtMeta.formatSize(source.size)
            if !sizeText.isEmpty {
                Text(sizeText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)
                    .monospacedDigit()
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9.5, weight: .bold))

                Text("\(source.seeders)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(PtPalette.seeders)

            pickButton(source)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(RexColor.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pickButton(_ source: MpTorrentSource) -> some View {
        let busy = submittingID == source.id

        return Button {
            RexHaptics.tap()
            onPick(source)
        } label: {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(PtPalette.accent)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 30, height: 30)
            .background(
                busy ? PtPalette.fill : PtPalette.solid,
                in: Circle()
            )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(submittingID != nil)
        .accessibilityLabel("从 \(source.site) 下载")
    }
}

// MARK: - 确认下载

private struct PtConfirmDialog: View {
    let torrent: MpTorrentItem
    let isSubmitting: Bool
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .onTapGesture { if !isSubmitting { onCancel() } }

            VStack(alignment: .leading, spacing: RexSpacing.md) {
                Text(PtMeta.splitName(torrent.title).title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if !torrent.siteNames.isEmpty {
                        dialogChip(torrent.siteNames.joined(separator: " / "))
                    }

                    let sizeText = PtMeta.formatSize(torrent.size)
                    if !sizeText.isEmpty {
                        dialogChip(sizeText)
                    }

                    dialogChip("做种 \(torrent.seeders)")
                }

                Text("将把该资源提交到 MoviePilot 下载器，确定继续？")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        RexHaptics.tap()
                        onCancel()
                    } label: {
                        Text("取消")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RexColor.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                RexColor.field,
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(isSubmitting)

                    Button {
                        RexHaptics.tap()
                        onConfirm()
                    } label: {
                        Group {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color.white)
                            } else {
                                Text("确认下载")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            PtPalette.solid,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(isSubmitting)
                }
                .padding(.top, 2)
            }
            .padding(18)
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
            .background(
                RexColor.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .padding(.horizontal, RexSpacing.xxl)
            .shadow(color: Color.black.opacity(0.22), radius: 28, y: 12)
        }
        .transition(.opacity)
    }

    private func dialogChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(RexColor.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RexColor.field,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}
