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

    /// 只清一个分类，其余缓存保留。
    static func clear(_ category: CacheCategory) async {
        switch category {
        case .network:
            URLCache.shared.removeAllCachedResponses()

        case .extra:
            // 网络缓存的落盘位置也在 Caches 下（以 bundle id 命名），跳过它。
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return }
            let keep = Bundle.main.bundleIdentifier
            await Task.detached(priority: .userInitiated) {
                let manager = FileManager.default
                let entries = (try? manager.contentsOfDirectory(
                    at: caches,
                    includingPropertiesForKeys: nil
                )) ?? []
                for entry in entries where entry.lastPathComponent != keep {
                    try? manager.removeItem(at: entry)
                }
            }.value

        case .temp:
            await Task.detached(priority: .userInitiated) {
                removeContents(of: FileManager.default.temporaryDirectory)
            }.value
        }
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

