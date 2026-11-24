import SwiftUI
import UIKit

/// 范围搜索结果详情：按 PWA 规则分流三套正文。
/// - 无 hash（AVDB / CloudSaver）→ `ScopePlainDetailBody`（对齐 `ScopeDetailBody`）
/// - hash + bitmagnet → `ScopeBitmagnetDetailBody`（对齐 `BitmagnetDetailBody`）
/// - hash + 其它（色花堂）→ `ScopeResourceDetailBody`（对齐 `ResourceDetailBody`）
struct ScopeResultDetailView: View {
    let item: ScopeItem
    /// 覆盖层由列表页管理，关闭动作走回调而不是 dismiss。
    var onClose: () -> Void

    @State private var isScrolled = false
    @State private var alert: RexAlertInfo?
    @State private var toast: RexToastInfo?

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "资源详情",
                leading: .back(action: { onClose() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailBody
                }
                .padding(.horizontal, RexSpacing.lg)
                .padding(.top, RexSpacing.xs)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "scopeDetailScroll"))
            }
            .rexScrollTracking("scopeDetailScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(RexPageBackground())
        .rexAlert($alert)
        .rexToast($toast)
    }

    @ViewBuilder
    private var detailBody: some View {
        if let hash = item.hash, !hash.isEmpty {
            if item.source == "bitmagnet" {
                ScopeBitmagnetDetailBody(
                    hash: hash,
                    onToast: { toast = $0 },
                    onAlert: { alert = $0 }
                )
            } else {
                ScopeResourceDetailBody(
                    hash: hash,
                    onToast: { toast = $0 },
                    onAlert: { alert = $0 }
                )
            }
        } else {
            ScopePlainDetailBody(
                item: item,
                onToast: { toast = $0 },
                onAlert: { alert = $0 }
            )
        }
    }
}

// MARK: - 无 hash：AVDB / CloudSaver

/// 对齐 PWA `ScopeDetailBody`：详情 / 下载链接 / 单张内容预览。
private struct ScopePlainDetailBody: View {
    let item: ScopeItem
    var onToast: (RexToastInfo) -> Void
    var onAlert: (RexAlertInfo) -> Void

    @Environment(\.apiClient) private var apiClient
    @State private var isSaving = false
    @State private var cover: UIImage?
    @State private var coverFailed = false

    var body: some View {
        ScopeDetailTitle(text: item.title)

        ScopeInfoCard(rows: infoRows)

        linksCard

        if showsPreview {
            previewCard
        }
    }

    // MARK: 详情

    private var infoRows: [ScopeKVRow] {
        var rows: [ScopeKVRow] = [
            ScopeKVRow(key: "来源", value: item.sourceLabel),
            ScopeKVRow(key: "大小", value: item.sizeLabel)
        ]
        if let date = item.publishedAt, !date.isEmpty {
            rows.append(ScopeKVRow(key: "日期", value: date))
        }
        if item.category == "pan" {
            rows.append(ScopeKVRow(key: "类型", value: "网盘"))
        }
        if let hash = item.hash, !hash.isEmpty {
            rows.append(ScopeKVRow(key: "Hash", value: hash, mono: true))
        }
        return rows
    }

