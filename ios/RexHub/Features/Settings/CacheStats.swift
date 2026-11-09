import Foundation
import SwiftUI

// MARK: - 缓存统计

/// App 缓存占用：网络响应、文件缓存与临时文件。
struct CacheUsage: Equatable, Sendable {
    var network: Int64 = 0
    var extra: Int64 = 0
    var temp: Int64 = 0

    var total: Int64 { network + extra + temp }

    static let zero = CacheUsage()

    /// 各分类占比（分母为缓存总量）；总量为 0 时返回 0。
    func ratio(_ value: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total)
    }
}

@MainActor
enum CacheStats {
    /// 扫描缓存占用。目录遍历放到后台线程，避免主线程卡顿。
    static func scan() async -> CacheUsage {
        let urlCache = URLCache.shared
        let network = Int64(urlCache.currentDiskUsage) + Int64(urlCache.currentMemoryUsage)
        let diskCache = Int64(urlCache.currentDiskUsage)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let temp = FileManager.default.temporaryDirectory

        return await Task.detached(priority: .utility) {
            let cachesBytes = caches.map { directorySize($0) } ?? 0
            return CacheUsage(
                network: network,
                extra: max(0, cachesBytes - diskCache),
                temp: directorySize(temp)
            )
        }.value
    }

    /// 清空网络缓存、Caches 与 tmp；不动账号、收藏与网盘文件。
    static func clear() async {
        URLCache.shared.removeAllCachedResponses()

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let temp = FileManager.default.temporaryDirectory

        await Task.detached(priority: .userInitiated) {
            if let caches {
                removeContents(of: caches)
            }
            removeContents(of: temp)
        }.value
    }

    static func text(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func percent(_ ratio: Double) -> String {
        guard ratio > 0 else { return "0%" }
        if ratio < 0.01 { return "<1%" }
        return String(format: "%.0f%%", ratio * 100)
    }

    // MARK: 私有

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }

            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated private static func removeContents(of directory: URL) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for item in items {
            try? manager.removeItem(at: item)
        }
    }
}

// MARK: - 缓存分类

enum CacheCategory: String, CaseIterable, Identifiable {
    case network
    case extra
    case temp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: "网络缓存"
        case .extra: "文件缓存"
        case .temp: "临时文件"
        }
    }

    var subtitle: String {
        switch self {
        case .network: "网页与接口响应"
        case .extra: "缩略图与预览"
        case .temp: "下载中转文件"
        }
    }

    var symbol: String {
        switch self {
        case .network: "wifi"
        case .extra: "folder.fill"
        case .temp: "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .network: Color(hex: 0xFF453A)
        case .extra: Color(hex: 0xFF9F0A)
        case .temp: Color(hex: 0xFFD60A)
        }
    }

    func bytes(in usage: CacheUsage) -> Int64 {
        switch self {
        case .network: usage.network
        case .extra: usage.extra
        case .temp: usage.temp
        }
    }
}

// MARK: - 存储条 / 入口卡片

/// 分段占比条：各分类按缓存总量着色，末段为剩余空间。
struct CacheStorageBar: View {
    let usage: CacheUsage
    var height: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let total = max(usage.total, 1)
            let width = proxy.size.width

            HStack(spacing: 0) {
                ForEach(CacheCategory.allCases) { category in
                    let value = category.bytes(in: usage)
                    if value > 0 {
                        Rectangle()
                            .fill(category.tint)
                            .frame(width: max(2, width * CGFloat(value) / CGFloat(total)))
                    }
                }

                Rectangle()
                    .fill(RexColor.field)
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 图例：彩色圆点 + 分类名。
struct CacheLegend: View {
    let usage: CacheUsage
    var showsPercent: Bool = false

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: RexSpacing.sm, alignment: .leading)],
            alignment: .leading,
            spacing: RexSpacing.sm
        ) {
            ForEach(CacheCategory.allCases) { category in
                HStack(spacing: 5) {
                    Circle()
                        .fill(category.tint)
                        .frame(width: 8, height: 8)

                    Text(category.title)
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(1)

                    if showsPercent {
                        Text(CacheStats.percent(usage.ratio(category.bytes(in: usage))))
                            .font(RexFont.caption2)
                            .foregroundStyle(RexColor.tertiaryText)
                    }
                }
            }
        }
    }
}

/// 「更多」页顶部的缓存入口卡片：标题 + 已用容量 + 分段条 + 图例。
struct CacheStorageCard: View {
    let usage: CacheUsage
    var isLoading: Bool
    var showsChevron: Bool = true

    private var usedText: String {
        CacheStats.text(usage.total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: RexSpacing.md) {
                Text("缓存")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: 0)

                Text(isLoading ? "统计中…" : "已用 \(usedText)")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }

            if isLoading {
                RexSkeleton(width: .infinity, height: 18, cornerRadius: 6)
            } else {
                CacheStorageBar(usage: usage)
            }

            if !isLoading {
                CacheLegend(usage: usage)
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.panel)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("缓存已用 \(usedText)")
    }
}

