import SwiftUI
import UIKit

/// 一个搜索来源：入口页选中的服务。
struct SearchSource: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 结果页里的单条资源。`id` 在加载时生成一次，避免重复链接导致列表标识冲突。
private struct SearchResultRow: Identifiable {
    let id = UUID()
    let title: String
    let link: String
    let password: String
    let kind: String
    /// 链接里的文件哈希（磁力 btih / ed2k 文件哈希），用于翻页去重；没有哈希时为 nil。
    let identity: String?
    let meta: ResourceMeta

    init(_ item: SearchResult) {
        title = item.title
        link = item.link
        password = item.password
        kind = item.kind
        identity = LinkIdentity.of(item.link)
        meta = ResourceMeta(item)
    }
}

/// 从资源链接里取出文件哈希，规则与后端 `_link_identity` 保持一致：
/// 一条记录挂多条链接、或 115 / http 这类没有哈希的分享返回 nil，不参与去重。
private enum LinkIdentity {
    private static let tokenRegex = try? NSRegularExpression(
        pattern: "magnet:\\?\\S+|ed2k://\\S+|(?:https?|115)://\\S+",
        options: [.caseInsensitive]
    )
    private static let ed2kRegex = try? NSRegularExpression(
        pattern: "ed2k://\\|file\\|[^|]*\\|\\d+\\|([0-9A-Fa-f]{32})\\|"
    )

