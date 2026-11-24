import SwiftUI

/// 缓存管理：统计网络响应、应用缓存与临时文件占用，支持一键清理。
/// 只清 Library/Caches 与 tmp，不动账号、收藏与网盘文件。
struct CacheManagementView: View {
    @State private var usage = CacheUsage.zero
    @State private var isLoading = true
    @State private var isClearing = false
    @State private var isConfirmingClear = false
    @State private var pendingCategory: CacheCategory?

    var body: some View {
        SettingsPage(title: "缓存管理", actions: actions) {
            usageCard

            SettingsSection(title: "缓存明细") {
                ForEach(Array(CacheCategory.allCases.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { SettingsDivider() }
                    detailRow(category)
                }
            }

            clearButton
        }
        .task {
            await refresh()
        }
        .alert("清理缓存？", isPresented: $isConfirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                Task { await clear() }
            }
        } message: {
            Text("将清空网络缓存、文件缓存与临时文件，不会影响账号、收藏和网盘文件。")
        }
        .alert(
            "清理\(pendingCategory?.title ?? "")？",
            isPresented: Binding(
                get: { pendingCategory != nil },
                set: { if !$0 { pendingCategory = nil } }
            ),
            presenting: pendingCategory
        ) { category in
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                Task { await clear(category) }
            }
        } message: { category in
            Text("只清空\(category.title)，其它缓存保留。")
        }
    }

    private var actions: [RexNavAction] {
        [
            RexNavAction(
                systemImage: "arrow.clockwise",
                label: "刷新",
                isEnabled: !isLoading && !isClearing,
                action: { Task { await refresh() } }
            )
        ]
    }

    // MARK: - 空间占用

    /// 顶部总览：总量 + 按分类着色的分段进度条 + 图例。
    private var usageCard: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: RexSpacing.sm) {
                Text("空间占用")
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.secondaryText)

                Spacer(minLength: RexSpacing.sm)

                Text(isLoading ? "—" : CacheStats.text(usage.total))
                    .font(RexFont.title3)
                    .foregroundStyle(RexColor.primaryText)
                    .monospacedDigit()
            }

            usageBar

            HStack(spacing: RexSpacing.sm) {
                ForEach(Array(CacheCategory.allCases.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { Spacer(minLength: 0) }
                    HStack(spacing: RexSpacing.xs) {
                        Circle()
                            .fill(category.tint)
                            .frame(width: 8, height: 8)

                        Text(category.title)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.panel)
        .animation(RexMotion.standard, value: usage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoading ? "空间占用统计中" : "空间占用 \(CacheStats.text(usage.total))")
    }

    private var usageBar: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let visible = CacheCategory.allCases.filter { $0.bytes(in: usage) > 0 }
            let gaps = spacing * CGFloat(max(0, visible.count - 1))
            let available = max(0, proxy.size.width - gaps)
            let total = max(usage.total, 1)

            HStack(spacing: spacing) {
                if visible.isEmpty {
                    Capsule().fill(RexColor.field)
                } else {
                    ForEach(visible) { category in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(category.tint)
                            .frame(width: available * CGFloat(category.bytes(in: usage)) / CGFloat(total))
                    }
                }
            }
        }
        .frame(height: 10)
    }

    // MARK: - 明细行

    private func detailRow(_ category: CacheCategory) -> some View {
        let bytes = category.bytes(in: usage)
        let isBusy = isLoading || isClearing || bytes == 0

        return HStack(spacing: RexSpacing.md) {
            Image(systemName: category.symbol)
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 22)

            Text(category.title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Text(isLoading ? "—" : CacheStats.text(bytes))
                .font(RexFont.rowValue)
                .foregroundStyle(RexColor.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .rexRowAction(isEnabled: !isBusy) {
            RexHaptics.tap()
            pendingCategory = category
        }
        .opacity(isBusy ? 0.45 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.title) \(CacheStats.text(bytes))")
        .accessibilityHint("轻点清理该分类缓存")
    }

    // MARK: - 清理

    private var clearButton: some View {
        Button {
            RexHaptics.warning()
            isConfirmingClear = true
        } label: {
            HStack(spacing: RexSpacing.sm) {
                if isClearing {
                    ProgressView()
                        .tint(RexColor.error)
                } else {
                    Image(systemName: "trash")
                        .font(.system(.subheadline, weight: .semibold))
                }

                Text(isClearing ? "清理中…" : "清理全部缓存")
                    .font(RexFont.button)
            }
            .foregroundStyle(RexColor.error)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .rexCard(cornerRadius: RexRadius.panel)
        .disabled(isClearing || isLoading || usage.total == 0)
        .opacity(isClearing || isLoading || usage.total == 0 ? 0.45 : 1)
        .accessibilityLabel("清理全部缓存")
        .padding(.top, RexSpacing.sm)
    }

    // MARK: - 数据

    private func refresh() async {
        isLoading = true
        usage = await CacheStats.scan()
        isLoading = false
    }

    private func clear() async {
        isClearing = true
        await CacheStats.clear()
        await refresh()
        isClearing = false
        RexHaptics.success()
    }

    /// 单条清理：只动这一分类，清完重新扫描刷新占比。
    private func clear(_ category: CacheCategory) async {
        isClearing = true
        await CacheStats.clear(category)
        await refresh()
        isClearing = false
        RexHaptics.success()
    }
}
