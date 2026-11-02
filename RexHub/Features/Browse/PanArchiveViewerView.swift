import SwiftUI

/// 压缩包预览：zip 列出内部文件清单，其它格式给出提示。
struct PanArchiveViewerView: View {
    let item: PanItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient
    @Environment(\.displayScale) private var displayScale

    @State private var entries: [ZipEntry] = []
    @State private var message: String?
    @State private var isLoading = true

    /// 超过这个体积的压缩包不下载，避免占满临时空间。
    private let maxSize: Int64 = 200 * 1024 * 1024

    private var fileExtension: String {
        (item.name as NSString).pathExtension.lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "压缩包",
                leading: .text("关闭", action: { dismiss() }),
                isScrolled: false
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.md) {
                    summaryCard

                    if isLoading {
                        loadingCard
                    } else if let message {
                        messageCard(message)
                    } else {
                        entryCard
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.xxxl)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(RexColor.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var summaryCard: some View {
        HStack(spacing: RexSpacing.md) {
            FileIconView(kind: .archive, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)

                Text(sizeText)
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(RexSpacing.lg)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private var loadingCard: some View {
        HStack(spacing: RexSpacing.sm) {
            ProgressView()
            Text("正在读取压缩包…")
                .font(.system(size: 14))
                .foregroundStyle(RexColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxl)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private func messageCard(_ text: String) -> some View {
        VStack(spacing: RexSpacing.sm) {
            Image(systemName: "archivebox")
                .font(.system(size: 24))
                .foregroundStyle(RexColor.secondaryText.opacity(0.6))

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(RexColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxl)
        .padding(.horizontal, RexSpacing.lg)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private var entryCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("共 \(entries.count) 个文件")
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RexSpacing.lg)
            .padding(.vertical, RexSpacing.sm)

            ForEach(entries) { entry in
                Rectangle()
                    .fill(RexColor.divider)
                    .frame(height: 1 / displayScale)
                    .padding(.leading, RexSpacing.lg + 28 + RexSpacing.md)

                HStack(spacing: RexSpacing.md) {
                    FileIconView(kind: .fileKind(forName: entry.name), size: 28)

                    Text(entry.name)
                        .font(.system(size: 14))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: RexSpacing.sm)

                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.system(size: 12))
                        .foregroundStyle(RexColor.secondaryText)
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(height: 46)
            }
        }
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }

    @MainActor
    private func load() async {
        guard let client = apiClient else {
            isLoading = false
            message = "登录状态已失效，请重新登录"
            return
        }

        guard fileExtension == "zip" else {
            isLoading = false
            message = "暂不支持在线查看 \(fileExtension.isEmpty ? "该格式" : fileExtension.uppercased()) 的内容，可下载后用其它 App 打开"
            return
        }

        guard item.size <= maxSize else {
            isLoading = false
            message = "压缩包超过 200 MB，暂不在线列出内容"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let url = try await PanRemoteFile.download(item: item, client: client)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let list = try ZipEntryLister.entries(at: url)
            if list.isEmpty {
                message = "没有读取到压缩包内的文件"
            } else {
                entries = list
            }
        } catch let error as APIError {
            guard error != .cancelled else { return }
            message = error.errorDescription ?? "压缩包读取失败"
        } catch {
            message = "压缩包读取失败"
        }
    }
}