    // MARK: 链接

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("下载链接")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)

                Spacer(minLength: 0)

                if let target = copyTarget, !target.isEmpty {
                    ScopeCopyActionButton(label: "复制链接") {
                        copy(target, toast: "已复制链接")
                    }
                }
                if !saveURLs.isEmpty {
                    ScopeSaveActionButton(isSaving: isSaving) {
                        Task { await save() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)

            if linkURLs.isEmpty {
                Text("暂无下载链接")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.tertiaryText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            } else {
                ScopeLinkRowList(links: linkURLs) { url in
                    copy(url, toast: "已复制")
                }
            }
        }
        .scopeDetailCard()
    }

    // MARK: 预览

    private var showsPreview: Bool {
        guard let raw = item.thumbUrl, !raw.isEmpty else { return false }
        return !coverFailed
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScopeCardHead(title: "内容预览")

            ZStack {
                Rectangle()
                    .fill(RexColor.field)

                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(RexColor.tertiaryText)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(RexColor.cardBorder.opacity(0.8), lineWidth: 0.5)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .animation(RexMotion.standard, value: cover != nil)
        }
        .scopeDetailCard()
        .task { await loadCover() }
    }

    // MARK: 链接集合

    /// 与 PWA `scopeLinkRows` 一致：磁力 → 电驴 → 网盘分享，按 URL 去重。
    private var linkURLs: [String] {
        var urls: [String] = []
        if let magnet = item.magnet, !magnet.isEmpty {
            urls.append(magnet)
        }
        if let ed2k = item.ed2k, !ed2k.isEmpty, !urls.contains(ed2k) {
            urls.append(ed2k)
        }
        for link in item.links where !link.url.isEmpty {
            guard !urls.contains(link.url) else { continue }
            urls.append(link.url)
        }
        return urls
    }

    /// 与 PWA `scopeUrls` 一致：转存时提交全部链接。
    private var saveURLs: [String] {
        linkURLs
    }

    /// 与 PWA `scopeCopyTarget` 一致：磁力优先，其次电驴，最后网盘分享。
    private var copyTarget: String? {
        if let magnet = item.magnet, !magnet.isEmpty { return magnet }
        if let ed2k = item.ed2k, !ed2k.isEmpty { return ed2k }
        return item.links.first { !$0.url.isEmpty }?.url
    }

    private var savePassword: String {
        item.links.first { !$0.password.isEmpty }?.password ?? ""
    }

    // MARK: 动作

    private func copy(_ text: String, toast message: String) {
        guard !text.isEmpty else {
            onAlert(.failure("没有可复制的链接"))
            return
        }
        UIPasteboard.general.string = text
        RexHaptics.success()
        onToast(.success(message))
    }

    private func save() async {
        guard let apiClient, !isSaving, !saveURLs.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let result = try await apiClient.panSave(urls: saveURLs, password: savePassword)
            RexHaptics.success()
            if let failed = result.errors.first {
                onAlert(.failure(failed))
            } else {
                onToast(.success("已转存到 115（\(result.count) 项）"))
            }
        } catch {
            RexHaptics.error()
            onAlert(.failure(error.localizedDescription))
        }
    }

    /// AVDB 封面 CDN 是加扰字节流，必须走 `api/makers/image` 解码。
    private func loadCover() async {
        guard let raw = item.thumbUrl, !raw.isEmpty,
              let url = apiClient?.makerImageURL(raw: raw, width: 960) else {
            coverFailed = true
            return
        }
        if let hit = MakerImageStore.shared.cached(url) {
            cover = hit
            return
        }
        let loaded = await MakerImageStore.shared.image(for: url)
        guard !Task.isCancelled else { return }
        cover = loaded
        coverFailed = loaded == nil
    }
}

// MARK: - bitmagnet：本地库种子详情

/// 对齐 PWA `BitmagnetDetailBody`：详情 4 行 / 磁力 / 2 列 16:9 预览 / 文件树 + 汇总 foot。
private struct ScopeBitmagnetDetailBody: View {
    let hash: String
    var onToast: (RexToastInfo) -> Void
    var onAlert: (RexAlertInfo) -> Void

