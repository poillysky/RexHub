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
                .frame(maxWidth: RexLayout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var summaryCard: some View {
        HStack(spacing: RexSpacing.md) {
            FileIconView(kind: .archive, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(2)

                Text(sizeText)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(RexSpacing.lg)
        .rexCard()
    }

    private var loadingCard: some View {
        RexStateCard(
            symbol: "archivebox",
            title: "正在读取压缩包",
            message: "较大的压缩包需要先下载到临时目录。",
            tone: .brand,
            isLoading: true
        )
    }

    private func messageCard(_ text: String) -> some View {
        RexStateCard(
            symbol: "archivebox",
            title: "无法预览压缩包",
            message: text,
            tone: .warning
        )
    }

    private var entryCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("共 \(entries.count) 个文件")
                    .font(RexFont.section)
                    .foregroundStyle(RexColor.secondaryText)
                    .contentTransition(.numericText())

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
                        .font(RexFont.row)
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: RexSpacing.sm)

                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(minHeight: 48)
            }
        }
        .rexCard()
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
