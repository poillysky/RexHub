import SwiftUI
import UIKit

/// 详情页展示用的资源元数据，来自搜索服务下发的数据库字段。
struct ResourceMeta: Hashable {
    var sizeText: String = ""
    /// 真实资源文件名；色花堂的帖子标题与文件名不同，详情页顶部用标题、卡片里展示文件名。
    var resourceName: String = ""
    var filesCount: Int = 0
    /// ISO 8601 收录时间，展示前再按本地时区格式化。
    var createdAt: String = ""
    var seeders: Int?
    var leechers: Int?
    var resolution: String = ""
    var codec: String = ""
    var releaseGroup: String = ""
    var boardName: String = ""
    var sourceUrl: String = ""
    var previewImages: [String] = []
    var actresses: [String] = []
    var code: String = ""
    var censored: String = ""
    var description: String = ""

    init() {}

    init(_ item: SearchResult) {
        sizeText = item.sizeText ?? ""
        resourceName = item.resourceName ?? ""
        filesCount = item.filesCount ?? 0
        createdAt = item.createdAt ?? ""
        seeders = item.seeders
        leechers = item.leechers
        resolution = item.resolution ?? ""
        codec = item.codec ?? ""
        releaseGroup = item.releaseGroup ?? ""
        boardName = item.boardName ?? ""
        sourceUrl = item.sourceUrl ?? ""
        previewImages = item.previewImages ?? []
        actresses = item.actresses ?? []
        code = item.code ?? ""
        censored = item.censored ?? ""
        description = item.description ?? ""
    }
}

/// 从搜索结果进入资源详情页时携带的数据。
struct ResourceDetailTarget: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let link: String
    let password: String
    let kind: String
    let sourceName: String
    var meta = ResourceMeta()
}

