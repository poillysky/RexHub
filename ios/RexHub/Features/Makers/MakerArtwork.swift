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

    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let running = tasks[url] { return await running.value }

        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
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
                    .font(.system(size: 22, weight: .light))
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
              let url = apiClient?.makerImageURL(raw: raw, width: width) else {
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
