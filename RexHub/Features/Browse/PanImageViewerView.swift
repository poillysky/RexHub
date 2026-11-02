import SwiftUI
import UIKit

/// 图片预览：当前目录的图片可左右翻页，支持双击放大、双指缩放与上一张 / 下一张。
struct PanImageViewerView: View {
    let items: [PanItem]
    let startID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient

    @State private var selection: String
    @State private var showInfo = false
    @State private var isPreparingShare = false
    @State private var isSharing = false
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    init(items: [PanItem], startID: String) {
        self.items = items
        self.startID = startID
        _selection = State(initialValue: startID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(items) { item in
                    ZoomablePanImage(item: item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                footer
            }

            if isPreparingShare {
                busyOverlay("正在准备分享…")
            }
        }
        .statusBarHidden()
        .sensoryFeedback(.selection, trigger: selection)
        .sheet(isPresented: $showInfo) {
            if let currentItem {
                PanImageInfoSheet(item: currentItem)
            }
        }
        .sheet(isPresented: $isSharing, onDismiss: cleanUpShareFile) {
            if let shareURL {
                ActivityView(items: [shareURL])
            }
        }
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 数据

    private var currentItem: PanItem? {
        items.first { $0.id == selection }
    }

    private var currentIndex: Int {
        items.firstIndex { $0.id == selection } ?? 0
    }

    private var canGoPrevious: Bool { currentIndex > 0 }
    private var canGoNext: Bool { currentIndex < items.count - 1 }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: RexSpacing.md) {
            circleButton(systemImage: "xmark", label: "关闭") {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(currentItem?.name ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Spacer(minLength: RexSpacing.sm)

            circleButton(systemImage: "square.and.arrow.up", label: "分享") {
                Task { await prepareShare() }
            }

            circleButton(systemImage: "info.circle", label: "图片信息") {
                showInfo = true
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.md)
        .animation(.easeOut(duration: 0.2), value: selection)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private var subtitle: String {
        let counter = "\(currentIndex + 1) / \(items.count)"
        guard let item = currentItem, item.size > 0 else { return counter }
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        return "\(counter) · \(size)"
    }

    private func circleButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 0) {
            navButton(
                systemImage: "chevron.left",
                label: "上一张",
                isEnabled: canGoPrevious
            ) {
                go(-1)
            }

            Text("\(currentIndex + 1) / \(items.count)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.numericText())
                .frame(minWidth: 66)

            navButton(
                systemImage: "chevron.right",
                label: "下一张",
                isEnabled: canGoNext
            ) {
                go(1)
            }
        }
        .frame(height: 46)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, y: 4)
        .animation(.easeOut(duration: 0.2), value: selection)
        .frame(maxWidth: .infinity)
        .padding(.bottom, RexSpacing.xl)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func navButton(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.28))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    // MARK: - 翻页

    private func go(_ delta: Int) {
        let target = currentIndex + delta
        guard items.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            selection = items[target].id
        }
    }

    // MARK: - 分享

    @MainActor
    private func prepareShare() async {
        guard !isPreparingShare, let item = currentItem else { return }
        guard let client = apiClient, !item.pickcode.isEmpty else {
            errorMessage = "无法获取原图，请稍后重试"
            return
        }

        isPreparingShare = true
        defer { isPreparingShare = false }

        do {
            shareURL = try await PanRemoteFile.download(item: item, client: client)
            isSharing = true
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorMessage = "分享失败，请重试"
        } catch {
            errorMessage = "分享失败，请重试"
        }
    }

    private func cleanUpShareFile() {
        if let shareURL {
            try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent())
        }
        shareURL = nil
    }

    // MARK: - 提示

