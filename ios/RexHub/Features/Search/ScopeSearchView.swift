import SwiftUI
import UIKit

/// 范围搜索结果：影视 / 片商两类多源聚合，支持来源、排序、时间与大小筛选。
struct ScopeSearchView: View {
    let keyword: String
    let scope: SearchScope

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var items: [ScopeItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var sourceErrors: [String: String] = [:]
    @State private var options = ScopeSearchOptions()
    @State private var isScrolled = false
    @State private var alert: RexAlertInfo?
    @State private var savingID: String?

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "\(scope.title)搜索",
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            filterBar

            ScrollView {
                VStack(spacing: RexSpacing.lg) {
                    if isLoading, items.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in
                            RexSkeleton(width: .infinity, height: 92, cornerRadius: RexRadius.card)
                        }
                    } else if let errorText, items.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
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
                            title: "没有找到资源",
                            message: "换个关键词，或放宽时间与大小筛选。",
                            tone: .neutral
                        )
                    } else {
                        if !sourceErrors.isEmpty {
                            RexInlineNotice(
                                title: "部分来源不可用",
                                message: sourceErrors
                                    .map { "\(label(for: $0.key))：\($0.value)" }
                                    .joined(separator: "\n"),
                                tone: .warning
                            )
                        }

                        ForEach(items) { item in
                            ScopeResultCard(
                                item: item,
                                isSaving: savingID == item.id,
                                onCopy: { copy($0) },
                                onSave: { link in Task { await save(link) } },
                                onOpen: { url in open(url) }
                            )
                        }

                        if hasMore {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                Text(isLoading ? "加载中…" : "加载更多")
                                    .font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(RexColor.brandBlue)
                                    .frame(minWidth: 120, minHeight: 44)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .disabled(isLoading)
                            .onAppear {
                                guard !isLoading, hasMore else { return }
                                Task { await load(reset: false) }
                            }
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "scopeSearchScroll"))
            }
            .rexScrollTracking("scopeSearchScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load(reset: true) }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load(reset: true) }
        .rexAlert($alert)
    }

    // MARK: - 筛选

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                sourceChip(id: "all", label: "全部")

                ForEach(scope.sources, id: \.id) { item in
                    sourceChip(id: item.id, label: item.label)
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)

                optionMenu(
                    title: label(in: ScopeSearchOptions.sortOptions, value: options.sort, fallback: "相关度"),
                    options: ScopeSearchOptions.sortOptions
                ) { value in
                    options.sort = value
                    Task { await load(reset: true) }
                }

                optionMenu(
                    title: label(in: ScopeSearchOptions.timeOptions, value: options.filterTime, fallback: "不限时间"),
                    options: ScopeSearchOptions.timeOptions
                ) { value in
                    options.filterTime = value
                    Task { await load(reset: true) }
                }

                optionMenu(
                    title: label(in: ScopeSearchOptions.sizeOptions, value: options.filterSize, fallback: "不限大小"),
                    options: ScopeSearchOptions.sizeOptions
                ) { value in
                    options.filterSize = value
                    Task { await load(reset: true) }
                }
            }
            .padding(.horizontal, RexSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, RexSpacing.sm)
    }

    private func sourceChip(id: String, label: String) -> some View {
        let selected = options.source == id

        return Button {
            guard !selected else { return }
            RexHaptics.selection()
            options.source = id
            Task { await load(reset: true) }
        } label: {
            Text(label)
                .font(.system(.footnote, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? RexColor.onBrand : RexColor.secondaryText)
                .padding(.horizontal, RexSpacing.md)
                .frame(height: 30)
                .background(
                    selected ? AnyShapeStyle(RexColor.brandGradient) : AnyShapeStyle(RexColor.surface),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    if !selected {
                        Capsule(style: .continuous)
                            .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func optionMenu(
        title: String,
        options: [(id: String, label: String)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button(option.label) { onSelect(option.id) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, RexSpacing.md)
            .frame(height: 30)
            .background(RexColor.surface, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
        }
    }

    // MARK: - 数据

    private func load(reset: Bool) async {
        guard let apiClient, !isLoading else { return }
        if reset {
            page = 1
            hasMore = true
            errorText = nil
            sourceErrors = [:]
        } else {
            guard hasMore else { return }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.searchScope(
                scope: scope,
                keyword: keyword,
                page: page,
                options: options
            )

            var seen = Set(items.map(\.id))
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

    private func open(_ url: String) {
        guard let value = URL(string: url),
              let scheme = value.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            copy(url)
            return
        }
        openURL(value)
    }

    private func showToast(_ text: String, isError: Bool = false) {
        alert = isError ? .failure(text) : .success(text)
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

// MARK: - 结果卡片

private struct ScopeResultCard: View {
    let item: ScopeItem
    let isSaving: Bool
    var onCopy: (String) -> Void
    var onSave: ((label: String, url: String, password: String)) -> Void
    var onOpen: (String) -> Void

    private var primaryLink: (label: String, url: String, password: String)? {
        item.actionableLinks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(alignment: .top, spacing: RexSpacing.md) {
                if let thumb = item.thumbUrl, let url = URL(string: thumb) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(RexColor.field)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: RexSpacing.sm) {
                        badge(item.sourceLabel, tint: RexColor.brandBlue)

                        if !item.sizeLabel.isEmpty, item.sizeBytes > 0 {
                            Text(item.sizeLabel)
                                .font(RexFont.caption2)
                                .foregroundStyle(RexColor.secondaryText)
                        }

                        if let date = item.publishedAt, !date.isEmpty {
                            Text(date)
                                .font(RexFont.caption2)
                                .foregroundStyle(RexColor.tertiaryText)
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            if !item.actionableLinks.isEmpty {
                HStack(spacing: RexSpacing.sm) {
                    if let primary = primaryLink {
                        Button {
                            RexHaptics.tap()
                            onSave(primary)
                        } label: {
                            HStack(spacing: 4) {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.down.to.line")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                Text("115 转存")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(RexColor.onBrand)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(height: 30)
                            .background(
                                RexColor.brandGradient,
                                in: Capsule(style: .continuous)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isSaving)

                        Button {
                            onCopy(primary.url)
                        } label: {
                            Text("复制")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RexColor.primaryText)
                                .padding(.horizontal, RexSpacing.md)
                                .frame(height: 30)
                                .background(RexColor.field, in: Capsule(style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    if item.actionableLinks.contains(where: { $0.url.hasPrefix("http") }) {
                        Button {
                            if let httpLink = item.actionableLinks.first(where: { $0.url.hasPrefix("http") }) {
                                onOpen(httpLink.url)
                            }
                        } label: {
                            Text("打开")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RexColor.secondaryText)
                                .padding(.horizontal, RexSpacing.md)
                                .frame(height: 30)
                                .background(RexColor.field, in: Capsule(style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(tint.opacity(0.12), in: Capsule(style: .continuous))
    }
}
