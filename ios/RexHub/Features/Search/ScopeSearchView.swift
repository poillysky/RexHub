import SwiftUI
import UIKit

/// 范围搜索结果：影视 / 片商两类多源聚合，支持来源、排序、时间与大小筛选。
struct ScopeSearchView: View {
    @State private var scope: SearchScope
    /// 顶栏改用首页同款可输入搜索框（从首页搜索入口进入时为 true）。
    var editableHeader: Bool

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var hasSubmitted: Bool
    @State private var items: [ScopeItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var sourceErrors: [String: String] = [:]
    @State private var options = ScopeSearchOptions()
    @State private var isScrolled = false
    @State private var alert: RexAlertInfo?
    @State private var toast: RexToastInfo?
    @State private var savingID: String?
    @State private var detailItem: ScopeItem?
    /// 详情覆盖层跟随手指右滑的位移。
    @State private var detailDrag: CGFloat = 0
    /// 每次发起搜索自增，用于丢弃切换范围后过期的旧响应。
    @State private var loadGeneration = 0
    @FocusState private var isSearchFocused: Bool

    init(keyword: String, scope: SearchScope, editableHeader: Bool = false) {
        _scope = State(initialValue: scope)
        self.editableHeader = editableHeader

        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        _query = State(initialValue: trimmed)
        _hasSubmitted = State(initialValue: !editableHeader || !trimmed.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 列表始终挂载在下面，详情以页内覆盖层推出，返回时数据与滚动位置都不丢。
            listContent

            if let detailItem {
                ScopeResultDetailView(item: detailItem, onClose: { closeDetail() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: detailDrag)
                    .transition(.move(edge: .trailing))
                    .simultaneousGesture(detailBackGesture)
                    .zIndex(1)
            }
        }
        .background(RexPageBackground())
        .animation(RexMotion.standard, value: detailItem?.id)
        // 详情覆盖层打开时关掉系统侧滑返回，右滑只关覆盖层，不弹掉整个搜索页。
        .rexPushedScreen(detailItem == nil)
        .task {
            if !editableHeader || hasSubmitted {
                // 只在列表为空时首次拉取，重新出现时保留已有内容与滚动位置。
                if items.isEmpty { await load(reset: true) }
            } else {
                // 从首页搜索入口进入时直接聚焦，省一次点击。
                try? await Task.sleep(nanoseconds: 350_000_000)
                isSearchFocused = true
            }
        }
        .rexAlert($alert)
        .rexToast($toast)
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            if editableHeader {
                searchHeader
            } else {
                RexNavBar(
                    title: "\(scope.title)搜索",
                    leading: .back(action: { dismiss() }),
                    isScrolled: isScrolled
                )
            }

            filterBar

            ScrollView {
                VStack(spacing: RexSpacing.md) {
                    if !hasSubmitted {
                        RexStateCard(
                            symbol: "magnifyingglass",
                            title: "搜索片名、番号或关键词",
                            message: "支持影视与片商多源聚合搜索。",
                            tone: .neutral
                        )
                    } else if isLoading, items.isEmpty {
                        loadingStatus

                        ForEach(0..<3, id: \.self) { _ in
                            skeletonCard
                        }
                    } else if let errorText, items.isEmpty {
                        RexStateCard(
                            symbol: "exclamationmark.triangle.fill",
                            title: "搜索失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await load(reset: true) }
                        }
                    } else if items.isEmpty {
                        RexStateCard(
                            symbol: "magnifyingglass",
                            title: "没有匹配结果",
                            message: "试试更短的关键词，或切换搜索范围。",
                            tone: .neutral
                        )
                    } else {
                        resultHint

                        ForEach(items) { item in
                            ScopeResultCard(
                                item: item,
                                isSaving: savingID.map { url in
                                    item.actionableLinks.contains { $0.url == url }
                                } ?? false,
                                onCopy: { copy($0) },
                                onSave: { link in Task { await save(link) } },
                                onOpenDetail: { detailItem = $0 }
                            )
                        }

                        listFooter
                    }
                }
                .padding(.horizontal, RexSpacing.lg)
                .padding(.top, RexSpacing.xs)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "scopeSearchScroll"))
            }
            .rexScrollTracking("scopeSearchScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load(reset: true) }
        }
    }

