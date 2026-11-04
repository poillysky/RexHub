import QuickLook
import SwiftUI
import UIKit

/// 文档预览：下载到本地临时文件后交给系统 QuickLook（PDF / Office / 文本 / 压缩包等）。
struct PanDocumentViewerView: View {
    let item: PanItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient

    @State private var fileURL: URL?
    @State private var errorText: String?
    @State private var showPreview = false

    var body: some View {
        ZStack {
            if let errorText {
                RexStateCard(
                    symbol: "doc.badge.ellipsis",
                    title: "无法预览文件",
                    message: errorText,
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    RexHaptics.tap()
                    Task { await load() }
                }
            } else {
                RexStateCard(
                    symbol: "doc.text.magnifyingglass",
                    title: "正在准备预览",
                    message: "文件会先下载到临时目录，预览结束后自动清理。",
                    tone: .brand,
                    isLoading: true
                )
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .frame(maxWidth: RexLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $showPreview, onDismiss: { dismiss() }) {
            if let fileURL {
                QuickLookPreview(url: fileURL)
                    .ignoresSafeArea()
            }
        }
        .onDisappear {
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
        }
    }

    @MainActor
    private func load() async {
        guard let client = apiClient else {
            errorText = "登录状态已失效，请重新登录"
            return
        }

        errorText = nil

        do {
            fileURL = try await PanRemoteFile.download(item: item, client: client)
            showPreview = true
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorText = error.errorDescription ?? "文件加载失败"
        } catch {
            errorText = "文件加载失败"
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
