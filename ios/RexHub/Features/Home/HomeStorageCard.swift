import SwiftUI

// MARK: - 卡片头

/// 卡片头：中性灰底小图标 + 粗标题 + 右侧说明。
/// 参考稿的卡头图标是灰底，彩色只留给卡内数据（进度环），避免一屏多个彩色块互相抢。
private struct HomeCardHeader: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(RexColor.field)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RexColor.secondaryText)
                }

            Text(title)
                .font(RexFont.headline)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            if let detail {
                Text(detail)
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 存储空间

/// 存储卡的展示状态：由页面从 `HomeStatusModel` 映射，卡片不再自己猜「未绑定」。
///
/// 早前卡片只有 `account` + `loaded` 两个输入：只要接口失败就落到「未绑定 115 网盘」，
/// 把网络错误说成了用户没绑定。拆成显式状态后，失败能给出重试，绑定但没容量也能单独表达。
enum HomeStorageStatus: Equatable {
    /// 正在读取，还没有任何可用数据。
    case loading
    /// 读取失败（网络或服务端），可重试。
    case failed
    /// 115 尚未绑定。
    case unbound
    /// 已绑定但容量信息还没取到。
    case unavailable
    /// 已绑定且有容量数据，单位是字节。
    case ready(total: Int64, used: Int64)
}

/// 参考稿「资源监控」的等价卡：115 容量环 + 右侧三项明细 + 底部三个浅灰小格。
///
/// 两处布局都按字号自适应：常规字号左右排布，无障碍字号（AX1 起）改成上下排布，
/// 否则 100pt 的容量环会把三项数字挤成一列几个字。
struct HomeStorageCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let storage: HomeStorageStatus
    let accountName: String
    let isVIP: Bool
    let onOpenLibrary: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            HomeCardHeader(symbol: "internaldrive", title: "存储空间", detail: "115 网盘")

            content

            statTiles
        }
        .padding(RexSpacing.lg)
        .rexCard(cornerRadius: RexRadius.largeCard)
    }

    @ViewBuilder
    private var content: some View {
        switch storage {
        case let .ready(total, used):
            ring(used: used, total: total)
        case .loading:
            placeholder
        case .failed:
            issueRow("存储信息读取失败", actionTitle: "重试", action: onRetry)
        case .unbound:
            issueRow("未绑定 115 网盘", actionTitle: "去绑定", action: onOpenLibrary)
        case .unavailable:
            issueRow("已绑定 115，容量信息暂时不可用", actionTitle: "重试", action: onRetry)
        }
    }

    @ViewBuilder
    private func ring(used: Int64, total: Int64) -> some View {
        let progress = min(max(Double(used) / Double(total), 0), 1)

        if dynamicTypeSize.isAccessibilitySize {
            // 无障碍字号下左右两栏会把三项数字压成一列几个字，改为上下排布。
            VStack(alignment: .leading, spacing: RexSpacing.lg) {
                ringHead(progress)
                stats(used: used, total: total)
            }
        } else {
            HStack(spacing: RexSpacing.lg) {
                ringHead(progress)
                stats(used: used, total: total)
            }
        }
    }

    private func ringHead(_ progress: Double) -> some View {
        VStack(spacing: 6) {
            HomeRing(progress: progress)
            Text("已用空间")
                .font(RexFont.caption2)
                .foregroundStyle(RexColor.tertiaryText)
        }
    }

    private func stats(used: Int64, total: Int64) -> some View {
        VStack(spacing: 11) {
            stat("已用", sizeText(used))
            stat("总量", sizeText(total))
            stat("剩余", sizeText(max(total - used, 0)))
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: RexSpacing.sm) {
            Text(title)
                .font(RexFont.caption2)
                .foregroundStyle(RexColor.tertiaryText)

            Spacer(minLength: RexSpacing.sm)

            Text(value)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .monospacedDigit()
        }
        // 「已用」和数值本来是两个元素，VoiceOver 会分两站读完；合成一句更像人话。
        .accessibilityElement(children: .combine)
    }

    /// 卡片内的一行状态 + 动作：失败给「重试」，未绑定给「去绑定」。
    private func issueRow(_ text: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: RexSpacing.sm) {
                Text(text)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text(actionTitle)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.brandBlue)
                Image(systemName: "chevron.right")
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .frame(minHeight: RexLayout.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(text)，\(actionTitle)")
    }

    private var placeholder: some View {
        HStack(spacing: RexSpacing.xl) {
            HomeRing(progress: 0)

            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                RexSkeleton(width: 96, height: 12)
                RexSkeleton(width: 72, height: 12)
                RexSkeleton(width: 84, height: 12)
            }

            Spacer(minLength: 0)
        }
        .accessibilityLabel("正在读取存储空间")
    }

    private struct StatTile: Identifiable {
        let title: String
        let value: String

        var id: String { title }
    }

    private var tiles: [StatTile] {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            StatTile(title: "账号", value: name.isEmpty ? "—" : name),
            StatTile(title: "会员", value: isVIP ? "VIP" : "普通"),
            StatTile(title: "状态", value: statusText),
        ]
    }

    private var statusText: String {
        switch storage {
        case .ready, .unavailable: "已绑定"
        case .unbound: "未绑定"
        case .failed: "读取失败"
        case .loading: "读取中"
        }
    }

    @ViewBuilder
    private var statTiles: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // 无障碍字号下三格横排每格只剩几十 pt，数字与单位会被压到最小字号。
            VStack(spacing: RexSpacing.sm) {
                ForEach(tiles) { tileView($0) }
            }
        } else {
            HStack(spacing: RexSpacing.sm) {
                ForEach(tiles) { tileView($0) }
            }
        }
    }

    /// 卡内浅灰小格：参考稿用「白卡里的浅灰格」再分一层，比再画一张卡片更轻。
    private func tileView(_ tile: StatTile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tile.title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)

            Text(tile.value)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RexSpacing.md)
        .padding(.vertical, 10)
        .background(
            RexColor.field,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 资源监控

/// 参考稿「资源监控」卡：CPU / 内存 / GPU 三个进度环 + 网络 / 硬盘 / 温度三小格。
///
/// 服务端暂未提供资源监控接口，这里只按参考稿把框架与排版铺满，
/// 环内百分比与小格读数统一用 0% / -- 占位，接入接口后替换 `metrics` 与 `tiles` 即可。
struct HomeResourceMonitorCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Metric: Identifiable {
        let title: String
        let value: String
        let progress: Double

        var id: String { title }
    }

    private let metrics = [
        Metric(title: "CPU", value: "0%", progress: 0),
        Metric(title: "内存", value: "0%", progress: 0),
        Metric(title: "GPU", value: "0%", progress: 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            HomeCardHeader(symbol: "waveform.path.ecg", title: "资源监控", detail: nil)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: RexSpacing.lg) {
                    ForEach(metrics) { metricCard($0) }
                }
            } else {
                HStack(spacing: RexSpacing.md) {
                    ForEach(metrics) { metricCard($0) }
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: RexSpacing.sm) { tiles }
            } else {
                HStack(spacing: RexSpacing.sm) { tiles }
            }
        }
        .padding(RexSpacing.lg)
        .rexCard(cornerRadius: RexRadius.largeCard)
    }

    private func metricCard(_ metric: Metric) -> some View {
        VStack(spacing: RexSpacing.sm) {
            HomeRing(
                progress: metric.progress,
                centerText: metric.value,
                size: 88,
                lineWidth: 10
            )

            Text(metric.title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) \(metric.value)")
    }

    @ViewBuilder
    private var tiles: some View {
        monitorTile(title: "网络", rows: [("↑", "-- KB/s"), ("↓", "-- KB/s")])
        monitorTile(title: "硬盘", rows: [("读", "-- /s"), ("写", "-- /s")])
        monitorTile(title: "温度", rows: [("CPU", "--°C"), ("GPU", "--°C")])
    }

    private func monitorTile(title: String, rows: [(label: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)

            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: RexSpacing.xs) {
                    Text(rows[index].label)
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.tertiaryText)

                    Text(rows[index].value)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(RexColor.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RexSpacing.md)
        .padding(.vertical, 10)
        .background(
            RexColor.field,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 进度环

/// 进度环：底轨 + 品牌色进度 + 中心读数。
private struct HomeRing: View {
    let progress: Double
    var centerText: String?
    var size: CGFloat = 100
    var lineWidth: CGFloat = 11

    private var clamped: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(RexColor.field, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    RexColor.brandBlue,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(RexMotion.standard, value: clamped)

            Text(centerText ?? "\(Int((clamped * 100).rounded()))%")
                .font(
                    size >= 100
                        ? .system(.title2, design: .rounded, weight: .bold)
                        : .system(.title3, design: .rounded, weight: .bold)
                )
                .foregroundStyle(RexColor.primaryText)
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}