    /// 详情覆盖层关闭：位移与移除一起做动画，避免先跳回原位再滑出。
    private func closeDetail() {
        withAnimation(RexMotion.standard) {
            detailDrag = 0
            detailItem = nil
        }
    }

    /// 左边缘右滑返回（对齐 PWA 的侧滑关闭），位移跟手，松手按距离或甩动速度决定去留。
    private var detailBackGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.startLocation.x < 32,
                      value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                detailDrag = value.translation.width
            }
            .onEnded { value in
                guard detailDrag > 0 else { return }
                let flicked = value.predictedEndTranslation.width > 240
                let draggedFar = value.translation.width > 90
                if flicked || draggedFar {
                    closeDetail()
                } else {
                    withAnimation(RexMotion.quick) { detailDrag = 0 }
                }
            }
    }

    // MARK: - 顶栏

    /// 首页同款顶栏：返回 + 可输入搜索胶囊（进入搜索列表页时使用）。
    private var searchHeader: some View {
        HStack(spacing: 0) {
            Button {
                RexHaptics.tap()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(width: RexLayout.minTouch, height: RexLayout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("返回")

            searchCapsule
                .padding(.leading, 4)
        }
        .padding(.leading, RexSpacing.md)
        .padding(.trailing, RexSpacing.xl)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.lg)
    }

    private var searchCapsule: some View {
        HStack(spacing: 6) {
            scopeSwitch

            Rectangle()
                .fill(RexColor.cardBorder)
                .frame(width: 1, height: 18)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("搜索")
                        .font(RexFont.body)
                        .foregroundStyle(RexColor.tertiaryText)
                }

                TextField("", text: $query)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)
                    .tint(RexColor.brandBlue)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit(submit)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !query.isEmpty {
                Button {
                    RexHaptics.tap()
                    clearQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(RexColor.tertiaryText)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("清空搜索")
            }

            searchButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .homeSearchCapsule()
    }

    /// 片商 / 影视 搜索范围切换：点一下来回切。
    private var scopeSwitch: some View {
        Button {
            RexHaptics.selection()
            switchScope()
        } label: {
            Text(scope.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(RexColor.field, in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isLoading)
        .accessibilityLabel("搜索范围：\(scope.title)，点击切换")
    }

    private var searchButton: some View {
        Button {
            RexHaptics.tap()
            submit()
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(RexColor.onBrand)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(RexColor.onBrand)
                }
            }
            .frame(width: 34, height: 34)
            .background(RexColor.brandGradient, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isLoading)
        .accessibilityLabel("搜索")
    }

    // MARK: - 筛选

    /// 与 PWA 一致的 4 列筛选：来源 / 排序 / 大小 / 时间。
    private var filterBar: some View {
        HStack(spacing: 7) {
            filterTrigger(
                title: "来源",
                value: label(in: sourceFilterOptions, value: options.source, fallback: "全部"),
                options: sourceFilterOptions,
                selection: options.source
            ) { value in
                options.source = value
                Task { await load(reset: true) }
            }

            filterTrigger(
                title: "排序",
                value: label(in: ScopeSearchOptions.sortOptions, value: options.sort, fallback: "相关度"),
                options: ScopeSearchOptions.sortOptions,
                selection: options.sort
            ) { value in
                options.sort = value
                Task { await load(reset: true) }
            }

            filterTrigger(
                title: "大小",
                value: label(in: ScopeSearchOptions.sizeOptions, value: options.filterSize, fallback: "不限"),
                options: ScopeSearchOptions.sizeOptions,
                selection: options.filterSize
            ) { value in
                options.filterSize = value
                Task { await load(reset: true) }
            }

            filterTrigger(
                title: "时间",
                value: label(in: ScopeSearchOptions.timeOptions, value: options.filterTime, fallback: "不限"),
                options: ScopeSearchOptions.timeOptions,
                selection: options.filterTime
            ) { value in
                options.filterTime = value
                Task { await load(reset: true) }
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.xs)
        .padding(.bottom, RexSpacing.sm)
    }

    private var sourceFilterOptions: [(id: String, label: String)] {
        [("all", "全部")] + scope.sources.map { (id: $0.id, label: $0.label) }
    }

    /// 两行式筛选触发器：小号字段名 + 加粗当前值 + 下拉箭头。
    private func filterTrigger(
        title: String,
        value: String,
        options: [(id: String, label: String)],
        selection: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    guard option.id != selection else { return }
                    RexHaptics.selection()
                    onSelect(option.id)
                } label: {
                    if option.id == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(RexColor.tertiaryText)

                HStack(spacing: 2) {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RexColor.surface.opacity(0.86),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(RexColor.cardBorder.opacity(0.85), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 8, x: 0, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 列表辅助

    private var loadingStatus: some View {
        HStack(spacing: RexSpacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(RexColor.brandBlue)

            Text(query.isEmpty ? "正在搜索" : "正在搜索「\(query)」")
                .font(.system(size: 14))
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
    }

    /// 与结果卡片同构的骨架：标题行 + 链接行 + 底栏。
    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                RexSkeleton(height: 12, cornerRadius: 4)
                RexSkeleton(width: 180, height: 12, cornerRadius: 4)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            RexSkeleton(height: 14, cornerRadius: 4)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            HStack(spacing: 6) {
                RexSkeleton(width: 58, height: 18, cornerRadius: 9)
                RexSkeleton(width: 96, height: 18, cornerRadius: 5)
                Spacer(minLength: 0)
                RexSkeleton(width: 62, height: 22, cornerRadius: 11)
                RexSkeleton(width: 68, height: 22, cornerRadius: 11)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RexColor.field.opacity(0.4))
        }
        .background(RexColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var resultHint: some View {
        if !sourceErrors.isEmpty {
            RexInlineNotice(
                title: "部分来源不可用",
                message: sourceErrors
                    .map { "\(label(for: $0.key))：\($0.value)" }
                    .joined(separator: "\n"),
                tone: .warning
            )
        }
    }

    @ViewBuilder
    private var listFooter: some View {
        if hasMore {
            Button {
                Task { await load(reset: false) }
            } label: {
                Text(isLoading ? "加载更多…" : "加载更多")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isLoading ? RexColor.tertiaryText : RexColor.brandBlue)
                    .frame(minWidth: 120, minHeight: 40)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isLoading)
            .onAppear {
                guard !isLoading, hasMore else { return }
                Task { await load(reset: false) }
            }
        } else {
            Text("已全部加载")
                .font(.system(size: 12))
                .foregroundStyle(RexColor.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, RexSpacing.xs)
        }
    }

    // MARK: - 数据

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearchFocused = true
            return
        }

        isSearchFocused = false
        query = trimmed
        items = []
        page = 1
        hasMore = true
        errorText = nil
        sourceErrors = [:]
        hasSubmitted = true
        Task { await load(reset: true) }
    }

    private func clearQuery() {
        // 清空输入即作废旧请求，避免在途响应回填到空列表。
        loadGeneration += 1
        isLoading = false
        query = ""
        items = []
        page = 1
        hasMore = true
        errorText = nil
        sourceErrors = [:]
        hasSubmitted = false
        isSearchFocused = true
    }

    /// 切换到另一范围并重置来源筛选；输入框有词就立即按新范围重搜。
    private func switchScope() {
        let next: SearchScope = scope == .movie ? .maker : .movie
        scope = next
        ScopeSelectionStore.save(next)
        options.source = "all"
        items = []
        page = 1
        hasMore = true
        errorText = nil
        sourceErrors = [:]

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 没有关键词时不发请求，但也要作废在途的旧范围请求。
            loadGeneration += 1
            isLoading = false
            hasSubmitted = false
            return
        }

        // 切范围时即使上一次请求还在飞，也要立刻按新范围重发。
        hasSubmitted = true
        Task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard let apiClient else { return }
        if !reset, isLoading { return }
        if reset {
            page = 1
            hasMore = true
            errorText = nil
            sourceErrors = [:]
        } else {
            guard hasMore else { return }
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        do {
            let response = try await apiClient.searchScope(
                scope: scope,
                keyword: query.trimmingCharacters(in: .whitespacesAndNewlines),
                page: page,
                options: options
            )

            // 期间已切换范围或重新搜索：丢弃这次过期响应。
            guard generation == loadGeneration else { return }

            // 过滤条件变化时结果是全新的，不能拿旧列表去重，否则同 id 会被整批滤掉。
            var seen = reset ? Set<String>() : Set(items.map(\.id))
            let fresh = response.items.filter { seen.insert($0.id).inserted }

            if reset {
                items = fresh
            } else {
                items.append(contentsOf: fresh)
            }
            sourceErrors = response.sourceErrors
            hasMore = response.hasMore
            if hasMore { page += 1 }
            errorText = nil
        } catch {
            guard generation == loadGeneration else { return }
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        RexHaptics.success()
        showToast("已复制链接")
    }

    private func save(_ link: (label: String, url: String, password: String)) async {
        guard let apiClient, savingID == nil else { return }
        savingID = link.url
        defer { savingID = nil }

        do {
            let result = try await apiClient.panSave(urls: [link.url], password: link.password)
            RexHaptics.success()
            let failed = result.errors.first
            showToast(failed ?? "已转存到 115（\(result.count) 项）", isError: failed != nil)
        } catch {
            RexHaptics.error()
            showToast(error.localizedDescription, isError: true)
        }
    }

    private func showToast(_ text: String, isError: Bool = false) {
        if isError {
            alert = .failure(text)
        } else {
            toast = .success(text)
        }
    }

    private func label(for source: String) -> String {
        scope.sources.first { $0.id == source }?.label ?? source
    }

    private func label(
        in options: [(id: String, label: String)],
        value: String,
        fallback: String
    ) -> String {
        options.first { $0.id == value }?.label ?? fallback
    }
}

// MARK: - 结果卡片（对齐 PWA .bm-card）

private struct ScopeResultCard: View {
    let item: ScopeItem
    let isSaving: Bool
    var onCopy: (String) -> Void
    var onSave: ((label: String, url: String, password: String)) -> Void
    var onOpenDetail: (ScopeItem) -> Void

    private var primaryLink: (label: String, url: String, password: String)? {
        item.actionableLinks.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !linkRows.isEmpty {
                linkList
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RexColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(RexColor.cardBorder.opacity(0.65), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.03), radius: 1, x: 0, y: 1)
        .shadow(color: .black.opacity(0.05), radius: 13, x: 0, y: 10)
    }

    // MARK: 头部

    private var header: some View {
        Button {
            RexHaptics.tap()
            onOpenDetail(item)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.27)
                    .foregroundStyle(RexColor.primaryText)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RexColor.tertiaryText)
                    .padding(.top, 5)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("查看资源详情")
    }

    private var sourceBadge: some View {
        Text(item.sourceLabel)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(badgeTint)
            .padding(.horizontal, 7)
            .frame(minHeight: 19)
            .background(badgeFill, in: Capsule(style: .continuous))
    }

    private var badgeTint: Color {
        switch item.source {
        case "bitmagnet": Color(hex: 0x0066D6)
        case "cloudsaver": Color(hex: 0x248A3D)
        case "sehuatang": Color(hex: 0xC56A00)
        case "avdb": Color(hex: 0x8944AB)
        default: RexColor.secondaryText
        }
    }

    private var badgeFill: Color {
        switch item.source {
        case "bitmagnet": Color(hex: 0x007AFF).opacity(0.13)
        case "cloudsaver": Color(hex: 0x34C759).opacity(0.14)
        case "sehuatang": Color(hex: 0xFF9500).opacity(0.14)
        case "avdb": Color(hex: 0xAF52DE).opacity(0.14)
        default: Color(white: 0.5).opacity(0.14)
        }
    }

    // MARK: 链接行

    private struct LinkRow: Identifiable {
        let id: String
        let icon: String
        let isMono: Bool
        let primary: String
        let secondary: String
        let url: String
    }

    private var linkRows: [LinkRow] {
        var rows: [LinkRow] = []

        if let magnet = item.magnet, !magnet.isEmpty {
            rows.append(LinkRow(id: magnet, icon: "🧲", isMono: true,
                                primary: magnet, secondary: "", url: magnet))
        }

        if let ed2k = item.ed2k, !ed2k.isEmpty {
            rows.append(LinkRow(id: ed2k, icon: "🔗", isMono: false,
                                primary: ed2kName(ed2k) ?? "电驴链接",
                                secondary: item.sizeLabel,
                                url: ed2k))
        }

        for link in item.links where !link.url.isEmpty {
            guard !rows.contains(where: { $0.url == link.url }) else { continue }
            let name = link.label.isEmpty ? "链接" : link.label
            let detail = link.password.isEmpty
                ? link.url
                : "\(link.url) · 提取码 \(link.password)"
            rows.append(LinkRow(id: link.url, icon: "", isMono: false,
                                primary: name, secondary: detail, url: link.url))
        }

        return rows
    }

    private var linkList: some View {
        VStack(spacing: 0) {
            ForEach(linkRows) { row in
                Button {
                    RexHaptics.tap()
                    onCopy(row.url)
                } label: {
                    HStack(spacing: 8) {
                        if !row.icon.isEmpty {
                            Text(row.icon)
                                .font(.system(size: 12))
                                .frame(width: 16)
                        }

                        if row.isMono {
                            Text(row.primary)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(RexColor.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(row.primary)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RexColor.primaryText)
                                .lineLimit(1)
                                .layoutPriority(1)

                            Text(row.secondary)
                                .font(.system(size: 11))
                                .foregroundStyle(RexColor.tertiaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .overlay(alignment: .bottom) {
                    if row.id != linkRows.last?.id {
                        Rectangle()
                            .fill(RexColor.cardBorder.opacity(0.85))
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// ed2k://|file|文件名|大小|哈希|/
    private func ed2kName(_ link: String) -> String? {
        let parts = link.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count > 2, parts[1].lowercased() == "file" else { return nil }
        let name = String(parts[2])
        guard !name.isEmpty else { return nil }
        return name.removingPercentEncoding ?? name
    }

    // MARK: 底栏

    private var footer: some View {
        footerRow
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(RexColor.field.opacity(0.55))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(RexColor.cardBorder.opacity(0.7))
                    .frame(height: 0.5)
            }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                sourceBadge
                if !metaText.isEmpty {
                    chip(metaText)
                }
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            if let primaryLink {
                copyButton(url: primaryLink.url)
                saveButton(link: primaryLink)
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if !item.sizeLabel.isEmpty, item.sizeBytes > 0 {
            parts.append(item.sizeLabel)
        }
        if let date = item.publishedAt, !date.isEmpty {
            parts.append(date)
        }
        return parts.joined(separator: " · ")
    }

    private func copyButton(url: String) -> some View {
        Button {
            RexHaptics.tap()
            onCopy(url)
        } label: {
            Text("复制")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.brandBlue)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(RexColor.brandBlue.opacity(0.09), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .fixedSize()
        .accessibilityLabel("复制链接")
    }

    private func saveButton(link: (label: String, url: String, password: String)) -> some View {
        Button {
            RexHaptics.tap()
            onSave(link)
        } label: {
            Group {
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(RexColor.onBrand)
                } else {
                    Text("转存")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(RexColor.onBrand)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(RexColor.brandGradient, in: Capsule(style: .continuous))
            .shadow(color: RexColor.brandBlue.opacity(0.28), radius: 5, x: 0, y: 3)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isSaving)
        .fixedSize()
        .accessibilityLabel("转存 115")
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(RexColor.primaryText.opacity(0.62))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minHeight: 22)
            .background(Color(white: 0.5).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