    @Environment(\.apiClient) private var apiClient
    @State private var detail: MagnetDetail?
    @State private var preview: MagnetPreview?
    @State private var isLoadingPreview = true
    @State private var errorText = ""
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        Group {
            if isLoading, detail == nil {
                ScopeDetailLoading()
            } else if let detail {
                content(detail)
            } else {
                ScopeDetailError(text: errorText.isEmpty ? "加载失败" : errorText)
            }
        }
        .task { await load() }
    }

    private func content(_ detail: MagnetDetail) -> some View {
        let name = detail.displayName
        let infoHash = (detail.hash.isEmpty ? hash : detail.hash).lowercased()
        let magnet = detail.primaryMagnet
        let count = detail.effectiveFilesCount
        let created = detail.createdAt

        return VStack(alignment: .leading, spacing: 12) {
            ScopeDetailTitle(text: name)

            ScopeInfoCard(
                rows: [
                    ScopeKVRow(key: "大小", value: ScopeDetailText.byteSize(detail.size)),
                    ScopeKVRow(key: "文件", value: String(count)),
                    ScopeKVRow(key: "创建", value: ScopeDetailText.date(created)),
                    ScopeKVRow(
                        key: "Hash",
                        value: infoHash,
                        mono: true,
                        copyable: true,
                        copyToast: "已复制 Hash"
                    )
                ],
                onCopy: { text, toast in
                    copy(text, toast: toast, empty: "暂无内容可复制")
                }
            )

            magnetCard(name: name, infoHash: infoHash, magnet: magnet)

            if let images = preview?.screenshots.map(\.screenshot), !images.isEmpty {
                ScopeVideoPreviewGrid(images: images)
            } else if isLoadingPreview {
                // 预览接口比详情慢几秒，先铺骨架占住高度，避免卡片迟到导致页面位移
                ScopeVideoPreviewGrid(images: [], skeletonCount: 2)
            }

            fileCard(detail: detail, name: name, count: count, created: created)
        }
    }

    // MARK: 磁力卡

    private func magnetCard(name: String, infoHash: String, magnet: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("磁力链接")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)

                Spacer(minLength: 0)

                if !magnet.isEmpty {
                    ScopeSaveActionButton(isSaving: isSaving) {
                        Task { await save(magnet: magnet) }
                    }
                }
                ScopeCopyActionButton(label: "复制") {
                    copy(magnet, toast: "已复制磁力", empty: "暂无内容可复制")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)

            magnetLine(infoHash: infoHash, magnet: magnet)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .scopeDetailCard()
    }

    @ViewBuilder
    private func magnetLine(infoHash: String, magnet: String) -> some View {
        let short = "magnet:?xt=urn:btih:\(infoHash)"
        if let url = URL(string: magnet.isEmpty ? short : magnet) {
            Link(destination: url) {
                ScopeBreakAllText(
                    text: short,
                    fontSize: 13,
                    color: RexColor.brandBlue
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 28)
            }
        } else {
            ScopeBreakAllText(text: short, fontSize: 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 28)
        }
    }

    // MARK: 文件列表卡

    private func fileCard(
        detail: MagnetDetail,
        name: String,
        count: Int,
        created: Int64
    ) -> some View {
        let hintText = [detail.name, detail.title]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 0) {
            ScopeCardHead(title: "文件列表")

            ScopeTorrentFileListView(files: detail.files, hintText: hintText)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Text("大小 \(ScopeDetailText.byteSize(detail.size))")
                Text("文件 \(count)")
                Text("创建 \(ScopeDetailText.date(created))")
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(RexColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 38)
            .background(RexColor.field.opacity(0.48))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(RexColor.cardBorder.opacity(0.7))
                    .frame(height: 0.5)
            }
        }
        .scopeDetailCard()
    }

    // MARK: 动作

    private func copy(_ text: String, toast message: String, empty: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onAlert(.failure(empty))
            return
        }
        UIPasteboard.general.string = trimmed
        RexHaptics.success()
        onToast(.success(message))
    }

    private func save(magnet: String) async {
        guard let apiClient, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let result = try await apiClient.panSave(urls: [magnet], password: "")
            RexHaptics.success()
            if let failed = result.errors.first {
                onAlert(.failure(failed))
            } else {
                onToast(.success("已转存到 115（\(result.count) 项）"))
            }
        } catch {
            RexHaptics.error()
            onAlert(.failure(error.localizedDescription))
        }
    }

    private func load() async {
        guard let apiClient else { return }
        isLoading = true
        errorText = ""
        defer { isLoading = false }
        defer { isLoadingPreview = false }

        do {
            async let detailTask = apiClient.magnetDetail(hash: hash)
            async let previewTask = apiClient.magnetPreview(hash: hash)
            detail = try await detailTask
            // 预览失败不影响正文（PWA retry 0 静默）。
            preview = try? await previewTask
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 色花堂：资源详情

/// 对齐 PWA `ResourceDetailBody`：描述行 / 密码 / 大小 / 板块 / 来源 / 收录，
/// 链接卡标题随 link_kind 变化，预览为 4 槽网格。
private struct ScopeResourceDetailBody: View {
    let hash: String
    var onToast: (RexToastInfo) -> Void
    var onAlert: (RexAlertInfo) -> Void

    @Environment(\.apiClient) private var apiClient
    @State private var detail: ResourceDetail?
    @State private var errorText = ""
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        Group {
            if isLoading, detail == nil {
                ScopeDetailLoading()
            } else if let detail {
                content(detail)
            } else {
                ScopeDetailError(text: errorText.isEmpty ? "加载失败" : errorText)
            }
        }
        .task { await load() }
    }

    private func content(_ detail: ResourceDetail) -> some View {
        let lines = scopeDescriptionLines(for: detail)
        let password = scopeExtractPassword(from: detail, lines: lines)
        let hasPasswordInDesc = lines.contains { $0.label == "解压密码" }
        let kind = ScopeLinkKind.normalize(detail.linkKind)
        let links = detail.links

        return VStack(alignment: .leading, spacing: 12) {
            ScopeDetailTitle(text: detail.displayTitle)

            ScopeInfoCard(
                rows: infoRows(
                    detail: detail,
                    lines: lines,
                    password: password,
                    hasPasswordInDesc: hasPasswordInDesc,
                    kind: kind
                ),
                onCopy: { text, toast in
                    copy(text, toast: toast, empty: "暂无链接可复制")
                }
            )

            linksCard(detail: detail, kind: kind, links: links)

            if !detail.previewImages.isEmpty {
                ScopePhotoPreviewGrid(images: detail.previewImages)
            }
        }
    }

    // MARK: 详情

    private func infoRows(
        detail: ResourceDetail,
        lines: [ScopeDescriptionLine],
        password: String,
        hasPasswordInDesc: Bool,
        kind: ScopeLinkKind
    ) -> [ScopeKVRow] {
        var rows: [ScopeKVRow] = lines.map { line in
            let isPassword = line.label == "解压密码"
            return ScopeKVRow(
                key: line.label,
                value: line.value,
                mono: isPassword,
                copyable: isPassword,
                copyToast: "已复制密码"
            )
        }

        if !hasPasswordInDesc, !password.isEmpty {
            rows.append(
                ScopeKVRow(
                    key: kind == .share115 ? "分享码" : "解压密码",
                    value: password,
                    mono: true,
                    copyable: true,
                    copyToast: "已复制密码"
                )
            )
        }

        if detail.size > 0 {
            rows.append(ScopeKVRow(key: "大小", value: ScopeDetailText.byteSize(detail.size)))
        }

        if !detail.boardName.isEmpty {
            rows.append(ScopeKVRow(key: "板块", value: detail.boardName))
        }

        if !detail.sourceUrl.isEmpty {
            rows.append(
                ScopeKVRow(
                    key: "来源",
                    value: ScopeDetailText.shortSourceLabel(detail.sourceUrl),
                    link: URL(string: detail.sourceUrl)
                )
            )
        }

        if detail.createdAt > 0 {
            rows.append(ScopeKVRow(key: "收录", value: ScopeDetailText.date(detail.createdAt)))
        }

        if rows.isEmpty {
            rows.append(ScopeKVRow(key: "Hash", value: detail.hash, mono: true))
        }
        return rows
    }

    // MARK: 链接

    private func linksCard(
        detail: ResourceDetail,
        kind: ScopeLinkKind,
        links: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(kind.sectionTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)

                Spacer(minLength: 0)

                if !links.isEmpty {
                    ScopeSaveActionButton(isSaving: isSaving) {
                        Task { await save(detail: detail) }
                    }
                }
                if !links.isEmpty {
                    ScopeCopyActionButton(label: scopeCopyAllLabel(links: links, kind: kind)) {
                        copy(
                            links.joined(separator: "\n"),
                            toast: kind == .magnet ? "已复制磁力" : "已复制链接",
                            empty: "暂无链接可复制"
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)

            if links.isEmpty {
                Text(kind == .stub ? "暂无可用下载链接" : "暂无链接")
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.tertiaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .padding(.bottom, 4)
            } else {
                ScopeLinkRowList(links: links) { url in
                    copy(url, toast: "已复制", empty: "暂无链接可复制")
                }
            }
        }
        .scopeDetailCard()
    }

    // MARK: 动作

    private func copy(_ text: String, toast message: String, empty: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onAlert(.failure(empty))
            return
        }
        UIPasteboard.general.string = trimmed
        RexHaptics.success()
        onToast(.success(message))
    }

    private func save(detail: ResourceDetail) async {
        guard let apiClient, !isSaving, !detail.links.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        let lines = scopeDescriptionLines(for: detail)
        let password = scopeExtractPassword(from: detail, lines: lines)

        do {
            let result = try await apiClient.panSave(urls: detail.links, password: password)
            RexHaptics.success()
            if let failed = result.errors.first {
                onAlert(.failure(failed))
            } else {
                onToast(.success("已转存到 115（\(result.count) 项）"))
            }
        } catch {
            RexHaptics.error()
            onAlert(.failure(error.localizedDescription))
        }
    }

    private func load() async {
        guard let apiClient else { return }
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        do {
            detail = try await apiClient.resourceDetail(hash: hash)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