    private func busyOverlay(_ text: String) -> some View {
        VStack(spacing: RexSpacing.md) {
            ProgressView()
                .tint(.white)

            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, RexSpacing.xxl)
        .padding(.vertical, RexSpacing.xl)
        .background(
            .white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - 单张图片

/// 单张图片：先取直链原图，失败时回退到服务端缩略图。
private struct ZoomablePanImage: View {
    let item: PanItem

    @Environment(\.apiClient) private var apiClient

    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnificationGesture(in: proxy.size))
                        .simultaneousGesture(dragGesture(in: proxy.size))
                        .onTapGesture(count: 2) { toggleZoom() }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if failed {
                    VStack(spacing: RexSpacing.md) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))

                        Text("图片加载失败")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))

                        Button {
                            Task { await retry() }
                        } label: {
                            Text("重试")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, RexSpacing.lg)
                                .frame(height: 34)
                                .background(.white.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                } else {
                    VStack(spacing: RexSpacing.md) {
                        ProgressView()
                            .tint(.white)

                        Text("加载原图…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: item.id) { await load() }
    }

    // MARK: - 手势

    private func magnificationGesture(in bounds: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let next = min(max(baseScale * value, 1), 5)
                scale = next
                offset = clamped(offset, in: bounds, scale: next)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1
                        baseScale = 1
                        offset = .zero
                        baseOffset = .zero
                    }
                } else {
                    baseOffset = offset
                }
            }
    }

    private func dragGesture(in bounds: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clamped(
                    CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    ),
                    in: bounds,
                    scale: scale
                )
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                baseOffset = offset
            }
    }

    /// 放大后限制拖动范围，避免图片被拖出屏幕。
    private func clamped(_ value: CGSize, in bounds: CGSize, scale: CGFloat) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return value }
        let fitRatio = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let scaledWidth = image.size.width * fitRatio * scale
        let scaledHeight = image.size.height * fitRatio * scale
        let maxX = max(0, (scaledWidth - bounds.width) / 2)
        let maxY = max(0, (scaledHeight - bounds.height) / 2)
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.22)) {
            if scale > 1 {
                scale = 1
                baseScale = 1
                offset = .zero
                baseOffset = .zero
            } else {
                scale = 2.5
                baseScale = 2.5
                baseOffset = .zero
            }
        }
    }

    // MARK: - 加载

    private func load() async {
        guard image == nil else { return }
        guard let client = apiClient, !item.pickcode.isEmpty else {
            failed = true
            return
        }

        let cacheKey = (item.sha1.isEmpty ? item.id : item.sha1) as NSString
        if let cached = PanImageCache.shared.object(forKey: cacheKey) {
            image = cached
            return
        }

        do {
            let data = try await PanRemoteFile.imageData(item: item, client: client)
            guard let decoded = UIImage(data: data) else { throw APIError.decoding }
            PanImageCache.shared.setObject(decoded, forKey: cacheKey)
            image = decoded
        } catch {
            if let data = try? await client.panThumbnail(sha1: item.sha1),
               let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        }
    }

    private func retry() async {
        failed = false
        image = nil
        await load()
    }
}

/// 原图只在本次运行内复用，避免来回翻页重复下载；内存紧张时由系统自动回收。
private enum PanImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        return cache
    }()
}

// MARK: - 图片信息

private struct PanImageInfoSheet: View {
    let item: PanItem

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RexSpacing.md) {
                FileIconView(kind: .image, size: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(2)

                    Text("图片")
                        .font(.system(size: 12))
                        .foregroundStyle(RexColor.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RexSpacing.lg)
            .padding(.vertical, RexSpacing.lg)

            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)

            row("大小", sizeText)
            divider
            row("格式", formatText)
            divider
            row("修改时间", dateText)

            Spacer(minLength: 0)
        }
        .background(RexColor.surface)
        .rexSheetStyle()
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }

    private var formatText: String {
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? "—" : ext.uppercased()
    }

    private var dateText: String {
        guard item.updatedAt > 0 else { return "—" }
        return Self.dateFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(item.updatedAt))
        )
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: RexSpacing.md) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(RexColor.secondaryText)

            Spacer(minLength: 0)

            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: 44)
    }

    private var divider: some View {
        Rectangle()
            .fill(RexColor.divider)
            .frame(height: 1 / displayScale)
            .padding(.leading, RexSpacing.lg)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - 系统分享

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
