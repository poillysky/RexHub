import SwiftUI

/// 影视影人页：资料 + 按年份归档的作品墙，对齐 PWA 的 `MediaPersonBody`。
struct MpPersonView: View {
    let person: MpPersonRef

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var detail: MpPerson?
    @State private var items: [MpItem] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorText: String?
    @State private var moreError: String?
    @State private var bioExpanded = false
    @State private var isScrolled = false

    private var displayName: String {
        detail?.name ?? person.name
    }

    private var displayAvatar: String? {
        detail?.avatarUrl ?? person.avatarUrl
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: displayName,
                leading: .back(action: { dismiss() }),
                isScrolled: isScrolled
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    hero

                    if !facts.isEmpty {
                        factsCard
                    }

                    if let bio, !bio.isEmpty {
                        bioSection(bio)
                    }

                    if isLoading {
                        workSkeletons
                    } else if let errorText, items.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "作品加载失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await loadFirst() }
                        }
                    } else if items.isEmpty {
                        RexStateCard(
                            symbol: "film",
                            title: "暂无作品",
                            message: "这位影人暂时没有收录作品。",
                            tone: .neutral
                        )
                    } else {
                        ForEach(yearGroups) { group in
                            yearSection(group)
                        }

                        if let moreError {
                            RexNote(text: moreError)
                        }

                        if hasMore {
                            moreButton
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "mpPersonScroll"))
            }
            .rexScrollTracking("mpPersonScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await loadFirst() }
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .task {
            // 从影片详情返回时保留已加载的作品与滚动位置。
            if items.isEmpty { await loadFirst() }
        }
    }

    // MARK: - 头部

    private var hero: some View {
        HStack(alignment: .top, spacing: RexSpacing.lg) {
            MpArtwork(url: displayAvatar, fallbackSymbol: "person.fill")
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                }

            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                Text(displayName)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)

                if let original = detail?.originalName, !original.isEmpty, original != displayName {
                    Text(original)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(2)
                }

                HStack(spacing: RexSpacing.sm) {
                    if let department = detail?.department, !department.isEmpty {
                        MakerBadge(text: department, tint: RexColor.brandBlue)
                    }

                    if isLoading {
                        MakerBadge(text: "加载中", tint: RexColor.secondaryText)
                    } else if items.isEmpty {
                        MakerBadge(text: "暂无作品", tint: RexColor.secondaryText)
                    } else {
                        MakerBadge(
                            text: "\(items.count)\(hasMore ? "+" : "") 部",
                            tint: RexColor.brandBlue
                        )
                        if !yearSpan.isEmpty {
                            MakerBadge(text: yearSpan, tint: RexColor.secondaryText)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var facts: [(String, String)] {
        guard let detail else { return [] }
        let aka = (detail.aliases).filter { !$0.isEmpty && $0 != displayName }
        let original = detail.originalName.flatMap { $0 != displayName ? $0 : nil }
        let aliases = original.map { [$0] + aka } ?? aka
        let birthday = [detail.birthday, detail.deathday.map { "– \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")

        return [
            ("出生日期", birthday),
            ("出生地", detail.placeOfBirth ?? ""),
            ("性别", detail.gender ?? ""),
            ("别名", aliases.prefix(5).joined(separator: " / "))
        ].filter { !$0.1.isEmpty }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            ForEach(facts, id: \.0) { item in
                HStack(alignment: .top, spacing: RexSpacing.md) {
                    Text(item.0)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                        .frame(width: 56, alignment: .leading)

                    Text(item.1)
                        .font(RexFont.footnote)
                        .foregroundStyle(RexColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }

    private var bio: String? {
        detail?.biography?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bioSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text("简介")
                .font(RexFont.section)
                .foregroundStyle(RexColor.secondaryText)

            Text(text)
                .font(RexFont.body)
                .foregroundStyle(RexColor.secondaryText)
                .lineSpacing(3)
                .lineLimit(bioExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            if text.count > 160 {
                Button(bioExpanded ? "收起" : "展开") {
                    withAnimation(RexMotion.standard) { bioExpanded.toggle() }
                }
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(RexColor.brandBlue)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 作品

    private struct YearGroup: Identifiable {
        let year: String
        let items: [MpItem]
        var id: String { year }
    }

    private var yearGroups: [YearGroup] {
        let sorted = items.sorted { lhs, rhs in
            let left = Int(lhs.year ?? "") ?? -1
            let right = Int(rhs.year ?? "") ?? -1
            if left != right { return left > right }
            return (lhs.rating ?? 0) > (rhs.rating ?? 0)
        }

        var buckets: [String: [MpItem]] = [:]
        var order: [String] = []
        for item in sorted {
            let year = validYear(item.year) ?? "未知年份"
            if buckets[year] == nil { order.append(year) }
            buckets[year, default: []].append(item)
        }
        return order.map { YearGroup(year: $0, items: buckets[$0] ?? []) }
    }

    private var yearSpan: String {
        let years = items.compactMap { validYear($0.year) }.compactMap { Int($0) }
        guard let maxYear = years.max(), let minYear = years.min() else { return "" }
        return maxYear == minYear ? "\(maxYear)" : "\(minYear)–\(maxYear)"
    }

    private func validYear(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard text.count == 4, text.allSatisfy(\.isNumber) else { return nil }
        return text
    }

    private func yearSection(_ group: YearGroup) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: RexSpacing.sm) {
                Text(group.year)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Text("\(group.items.count) 部")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.tertiaryText)

                Spacer(minLength: 0)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md), count: 3),
                spacing: RexSpacing.lg
            ) {
                ForEach(group.items) { item in
                    NavigationLink(value: MpRoute.detail(item)) {
                        MpPosterCard(item: item)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    private var workSkeletons: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md), count: 3),
            spacing: RexSpacing.lg
        ) {
            ForEach(0..<6, id: \.self) { _ in
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        RexSkeleton(cornerRadius: RexRadius.control)
                    }
            }
        }
    }

    private var moreButton: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack(spacing: RexSpacing.sm) {
                if isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isLoadingMore ? "加载中" : "加载更多作品")
                    .font(.system(.subheadline, weight: .medium))
            }
            .foregroundStyle(RexColor.brandBlue)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isLoadingMore)
    }

    // MARK: - 数据

    private func loadFirst() async {
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        moreError = nil
        defer { isLoading = false }

        do {
            async let personTask = apiClient.mpPerson(source: person.source, id: person.id)
            async let worksTask = apiClient.mpPersonWorks(
                source: person.source,
                id: person.id,
                page: 1
            )
            detail = try? await personTask

            let works = try await worksTask
            var seen = Set<String>()
            items = works.items.filter { seen.insert($0.uniqueID).inserted }
            hasMore = works.hasMore
            page = 1
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let apiClient, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let works = try await apiClient.mpPersonWorks(
                source: person.source,
                id: person.id,
                page: page + 1
            )
            var seen = Set(items.map(\.uniqueID))
            items.append(contentsOf: works.items.filter { seen.insert($0.uniqueID).inserted })
            hasMore = works.hasMore
            page += 1
            moreError = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            moreError = error.localizedDescription
        }
    }
}
