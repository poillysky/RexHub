import SwiftUI
import UIKit

/// 图片预览：当前目录的图片可左右翻页，支持双击放大、双指缩放。
struct PanImageViewerView: View {
    let items: [PanItem]
    let startID: String

    @Environment(\.dismiss) private var dismiss

    @State private var selection: String

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
        }
        .statusBarHidden()
        .sensoryFeedback(.selection, trigger: selection)
    }

    // MARK: - 数据

    private var currentItem: PanItem? {
        items.first { $0.id == selection }
    }

    private var currentIndex: Int {
        items.firstIndex { $0.id == selection } ?? 0
    }

    // MARK: - 顶栏

    private var header: some View {
        ZStack {
            VStack(spacing: 3) {
                Text(currentItem?.name ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: selection)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("关闭")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.lg)
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

    // MARK: - 底栏

    private var footer: some View {
        thumbnailStrip
            .padding(.bottom, RexSpacing.md)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
    }

    /// 底部缩略图条：显示相邻图片，点击直接跳转。
    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: RexSpacing.sm) {
                    ForEach(items) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selection = item.id
                            }
                        } label: {
                            PanThumbnailView(item: item, isSelected: item.id == selection)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .id(item.id)
                    }
                }
                .padding(.horizontal, RexSpacing.lg)
                .padding(.vertical, RexSpacing.sm)
            }
            .frame(height: 62)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, newValue in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - 单张图片

/// 单张图片：先取直链原图，失败时回退到服务端缩略图。
private struct ZoomablePanImage: View {
    let item: PanItem

    @Environment(\.apiClient) private var apiClient
    @Environment(\.displayScale) private var displayScale

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
                        // 未放大时不接管拖拽，手势交给 TabView 翻页；
                        // 放大后才用拖拽平移图片，避免滑动被图片吃掉。
                        .simultaneousGesture(
                            dragGesture(in: proxy.size),
                            including: scale > 1 ? .all : GestureMask.subviews
                        )
                        .onTapGesture(count: 2) { toggleZoom() }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
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
                    .padding(.horizontal, RexSpacing.xxl)
                    .padding(.vertical, RexSpacing.xl)
                    .background(
                        .white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    )
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
        if let cached = PanImageCache.shared.image(forKey: cacheKey) {
            image = cached
            return
        }

        let maxPixelSize = maxDisplayPixelSize
        do {
            let data = try await PanRemoteFile.imageData(item: item, client: client)
            guard let decoded = await Self.decode(data, maxPixelSize: maxPixelSize) else {
                throw APIError.decoding
            }
            PanImageCache.shared.insert(decoded, forKey: cacheKey)
            withAnimation(.easeOut(duration: 0.22)) { image = decoded }
        } catch {
            if let data = try? await client.panThumbnail(sha1: item.sha1),
               let decoded = await Self.decode(data, maxPixelSize: maxPixelSize) {
                withAnimation(.easeOut(duration: 0.22)) { image = decoded }
            } else {
                failed = true
            }
        }
    }

    /// 原图按屏幕尺寸降采样后解码：十几 M 的 JPEG 直接解成位图可能有上百 M，
    /// 连翻几张就会触发系统杀进程。2 倍的屏幕像素兼顾放大清晰度，并封顶避免 iPad 上过大。
    private var maxDisplayPixelSize: CGFloat {
        let bounds = UIScreen.main.bounds
        return min(max(bounds.width, bounds.height) * displayScale * 2, 3000)
    }

    private static func decode(_ data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        // 同时只解码有限张，避免快速翻页时多张大图同时展开造成内存尖峰。
        await PanImageDecodeGate.shared.acquire()
        let image = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage?.none }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize))
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return UIImage?.none
            }
            return UIImage(cgImage: cgImage)
        }.value
        await PanImageDecodeGate.shared.release()
        return image
    }

    private func retry() async {
        failed = false
        image = nil
        await load()
    }
}

private extension UIImage {
    var decodedByteCount: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// 原图只在本次运行内复用，避免来回翻页重复下载；内存紧张时立即清空。
private final class PanImageCache {
    static let shared = PanImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 5
        // 解码后的位图才是内存大头，按实际字节数计费，超过上限自动淘汰。
        cache.totalCostLimit = 64 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [cache] _ in
            cache.removeAllObjects()
        }
    }

    func image(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func insert(_ image: UIImage, forKey key: NSString) {
        cache.setObject(image, forKey: key, cost: image.decodedByteCount)
    }
}

/// 解码并发闸门：最多两张同时解码，多余的排队，避免翻页时内存尖峰。
private actor PanImageDecodeGate {
    static let shared = PanImageDecodeGate()

    private let limit = 2
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        // 名额直接由 release() 移交，恢复时不再重复计数。
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - 缩略图

/// 底部缩略图：小尺寸解码，内存占用可以忽略。
private struct PanThumbnailView: View {
    let item: PanItem
    let isSelected: Bool

    @Environment(\.apiClient) private var apiClient
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.1))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    .white.opacity(isSelected ? 0.9 : 0.12),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(isSelected ? 1 : 0.62)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        guard image == nil, let client = apiClient, !item.sha1.isEmpty else { return }
        let key = item.sha1 as NSString
        if let cached = PanThumbnailCache.shared.image(forKey: key) {
            image = cached
            return
        }
        guard let data = try? await client.panThumbnail(sha1: item.sha1) else { return }
        await PanImageDecodeGate.shared.acquire()
        let decoded = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage?.none }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 144
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return UIImage?.none
            }
            return UIImage(cgImage: cgImage)
        }.value
        await PanImageDecodeGate.shared.release()

        guard let decoded else { return }
        PanThumbnailCache.shared.insert(decoded, forKey: key)
        image = decoded
    }
}

private final class PanThumbnailCache {
    static let shared = PanThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 12 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [cache] _ in
            cache.removeAllObjects()
        }
    }

    func image(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func insert(_ image: UIImage, forKey key: NSString) {
        cache.setObject(image, forKey: key, cost: image.decodedByteCount)
    }
}