/// 资源详情：独立整页，按「详情 / 链接 / 内容预览」三段展示资源信息，
/// 支持单条复制 / 全部复制 / 转存 115。
struct ResourceDetailView: View {
    let target: ResourceDetailTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.apiClient) private var apiClient
    @Environment(\.openURL) private var openURL

    @State private var toast: String?
    @State private var isSaving = false
    @State private var loadedPreviewImages: [UIImage] = []

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    titleBlock
                    detailCard
                    linkCard
                    previewCard
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, RexSpacing.xxl)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .task { await loadPreviewImages() }
            }
            .scrollBounceBehavior(.basedOnSize)
            .overlay(alignment: .top) {
                if let toast {
                    RexToastBanner(message: toast)
                        .padding(.horizontal, RexSpacing.xl)
                        .padding(.top, RexSpacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(RexMotion.quick, value: toast)
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var meta: ResourceMeta { target.meta }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: RexSpacing.sm) {
            Button {
                RexHaptics.tap()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("返回")

            Text("资源详情")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .frame(maxWidth: .infinity)

            Color.clear.frame(width: 44, height: 44)
        }
        .frame(height: 44)
        .padding(.horizontal, RexSpacing.md)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)
        }
    }

    // MARK: - 标题

    private var titleBlock: some View {
        Text(target.title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(RexColor.primaryText)
            .lineLimit(4)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 详情

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("详情")
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(Array(detailRows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    rowDivider
                }

                detailRowView(row)
            }
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.largeCard)
    }

    /// 一行一个字段，取不到的字段直接不出现。
    /// 顶部已经展示帖子标题，这里只在文件名与标题不同时补一行「资源名称」。
    private var detailRows: [DetailRow] {
        var rows: [DetailRow] = []

        if !meta.resourceName.isEmpty, meta.resourceName != target.title {
            rows.append(DetailRow(label: "资源名称", value: meta.resourceName))
        }

        if !meta.code.isEmpty {
            rows.append(DetailRow(label: "番号", value: meta.code, mono: true))
        }

        if !meta.actresses.isEmpty {
            rows.append(DetailRow(label: "出演", value: meta.actresses.joined(separator: "、")))
        }

        if !meta.censored.isEmpty {
            rows.append(DetailRow(label: "是否有码", value: meta.censored))
        }

        if let size = displaySize {
            rows.append(DetailRow(label: "大小", value: size))
        }

        if !meta.boardName.isEmpty {
            rows.append(DetailRow(label: "板块", value: meta.boardName))
        }

        if !meta.resolution.isEmpty {
            rows.append(DetailRow(label: "画质", value: meta.resolution))
        }

        if !meta.codec.isEmpty {
            rows.append(DetailRow(label: "编码", value: meta.codec))
        }

        if !meta.releaseGroup.isEmpty {
            rows.append(DetailRow(label: "发布组", value: meta.releaseGroup))
        }

        if meta.filesCount > 0 {
            rows.append(DetailRow(label: "文件数", value: "\(meta.filesCount) 个"))
        }

        if let seeders = meta.seeders {
            rows.append(
                DetailRow(label: "做种 / 下载", value: "\(seeders) / \(meta.leechers ?? 0)")
            )
        }

        if let sourceLink {
            rows.append(DetailRow(label: "来源", value: sourceDisplay, link: sourceLink))
        }

        if !collectionDate.isEmpty {
            rows.append(DetailRow(label: "收录", value: collectionDate))
        }

        if !target.password.isEmpty {
            rows.append(
                DetailRow(
                    label: "提取码",
                    value: target.password,
                    mono: true,
                    copyValue: target.password
                )
            )
        }

        return rows
    }

    /// 一行一个字段：标签左对齐定宽，值占满剩余宽度，长内容最多两行。
    /// 统一用居中对齐，单行和两行时标签、值、图标都在同一条中线上。
    private func detailRowView(_ row: DetailRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(row.label)
                .font(.system(size: 11.5))
                .foregroundStyle(RexColor.tertiaryText)
                .frame(width: 66, alignment: .leading)

            if let url = row.link {
                Button {
                    RexHaptics.tap()
                    openURL(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(row.value)
                            .font(.system(size: 12.5))
                            .foregroundStyle(RexColor.brandBlue)
                            .multilineTextAlignment(.leading)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(RexColor.brandBlue.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("打开来源帖子")
            } else {
                Text(row.value)
                    .font(
                        row.mono
                            ? .system(size: 12, design: .monospaced)
                            : .system(size: 12.5)
                    )
                    .foregroundStyle(RexColor.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let copyValue = row.copyValue {
                    rowCopyButton(copyValue, message: "已复制\(row.label)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(minHeight: 30, alignment: .center)
    }

    /// 详情行内的复制按钮：26×26 与 30 的行高正好同高，不会把行撑起来。
    private func rowCopyButton(_ value: String, message: String) -> some View {
        Button {
            copy(value, message: message)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(RexColor.brandBlue)
                .frame(width: 26, height: 26)
                .background(
                    RexColor.brandBlue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(message)
    }

    // MARK: - 链接

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                cardHeader(linkSectionTitle)

                if links.count > 1 {
                    Text("\(links.count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(RexColor.tertiaryText)
                        .padding(.horizontal, 4)
                        .frame(height: 15)
                        .background(RexColor.field, in: Capsule(style: .continuous))
                }

                Spacer(minLength: 4)

                if !links.isEmpty {
                    transferPill
                    copyAllPill
                }
            }

            if links.isEmpty {
                RexNote(text: "该资源没有提供原始链接。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                        if index > 0 {
                            Rectangle()
                                .fill(RexColor.divider)
                                .frame(height: 1 / displayScale)
                        }

                        linkRow(link, index: index)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.largeCard)
    }

    private func linkRow(_ link: String, index: Int) -> some View {
        HStack(alignment: .center, spacing: 7) {
            if links.count > 1 {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(width: 18, height: 18)
                    .background(RexColor.brandBlue.opacity(0.10), in: Circle())
            }

            Text(displayLink(link))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .lineSpacing(1.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            miniCopyButton(link, message: "已复制第 \(index + 1) 条链接")
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transferPill: some View {
        Button {
            Task { await transfer() }
        } label: {
            HStack(spacing: 3) {
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(RexColor.brandBlue)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                }

                Text(isSaving ? "转存中…" : "转存 115")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(RexColor.brandBlue)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RexColor.brandBlue.opacity(0.11), in: Capsule(style: .continuous))
            .frame(minHeight: 32)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isSaving)
        .opacity(isSaving ? 0.7 : 1)
        .accessibilityLabel("转存到 115 网盘")
    }

    private var copyAllPill: some View {
        Button {
            copyAllLinks()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))

                Text(copyAllTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(RexColor.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RexColor.surface, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .frame(minHeight: 32)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(copyAllTitle)
    }

    // MARK: - 内容预览

    /// 只有真正加载成功的图片才渲染卡片：没有图片、加载失败都不出现空图框。
    @ViewBuilder
    private var previewCard: some View {
        if !loadedPreviewImages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    cardHeader("内容预览")

                    Text("\(loadedPreviewImages.count) 张")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(RexColor.tertiaryText)
                        .padding(.horizontal, 4)
                        .frame(height: 15)
                        .background(RexColor.field, in: Capsule(style: .continuous))

                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(loadedPreviewImages.enumerated()), id: \.offset) { _, image in
                        PreviewImage(image: image)
                    }

                    if loadedPreviewImages.count == 1 {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rexCard(cornerRadius: RexRadius.largeCard)
            .transition(.opacity)
        }
    }

    /// 最多两张，加载失败的直接丢弃；全部失败就整张卡片不显示。
    private func loadPreviewImages() async {
        guard loadedPreviewImages.isEmpty else { return }

        let candidates = Array(meta.previewImages.prefix(2))
        guard !candidates.isEmpty else { return }

        let referer = Self.previewReferer(for: meta.sourceUrl)
        var results: [(index: Int, image: UIImage)] = []

        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, raw) in candidates.enumerated() {
                guard let url = URL(string: raw) else { continue }

                group.addTask {
                    (index, await Self.fetchPreviewImage(url, referer: referer))
                }
            }

            for await (index, image) in group {
                guard let image else { continue }
                results.append((index, image))
            }
        }

        guard !results.isEmpty else { return }

        withAnimation(RexMotion.standard) {
            loadedPreviewImages = results.sorted { $0.index < $1.index }.map(\.image)
        }
    }

    /// 图床大多做了防盗链：不带 Referer 直接 403（色花堂的 tu.* 域实测 403，带来源页 200）。
    private static func previewReferer(for sourceUrl: String) -> String {
        if let url = URL(string: sourceUrl), let scheme = url.scheme, let host = url.host {
            return "\(scheme)://\(host)/"
        }
        return "https://www.sehuatang.net/"
    }

    private static let previewUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// 很多预览图是 `http://` 地址，而 App 只开了本地网络的 ATS 例外，
    /// 明文请求会被系统拦掉；优先尝试同地址的 https 版本。
    private static func previewCandidates(for url: URL) -> [URL] {
        guard url.scheme?.lowercased() == "http" else { return [url] }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        components.scheme = "https"
        guard let secure = components.url else { return [url] }
        return [secure, url]
    }

    private static func fetchPreviewImage(_ url: URL, referer: String) async -> UIImage? {
        if let cached = PreviewImageCache.shared.image(for: url) {
            return cached
        }

        for candidate in previewCandidates(for: url) {
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 15
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue(previewUA, forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
            guard let image = UIImage(data: data) else { continue }

            PreviewImageCache.shared.insert(image, for: url)
            return image
        }
        return nil
    }

    // MARK: - 辅助

    private func cardHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(RexColor.tertiaryText)
    }

    /// 磁力/ed2k 是一整段没有空格的长 token，直接排会整段被挤到第二行。
    /// 在分隔符后、以及长串每 12 个字符处补零宽空格，让它能在两行内均匀折行；
    /// 复制仍然使用原始字符串。
    private func displayLink(_ link: String) -> String {
        var result = ""
        var run = 0

        for character in link {
            result.append(character)

            if character == " " {
                run = 0
                continue
            }

            if "?:&|/".contains(character) {
                result.append("\u{200B}")
                run = 0
                continue
            }

            run += 1
            if run >= 12 {
                result.append("\u{200B}")
                run = 0
            }
        }

        return result
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(RexColor.divider)
            .frame(height: 1 / displayScale)
            .padding(.horizontal, 12)
    }

    /// 解析字段里的全部链接：同一字段可能用换行 / 空格 / 逗号分隔多条。
    private var links: [String] {
        let raw = target.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        let pattern = "magnet:\\?\\S+|ed2k://\\S+|https?://\\S+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [raw]
        }
        let ns = raw as NSString
        let found = regex
            .matches(in: raw, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }

        return found.isEmpty ? [raw] : found
    }

    private var linkKind: DetailLinkKind {
        guard let first = links.first else { return .unknown(target.kind) }
        return DetailLinkKind(first, fallbackKind: target.kind)
    }

    private var linkSectionTitle: String {
        let kinds = Set(links.map { DetailLinkKind($0) })
        guard kinds.count == 1, let only = kinds.first else {
            return "资源链接"
        }
        switch only {
        case .magnet: return "磁力链接"
        case .ed2k: return "ed2k 链接"
        case .share115: return "115 分享链接"
        case .direct: return "直链"
        case .unknown: return "资源链接"
        }
    }

    private var copyAllTitle: String {
        let kinds = Set(links.map { DetailLinkKind($0) })
        if kinds.count == 1, kinds.first == .magnet {
            return "复制磁力"
        }
        return links.count > 1 ? "全部复制" : "复制链接"
    }

    private var displaySize: String? {
        let text = meta.sizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var collectionDate: String {
        let raw = meta.createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return "" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 来源行文案：域名 + 帖子号，例如「www.sehuatang.net · 帖子 451074」。
    private var sourceDisplay: String {
        guard let url = URL(string: meta.sourceUrl), let host = url.host else {
            return target.sourceName
        }
        let id = threadID(from: url)
        return id.isEmpty ? host : "\(host) · 帖子 \(id)"
    }

    private var sourceLink: URL? {
        guard let url = URL(string: meta.sourceUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func threadID(from url: URL) -> String {
        let raw = url.absoluteString
        guard let regex = try? NSRegularExpression(pattern: "thread-(\\d+)"),
              let match = regex.firstMatch(
                in: raw,
                range: NSRange(location: 0, length: (raw as NSString).length)
              ),
              match.numberOfRanges > 1 else { return "" }
        return (raw as NSString).substring(with: match.range(at: 1))
    }

    /// 紧凑复制按钮：视觉 24×24，点击区域 32×32，不把行高撑起来。
    private func miniCopyButton(_ value: String, message: String) -> some View {
        Button {
            copy(value, message: message)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RexColor.brandBlue)
                .frame(width: 24, height: 24)
                .background(
                    RexColor.brandBlue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(message)
    }

    private func copyAllLinks() {
        guard !links.isEmpty else { return }
        if links.count > 1 {
            copy(links.joined(separator: "\n"), message: "已复制全部 \(links.count) 条链接")
            return
        }
        let name = copyAllTitle.replacingOccurrences(of: "复制", with: "")
        copy(links.joined(separator: "\n"), message: "已复制\(name)")
    }

    private func copy(_ value: String, message: String) {
        UIPasteboard.general.string = value
        RexHaptics.success()
        withAnimation(RexMotion.quick) { toast = message }

        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(RexMotion.quick) { toast = nil }
        }
    }

    @MainActor
    private func transfer() async {
        guard !links.isEmpty else { return }
        guard let apiClient else {
            RexHaptics.warning()
            withAnimation(RexMotion.quick) { toast = "服务未连接" }
            return
        }
        guard !isSaving else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            let result = try await apiClient.panSave(urls: links, password: target.password)
            if let error = result.errors.first, result.count == 0 {
                RexHaptics.warning()
                withAnimation(RexMotion.quick) { toast = error }
            } else {
                RexHaptics.success()
                withAnimation(RexMotion.quick) { toast = "已转存 \(result.count) 项到 115" }
            }
        } catch {
            RexHaptics.warning()
            withAnimation(RexMotion.quick) { toast = message(for: error) }
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(RexMotion.quick) { toast = nil }
        }
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            if case .conflict(let detail) = apiError, let detail, !detail.isEmpty {
                return detail
            }
            return apiError.errorDescription ?? "转存失败，请稍后重试"
        }
        return error.localizedDescription
    }
}

/// 详情卡里的一行：左侧灰色标签，右侧值；可点击外链或带上复制按钮。
private struct DetailRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var link: URL?
    var mono: Bool = false
    var copyValue: String?
}

/// 自适应预览图：按图片真实比例排布，横图更矮、竖图更高；由上层决定是否/显示几张。
private struct PreviewImage: View {
    let image: UIImage

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .accessibilityLabel("内容预览")
    }

    /// 竖图最多拉长到 0.62（约 5:8），横图最多压到 1.9，避免极端比例把卡片撑爆。
    private var aspect: CGFloat {
        guard image.size.height > 0 else { return 0.75 }
        return min(max(image.size.width / image.size.height, 0.62), 1.9)
    }
}

/// 预览图小缓存，避免翻回列表再进详情时重复下载。
private final class PreviewImageCache {
    static let shared = PreviewImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

/// 详情页的链接类型：图标与搜索结果的类型胶囊保持一致。
private enum DetailLinkKind: Hashable {
    case magnet
    case ed2k
    case share115
    case direct
    case unknown(String)

    init(_ link: String, fallbackKind: String = "") {
        let lower = link.lowercased()
        if lower.hasPrefix("magnet:") {
            self = .magnet
        } else if lower.hasPrefix("ed2k://") {
            self = .ed2k
        } else if lower.contains("115.com/s/") || lower.contains("115cdn.com/s/") {
            self = .share115
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            self = .direct
        } else {
            self = .unknown(fallbackKind)
        }
    }

    var tint: Color {
        switch self {
        case .magnet: return RexColor.brandBlue
        case .ed2k: return Color(hex: 0x2563EB)
        case .share115: return Color(hex: 0x0EA5E9)
        case .direct: return Color(hex: 0x10B981)
        case .unknown: return RexColor.secondaryText
        }
    }

    var rowSymbol: String {
        switch self {
        case .magnet: return "link"
        case .ed2k: return "link"
        case .share115: return "cloud.fill"
        case .direct: return "safari"
        case .unknown: return "shippingbox.fill"
        }
    }
}

#Preview {
    NavigationStack {
        ResourceDetailView(
            target: ResourceDetailTarget(
                title: "流浪地球2 4K HDR 国语中字 2023",
                link: "magnet:?xt=urn:btih:F434BFDA452A1CF89785081163CC505061E89A74&dn=test",
                password: "",
                kind: "磁力",
                sourceName: "色花堂",
                meta: sampleMeta()
            )
        )
    }
}

/// 预览用的元数据构造器（仅 #Preview 使用）。
private func sampleMeta() -> ResourceMeta {
    var meta = ResourceMeta()
    meta.sizeText = "5.01 GB"
    meta.createdAt = "2026-09-27T15:23:44.494051+00:00"
    meta.boardName = "4K 原版"
    meta.sourceUrl = "https://www.sehuatang.net/thread-451074-1-1.html"
    meta.code = "WAND-123"
    meta.censored = "有码"
    meta.actresses = ["示例演员"]
    meta.seeders = 12
    meta.leechers = 3
    meta.previewImages = [
        "https://picsum.photos/seed/rex1/300/400",
        "https://picsum.photos/seed/rex2/300/400",
    ]
    return meta
}
