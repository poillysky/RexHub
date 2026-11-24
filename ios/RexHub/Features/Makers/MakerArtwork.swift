import SwiftUI
import UIKit

// MARK: - 图片缓存

/// AVDB 图片都经服务端代理（上游是加扰字节流，客户端无法直连）。
/// 同一张封面会在列表、详情、相关推荐里反复出现，这里复用解码后的位图。
@MainActor
final class MakerImageStore {
    static let shared = MakerImageStore()

    private let cache = NSCache<NSURL, UIImage>()
    private var tasks: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 260
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL, bearerToken: String? = nil) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let running = tasks[url] { return await running.value }

        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 20
            if let bearerToken, !bearerToken.isEmpty {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await HTTPTransport.transfer.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            return image
        }
        tasks[url] = task
        let image = await task.value
        tasks[url] = nil

        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.rexMakerCacheCost)
        }
        return image
    }
}

private extension UIImage {
    var rexMakerCacheCost: Int {
        let pixels = size.width * size.height * scale * scale
        return max(1, Int(pixels * 4))
    }
}

// MARK: - 海报

struct MakerArtwork: View {
    /// AVDB 原始图片地址，服务端代理需要原样传回。
    let raw: String?
    var width: Int = 400

    @Environment(\.apiClient) private var apiClient
    @State private var image: UIImage?
    @State private var failed = false

    init(_ raw: String?, width: Int = 400) {
        self.raw = raw
        self.width = width
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(RexColor.field)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "film")
                    .font(.system(.title2, weight: .light))
                    .foregroundStyle(RexColor.tertiaryText)
            } else {
                MakerArtworkPlaceholder()
            }
        }
        .clipped()
        .animation(RexMotion.standard, value: image != nil)
        .task(id: raw) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let raw, !raw.isEmpty,
              let url = apiClient?.artworkURL(raw: raw, width: width) else {
            failed = true
            return
        }
        if let hit = MakerImageStore.shared.cached(url) {
            image = hit
            failed = false
            return
        }
        let loaded = await MakerImageStore.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

/// 预览图：固定高度、宽度按原图比例（竖图缩放到与横图同高，完整显示不裁切）。
/// 详情页「图片」区为一行横滑，竖图保持自身比例缩到统一高度。
struct MakerPreviewArtwork: View {
    let raw: String?
    var width: Int = 480
    var height: CGFloat = 90

    @Environment(\.apiClient) private var apiClient
    @State private var image: UIImage?

    init(_ raw: String?, width: Int = 480, height: CGFloat = 90) {
        self.raw = raw
        self.width = width
        self.height = height
    }

    var body: some View {
        Color.clear
            .frame(width: height * aspect, height: height)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Rectangle()
                        .fill(RexColor.field)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous))
            .animation(RexMotion.standard, value: image != nil)
            .task(id: raw) { await load() }
            .accessibilityHidden(true)
    }

    /// 图片加载前按 16:10 占位，加载后切到真实比例。
    private var aspect: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 16 / 10 }
        return image.size.width / image.size.height
    }

    private func load() async {
        guard let raw, !raw.isEmpty,
              let url = apiClient?.artworkURL(raw: raw, width: width) else { return }
        if let hit = MakerImageStore.shared.cached(url) {
            image = hit
            return
        }
        let loaded = await MakerImageStore.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

/// 全宽封面：宽度撑满父级，高度按原图比例计算，完整显示不裁切（竖图自然更高）。
/// 加载前按 16:10 占位，图片到达后切到真实比例。
struct MakerFullWidthArtwork: View {
    let raw: String?
    var width: Int = 1080

    @Environment(\.apiClient) private var apiClient
    @State private var image: UIImage?

    init(_ raw: String?, width: Int = 1080) {
        self.raw = raw
        self.width = width
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(RexColor.field)
                }
            }
            .clipped()
            .task(id: raw) { await load() }
            .accessibilityHidden(true)
    }

    private var aspect: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 16 / 10 }
        return image.size.width / image.size.height
    }

    private func load() async {
        guard let raw, !raw.isEmpty,
              let url = apiClient?.artworkURL(raw: raw, width: width) else { return }
        if let hit = MakerImageStore.shared.cached(url) {
            image = hit
            return
        }
        let loaded = await MakerImageStore.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

private struct MakerArtworkPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(RexColor.field)

                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.30), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.55)
                    .offset(x: phase * proxy.size.width * 1.7)
                }
            }
            .clipped()
            .onAppear {
                guard !reduceMotion else { return }
                phase = -1
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}