    static func of(_ link: String) -> String? {
        let cocoa = link as NSString
        guard let tokens = tokenRegex?
            .matches(in: link, range: NSRange(location: 0, length: cocoa.length))
            .map({ cocoa.substring(with: $0.range) }),
            tokens.count == 1,
            let token = tokens.first
        else { return nil }

        if let range = token.range(of: "urn:btih:", options: [.caseInsensitive]) {
            let raw = String(token[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
            guard !raw.isEmpty else { return nil }
            // btih 允许 32 位 base32，统一成 40 位十六进制才能和别的库对上。
            if raw.count == 32, let hex = decodeBase32(raw) { return hex }
            return raw.uppercased()
        }

        let tokenCocoa = token as NSString
        if let match = ed2kRegex?.firstMatch(
            in: token,
            range: NSRange(location: 0, length: tokenCocoa.length)
        ), match.numberOfRanges > 1 {
            return tokenCocoa.substring(with: match.range(at: 1)).uppercased()
        }
        return nil
    }

    private static func decodeBase32(_ value: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bytes: [UInt8] = []
        var buffer = 0
        var bitsLeft = 0
        for character in value.uppercased() {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                bytes.append(UInt8((buffer >> bitsLeft) & 0xFF))
            }
        }
        guard bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}

/// 某一来源的结果集合。
private struct SearchResultGroup: Identifiable {
    let id: String
    let name: String
    let error: String
    var hasMore: Bool
    var truncated: Bool
    var items: [SearchResultRow]
    /// 服务端已返回的条数（翻页 offset 用它，而不是去重后的条数，避免翻页错位）。
    var fetchedCount: Int

    init(_ group: SearchGroup) {
        id = group.id
        name = group.name
        error = group.error
        hasMore = group.hasMore
        truncated = group.truncated ?? false
        items = group.items.map { SearchResultRow($0) }
        fetchedCount = group.items.count
    }

    mutating func append(_ group: SearchGroup, excluding known: Set<String>) {
        hasMore = group.hasMore
        truncated = group.truncated ?? false
        fetchedCount += group.items.count
        // 翻页时按链接哈希去掉已展示过的资源：单服务翻页请求拿不到跨库去重信息，
        // 同一文件（尤其别的来源 Tab 里展示过的那条）可能在新一页再出现一次。
        var seen = known
        let incoming = group.items.map { SearchResultRow($0) }.filter { row in
            guard let identity = row.identity else { return true }
            return seen.insert(identity).inserted
        }
        items += incoming
    }
}

/// 搜索结果详情页：顶栏用来源 Tab 切换各服务的结果。
struct SearchResultsView: View {
    let keyword: String
    let sources: [SearchSource]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient
    @Environment(\.openURL) private var openURL

    @State private var groups: [SearchResultGroup] = []
    @State private var isLoading = true
    /// 首次加载完成后为 true：详情页返回时不再重复请求；中途被取消则允许重新加载。
    @State private var didLoadOnce = false
    @State private var errorMessage: String?
    @State private var loadingMoreID: String?
    @State private var selectedID: String
    @State private var isScrolled = false
    @State private var toast: String?
    /// 响应慢、正在后台续搜的来源；这些来源不显示超时错误，只显示「继续检索」。
    @State private var retryingIDs: Set<String> = []
    /// 整次请求超时且还没有任何结果时置位。
    @State private var isRetryingAll = false
    @State private var detailTarget: ResourceDetailTarget?
    @State private var savingIDs: Set<UUID> = []

    init(keyword: String, sources: [SearchSource]) {
        self.keyword = keyword
        self.sources = sources
        _selectedID = State(initialValue: sources.first?.id ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            sourceBar

            GeometryReader { proxy in
                ScrollView {
                    contentView
                        .frame(maxWidth: RexLayout.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                .rexScrollTracking("searchResultsScroll", isScrolled: $isScrolled)
                .overlay(alignment: .top) {
                    if let toast {
                        RexToastBanner(message: toast, symbol: "checkmark.circle.fill")
                            .padding(.horizontal, RexSpacing.xl)
                            .padding(.top, RexSpacing.sm)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(2)
                    }
                }
                .animation(RexMotion.quick, value: toast)
            }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $detailTarget) { target in
            ResourceDetailView(target: target)
        }
        .task {
            // 从详情页返回时视图会重新出现；已加载完成则不再发起搜索
            guard !didLoadOnce else { return }
            await load()
        }
    }

    // MARK: - 顶栏

    /// 二级页工具条：左侧返回、居中关键词，滚动后由统一顶栏组件切换为毛玻璃材质。
    private var topBar: some View {
        RexNavBar(
            title: keyword,
            leading: .back(action: { dismiss() }),
            isScrolled: isScrolled
        )
    }

    // MARK: - 来源切换

    /// 来源做成独立胶囊，横向可滚动；选中项实心蓝，其余描边白底。
    private var sourceBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                ForEach(sources) { source in
                    tab(for: source)
                }
            }
            .padding(.horizontal, RexSpacing.xl)
            .padding(.vertical, RexSpacing.sm)
        }
        .scrollIndicators(.hidden)
        .animation(RexMotion.spring, value: selectedID)
    }

    private func tab(for source: SearchSource) -> some View {
        let isSelected = source.id == selectedID
        let group = group(for: source.id)
        // 超时不算失败：还在续搜时不打警告标，避免误导。
        let hasError = !(group?.error.isEmpty ?? true)
            && !isTimeoutError(group?.error ?? "")
            && !retryingIDs.contains(source.id)

        return Button {
            guard selectedID != source.id else { return }
            RexHaptics.selection()
            withAnimation(RexMotion.spring) {
                selectedID = source.id
            }
        } label: {
            Text(source.name)
                .font(.system(.footnote, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(
                    isSelected
                        ? RexColor.onBrand
                        : (hasError ? RexColor.error : RexColor.primaryText)
                )
                .lineLimit(1)
                .padding(.horizontal, RexSpacing.md)
                .frame(height: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(RexColor.brandGradient) : AnyShapeStyle(RexColor.surface))
                    .shadow(
                        color: isSelected ? RexColor.brandBlue.opacity(0.22) : .clear,
                        radius: 8,
                        y: 3
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : RexColor.cardBorder,
                        lineWidth: 0.75
                    )
            }
            .contentShape(Capsule(style: .continuous))
            .frame(minHeight: RexLayout.minTouch)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(source.name)
        .accessibilityValue(group.map { "\($0.items.count) 条结果" } ?? "加载中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 内容

    @ViewBuilder
    private var contentView: some View {
        if isLoading {
            loadingView
        } else if let group = currentGroup {
            if isTimeoutError(group.error) {
                // 超时不弹错误：来源还在后台续搜，结果一到就直接替换这个页面。
                stateCard(
                    symbol: "magnifyingglass",
                    title: "正在继续检索…",
                    message: "「\(group.name)」响应较慢，结果出来后会直接显示",
                    tone: .brand,
                    isLoading: true
                )
            } else if !group.error.isEmpty {
                stateCard(
                    symbol: "exclamationmark.triangle",
                    title: "\(group.name) 搜索失败",
                    message: group.error,
                    tone: .warning
                )
            } else if group.items.isEmpty {
                stateCard(
                    symbol: "magnifyingglass",
                    title: "没有找到相关资源",
                    message: "换个关键词或切换其他来源试试",
                    tone: .neutral,
                    actionTitle: "返回修改关键词",
                    action: { dismiss() }
                )
            } else {
                resultList(group)
            }
        } else if isRetryingAll {
            stateCard(
                symbol: "magnifyingglass",
                title: "正在继续检索…",
                message: "服务响应较慢，仍在继续查找「\(keyword)」",
                tone: .brand,
                isLoading: true
            )
        } else {
            stateCard(
                symbol: errorMessage == nil ? "magnifyingglass" : "wifi.exclamationmark",
                title: errorMessage == nil ? "没有找到相关资源" : "搜索失败",
                message: errorMessage ?? "换个关键词或切换其他来源试试",
                tone: errorMessage == nil ? .neutral : .warning,
                actionTitle: errorMessage == nil ? "返回修改关键词" : "重试",
                action: {
                    if errorMessage == nil {
                        dismiss()
                    } else {
                        Task { await load() }
                    }
                }
            )
        }
    }

    /// 首次搜索用骨架屏占位，避免整页只剩一个转圈，也减少结果出现时的布局跳动。
    private var loadingView: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            HStack(spacing: RexSpacing.sm) {
                ProgressView()
                    .controlSize(.small)

                Text("正在 \(sources.count) 个来源中查找「\(keyword)」")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, RexSpacing.xs)

            ForEach(0..<3, id: \.self) { _ in
                RexSkeletonResultCard()
            }

            searchTipsCard
                .padding(.top, RexSpacing.xs)
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.huge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在搜索 \(keyword)")
    }

    /// 检索等待期的底部提示卡：利用骨架屏下方的留白解释搜索规则与操作方式。
    private var searchTipsCard: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RexColor.warning)

                Text("搜索小贴士")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)

                Spacer(minLength: 0)
            }

            tipRow("关键词加上年份、番号或画质，命中更精准")
            tipRow("点卡片可查看详情，复制与转存直接在卡片上完成")
            tipRow("磁力 / ed2k 需要下载工具，115 分享可直接转存网盘")
        }
        .padding(RexSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("搜索小贴士：关键词加上年份、番号或画质命中更精准；点卡片可查看详情；磁力与 ed2k 需要下载工具，115 分享可直接转存网盘")
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(RexColor.tertiaryText.opacity(0.55))
                .frame(width: 3, height: 3)
                .padding(.top, 6)

            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(RexColor.secondaryText)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stateCard(
        symbol: String,
        title: String,
        message: String,
        tone: RexStateCard.Tone,
        isLoading: Bool = false,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        RexStateCard(
            symbol: symbol,
            title: title,
            message: message,
            tone: tone,
            isLoading: isLoading,
            actionTitle: actionTitle,
            action: action
        )
        .padding(.horizontal, RexSpacing.xl)
        .padding(.vertical, RexSpacing.lg)
        .frame(maxWidth: .infinity)
    }

    private func resultList(_ group: SearchResultGroup) -> some View {
        LazyVStack(spacing: 10) {
            HStack(spacing: 5) {
                Text("搜索结果")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)

                Text("\(group.items.count) 条")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(RexColor.tertiaryText)

                Spacer(minLength: 0)
            }

            ForEach(group.items) { item in
                resultCard(item, sourceName: group.name)
            }

            if group.hasMore {
                loadMoreButton(group)
            } else if group.truncated {
                RexInlineNotice(
                    title: "结果可能不完整",
                    message: "「\(group.name)」每次最多检查固定数量的候选，关键词太宽泛时会提前停止，可能还有结果没被列出。加上年份、番号或画质再搜，命中会更准。",
                    tone: .warning,
                    actionTitle: "返回修改关键词",
                    action: { dismiss() }
                )
                .padding(.top, RexSpacing.xs)
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.xxxl)
    }

    // MARK: - 结果卡片
    private func resultCard(_ item: SearchResultRow, sourceName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(highlightedTitle(item.title))
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .lineSpacing(1.5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.link.isEmpty {
                Text(item.link)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 5) {
                kindChip(item)

                if !item.password.isEmpty {
                    passwordChip(item)
                }

                Spacer(minLength: 0)

                cardAction(
                    title: "复制",
                    systemImage: "doc.on.doc",
                    filled: false,
                    enabled: !item.link.isEmpty
                ) {
                    copy(item.link)
                }

                cardAction(
                    title: savingIDs.contains(item.id) ? "转存中" : "转存",
                    systemImage: "cloud.fill",
                    filled: false,
                    tinted: true,
                    enabled: !item.link.isEmpty && !savingIDs.contains(item.id)
                ) {
                    Task { await save(item) }
                }

                if let url = openableURL(item.link), !is115Share(item) {
                    cardAction(
                        title: "播放",
                        systemImage: "play.fill",
                        filled: true
                    ) {
                        openURL(url)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, RexSpacing.md)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.card)
        .contentShape(RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous))
        .onTapGesture {
            RexHaptics.tap()
            detailTarget = ResourceDetailTarget(
                title: item.title,
                link: item.link,
                password: item.password,
                kind: item.kind,
                sourceName: sourceName,
                meta: item.meta
            )
        }
        .accessibilityAddTraits(.isButton)
    }

    /// 链接类型标签：磁力 / ed2k / 115 分享，压缩成一行小胶囊。
    private func kindChip(_ item: SearchResultRow) -> some View {
        let tint = kindTint(item)
        let filled = isEd2k(item)

        return HStack(spacing: 4) {
            if is115Share(item) {
                Image("Brand115")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else if isMagnet(item) {
                Text("🧲")
                    .font(.system(size: 10))
            } else {
                Image(systemName: kindIcon(item))
                    .font(.system(size: 9.5, weight: .semibold))
            }

            Text(kindLabel(item))
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(filled ? RexColor.onBrand : tint)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(filled ? tint : tint.opacity(0.10), in: Capsule(style: .continuous))
        .accessibilityLabel(kindLabel(item))
    }

    private func passwordChip(_ item: SearchResultRow) -> some View {
        Button {
            copy(item.password, message: "提取码已复制")
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9, weight: .semibold))

                Text(item.password)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(RexColor.warning)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RexColor.warning.opacity(0.10), in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .frame(minHeight: RexLayout.minTouch)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("复制提取码 \(item.password)")
    }

    private func isMagnet(_ item: SearchResultRow) -> Bool {
        let kind = item.kind.lowercased()
        return kind.contains("磁力")
            || kind.contains("magnet")
            || item.link.lowercased().hasPrefix("magnet:")
    }

    /// 卡片整体可点进详情，这里用高优先级手势保证按钮点击不会同时触发跳转。
    private func cardAction(
        title: String,
        systemImage: String,
        filled: Bool,
        tinted: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let shape = Capsule(style: .continuous)
        let foreground: Color = filled
            ? RexColor.onBrand
            : (tinted ? RexColor.brandBlue : RexColor.secondaryText)

        return HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))

            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
        .background(
            shape.fill(
                filled
                    ? RexColor.brandBlue
                    : (tinted ? RexColor.brandBlue.opacity(0.09) : RexColor.field)
            )
        )
        .overlay(
            shape.strokeBorder(
                tinted ? RexColor.brandBlue.opacity(0.22) : RexColor.cardBorder,
                lineWidth: filled ? 0 : 0.75
            )
        )
        .contentShape(shape)
        .frame(minHeight: RexLayout.minTouch)
        .opacity(enabled ? 1 : 0.45)
        .highPriorityGesture(
            TapGesture().onEnded {
                guard enabled else { return }
                action()
            }
        )
        .accessibilityAddTraits(.isButton)
    }

    private func kindLabel(_ item: SearchResultRow) -> String {
        if is115Share(item) { return "115 分享" }
        if isMagnet(item) { return "磁力" }
        if isEd2k(item) { return "ed2k" }
        if openableURL(item.link) != nil { return "直链" }
        return item.kind.isEmpty ? "资源链接" : item.kind
    }

    private func kindIcon(_ item: SearchResultRow) -> String {
        if is115Share(item) { return "cloud.fill" }
        if isMagnet(item) {
            return UIImage(systemName: "magnet") == nil ? "link" : "magnet"
        }
        if isEd2k(item) { return "link" }
        if openableURL(item.link) != nil { return "play.rectangle.fill" }
        return "shippingbox.fill"
    }

    private func kindTint(_ item: SearchResultRow) -> Color {
        if is115Share(item) { return Color(hex: 0x0EA5E9) }
        if isEd2k(item) { return Color(hex: 0x2563EB) }
        if isMagnet(item) { return RexColor.brandBlue }
        if openableURL(item.link) != nil { return Color(hex: 0x10B981) }
        return RexColor.secondaryText
    }

    private func isEd2k(_ item: SearchResultRow) -> Bool {
        item.kind.lowercased().contains("ed2k")
            || item.link.lowercased().hasPrefix("ed2k://")
    }

    private func is115Share(_ item: SearchResultRow) -> Bool {
        item.kind.lowercased().contains("115")
            || item.link.contains("115.com/s/")
            || item.link.contains("115cdn.com/s/")
    }

    private func openableURL(_ link: String) -> URL? {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// 标题里命中关键词的部分加浅红底色，扫读时更快定位。
    private func highlightedTitle(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text[searchStart..<text.endIndex].range(of: needle, options: .caseInsensitive) {
            text[range].backgroundColor = RexColor.brandBlue.opacity(0.16)
            searchStart = range.upperBound
        }
        return text
    }

    private func loadMoreButton(_ group: SearchResultGroup) -> some View {
        Button {
            RexHaptics.tap()
            Task { await loadMore(group.id) }
        } label: {
            HStack(spacing: RexSpacing.sm) {
                if loadingMoreID == group.id {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(loadingMoreID == group.id ? "正在加载…" : "加载更多")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    .fill(RexColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(loadingMoreID != nil)
    }

    // MARK: - 状态派生

    private var currentGroup: SearchResultGroup? {
        group(for: selectedID)
    }

    private func group(for id: String) -> SearchResultGroup? {
        groups.first { $0.id == id }
    }

    // MARK: - 数据

    private func load() async {
        guard let client = apiClient else {
            isLoading = false
            errorMessage = "服务未连接，请稍后重试"
            didLoadOnce = true
            return
        }

        isLoading = true
        errorMessage = nil
        isRetryingAll = false
        retryingIDs = []

        var pending = Set(sources.map(\.id))
        var round = 0

        // 只要还停留在本页就持续续搜；离开页面或换关键词时 .task 取消，循环随之结束。
        while !Task.isCancelled {
            do {
                let response = try await client.searchResources(
                    keyword: keyword,
                    serviceIDs: pending
                )
                merge(response.groups)
                isRetryingAll = false
            } catch {
                if isCancelled(error) {
                    return
                }
                if isTimeout(error) {
                    // 整次请求超时不提示，直接进入下一轮静默续搜。
                    isRetryingAll = groups.isEmpty
                } else {
                    isLoading = false
                    didLoadOnce = true
                    if groups.isEmpty {
                        errorMessage = message(for: error)
                    } else {
                        showToast(message(for: error))
                    }
                    return
                }
            }

            isLoading = false

            let timedOut = groups.filter { isTimeoutError($0.error) }.map(\.id)
            retryingIDs = Set(timedOut)
            guard !timedOut.isEmpty || isRetryingAll else { break }

            pending = timedOut.isEmpty ? Set(sources.map(\.id)) : Set(timedOut)
            round += 1
            do {
                try await Task.sleep(for: .seconds(min(2 * Double(round), 12)))
            } catch {
                return
            }
        }

        isLoading = false
        didLoadOnce = true
        retryingIDs = []
        isRetryingAll = false
    }

    /// 把某一轮返回的来源结果合并进来；续搜只请求慢的来源，不能覆盖已拿到的其它结果。
    private func merge(_ incoming: [SearchGroup]) {
        for group in incoming {
            let item = SearchResultGroup(group)
            if let index = groups.firstIndex(where: { $0.id == item.id }) {
                groups[index] = item
            } else {
                groups.append(item)
            }
        }

        if group(for: selectedID) == nil {
            selectedID = groups.first?.id ?? selectedID
        }
    }

    private func isTimeoutError(_ text: String) -> Bool {
        text.contains("超时")
    }

    private func isTimeout(_ error: Error) -> Bool {
        (error as? APIError) == .timeout
    }

    private func isCancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? APIError) == .cancelled
    }

    private func loadMore(_ id: String) async {
        guard loadingMoreID == nil,
              let client = apiClient,
              let index = groups.firstIndex(where: { $0.id == id }),
              groups[index].hasMore else { return }

        loadingMoreID = id
        defer { loadingMoreID = nil }

        // 翻页超时同样静默续搜，用户还留在本页就继续补这一页。
        while !Task.isCancelled {
            do {
                let response = try await client.searchResources(
                    keyword: keyword,
                    serviceIDs: [id],
                    offset: groups[index].fetchedCount
                )
                guard let updated = response.groups.first(where: { $0.id == id }) else { return }
                guard let currentIndex = groups.firstIndex(where: { $0.id == id }) else { return }
                // 已见哈希取全部 Tab，跨来源的同一文件不会在新一页重复出现。
                let known = Set(groups.flatMap { $0.items.compactMap(\.identity) })
                groups[currentIndex].append(updated, excluding: known)
                return
            } catch {
                if isCancelled(error) {
                    return
                }
                if isTimeout(error) {
                    do {
                        try await Task.sleep(for: .seconds(3))
                    } catch {
                        return
                    }
                    continue
                }
                showToast("加载更多失败，请稍后重试")
                return
            }
        }
    }

    private func copy(_ link: String, message: String = "链接已复制") {
        guard !link.isEmpty else { return }
        UIPasteboard.general.string = link
        RexHaptics.success()
        showToast(message)
    }

    /// 转存到 115：分享链接接收分享，磁力 / ed2k / 直链添加云下载。
    private func save(_ item: SearchResultRow) async {
        guard let apiClient else {
            showToast("服务未连接")
            return
        }
        guard !savingIDs.contains(item.id) else { return }
        savingIDs.insert(item.id)
        defer { savingIDs.remove(item.id) }

        do {
            let result = try await apiClient.panSave(
                urls: [item.link],
                password: item.password
            )
            if let error = result.errors.first, result.count == 0 {
                RexHaptics.warning()
                showToast(error)
            } else {
                RexHaptics.success()
                showToast("已转存 \(result.count) 项到 115")
            }
        } catch {
            RexHaptics.warning()
            showToast(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            if case .conflict(let detail) = apiError, let detail, !detail.isEmpty {
                return detail
            }
            return apiError.errorDescription ?? "搜索失败，请稍后重试"
        }
        return error.localizedDescription
    }

    private func showToast(_ text: String) {
        withAnimation(RexMotion.quick) {
            toast = text
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            guard toast == text else { return }
            withAnimation(RexMotion.quick) {
                toast = nil
            }
        }
    }
}

#Preview {
    NavigationStack {
        SearchResultsView(
            keyword: "沙丘",
            sources: [
                SearchSource(id: "tmdb", name: "TMDB"),
                SearchSource(id: "douban", name: "豆瓣")
            ]
        )
    }
}
