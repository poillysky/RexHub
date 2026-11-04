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
            summaryCard

            SettingsSection(title: "缓存明细") {
                SettingsRow(icon: "wifi", title: "网络缓存", value: sizeText(usage.network))
                SettingsDivider()
                SettingsRow(icon: "folder.fill", title: "文件缓存", value: sizeText(usage.extra))
                SettingsDivider()
                SettingsRow(icon: "hourglass", title: "临时文件", value: sizeText(usage.temp))
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
                isEnabled: !isLoading && !isClearing
            ) {
                Task { await refresh() }
            }
        ]
    }

    // MARK: - 总量

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            HStack(spacing: RexSpacing.md) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        .white.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("缓存总量")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))

                    Text(isLoading ? "统计中…" : sizeText(usage.total))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 0)
            }

            Text("缓存只包含缩略图、网络响应和临时文件，清理不会影响账号、收藏与网盘文件。")
                .font(RexFont.caption)
                .foregroundStyle(.white.opacity(0.84))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RexSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
                    .fill(RexColor.brandGradient)

                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    .frame(width: 168, height: 168)
                    .offset(x: 118, y: -58)

                Circle()
                    .fill(.white.opacity(0.06))
                    .frame(width: 96, height: 96)
                    .offset(x: 86, y: -46)
            }
            .clipShape(RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.75)
        }
        .shadow(color: RexColor.brandBlue.opacity(0.18), radius: 16, y: 8)
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
    }

    // MARK: - 数据

    @MainActor
    private func refresh() async {
        isLoading = true

        let urlCache = URLCache.shared
        let network = Int64(urlCache.currentDiskUsage) + Int64(urlCache.currentMemoryUsage)
        let diskCache = Int64(urlCache.currentDiskUsage)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let temp = FileManager.default.temporaryDirectory

        let scanned = await Task.detached(priority: .utility) {
            let cachesBytes = caches.map { Self.directorySize($0) } ?? 0
            return CacheUsage(
                network: network,
                extra: max(0, cachesBytes - diskCache),
                temp: Self.directorySize(temp)
            )
        }.value

        usage = scanned
        isLoading = false
    }

    @MainActor
    private func clear() async {
        isClearing = true
        URLCache.shared.removeAllCachedResponses()

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let temp = FileManager.default.temporaryDirectory

        await Task.detached(priority: .userInitiated) {
            if let caches {
                Self.removeContents(of: caches)
            }
            Self.removeContents(of: temp)
        }.value

        await refresh()
        isClearing = false
        RexHaptics.success()
    }

    private static func directorySize(_ url: URL) -> Int64 {
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

    private static func removeContents(of directory: URL) {
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

    private func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct CacheUsage: Equatable, Sendable {
    var network: Int64 = 0
    var extra: Int64 = 0
    var temp: Int64 = 0

    var total: Int64 { network + extra + temp }

    static let zero = CacheUsage()
}
