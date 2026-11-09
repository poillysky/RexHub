import SwiftUI

/// 缓存管理：统计网络响应、应用缓存与临时文件占用，支持一键清理。
/// 只清 Library/Caches 与 tmp，不动账号、收藏与网盘文件。
struct CacheManagementView: View {
    @State private var usage = CacheUsage.zero
    @State private var isLoading = true
    @State private var isClearing = false
    @State private var isConfirmingClear = false

    var body: some View {
        SettingsPage(title: "缓存管理", actions: actions) {
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

    // MARK: - 明细行

    private func detailRow(_ category: CacheCategory) -> some View {
        let bytes = category.bytes(in: usage)
        let percent = CacheStats.percent(usage.ratio(bytes))

        return HStack(spacing: RexSpacing.md) {
            Circle()
                .fill(category.tint)
                .frame(width: 9, height: 9)

            Image(systemName: category.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)

                Text(category.subtitle)
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
            }

            Spacer(minLength: RexSpacing.sm)

            VStack(alignment: .trailing, spacing: 2) {
                Text(isLoading ? "—" : CacheStats.text(bytes))
                    .font(RexFont.rowValue)
                    .foregroundStyle(RexColor.primaryText)
                    .monospacedDigit()

                Text(isLoading ? "" : percent)
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.title) \(CacheStats.text(bytes))，占比 \(percent)")
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
                        .font(.system(size: 15, weight: .semibold))
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
}
