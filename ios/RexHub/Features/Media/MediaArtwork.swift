import SwiftUI
import UIKit

// MARK: - 图片缓存

/// 海报 / 剧照缓存：服务端已经把 TMDB 图片代理到内网，客户端再缓存解码后的位图，
/// 让同一张海报在竖向滚动、栏目切换、详情页之间不再重复请求与解码。
@MainActor
final class MediaImageStore {
    static let shared = MediaImageStore()

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
            cache.setObject(image, forKey: url as NSURL, cost: image.rexCacheCost)
        }
        return image
    }
}

private extension UIImage {
    /// 解码后的近似内存占用，用于 `NSCache` 的容量回收。
    var rexCacheCost: Int {
        let pixels = size.width * size.height * scale * scale
        return max(1, Int(pixels * 4))
    }
}

// MARK: - 海报图

/// 按 TMDB 路径加载海报：`path` 直接取接口返回的 `/abc.jpg`。
struct MediaArtwork: View {
    let path: String
    var size: String = "w342"

    @Environment(\.apiClient) private var apiClient
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if path.isEmpty {
                // 没有图片时直接铺静态底色，避免占位高光一直在转。
                Rectangle()
                    .fill(RexColor.field)

                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(RexColor.tertiaryText)
            } else {
                MediaArtworkPlaceholder()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if failed {
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }
        }
        .clipped()
        .animation(RexMotion.standard, value: image != nil)
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let url = apiClient?.mediaImageURL(path: path, size: size) else {
            failed = true
            return
        }
        if let hit = MediaImageStore.shared.cached(url) {
            image = hit
            failed = false
            return
        }
        let loaded = await MediaImageStore.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

/// 图片占位：与全局骨架屏一致的高光扫过，但填满任意尺寸的容器。
private struct MediaArtworkPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(RexColor.field)

                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.34), .clear],
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
        .accessibilityHidden(true)
    }
}

// MARK: - 评分徽标

struct MediaRatingBadge: View {
    let rating: Double
    var compact: Bool = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: compact ? 8.5 : 10, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFFC93C))

            Text(String(format: "%.1f", rating))
                .font(.system(size: compact ? 11 : 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.horizontal, compact ? 6 : 8)
        .frame(height: compact ? 20 : 24)
        .background(Color.black.opacity(0.74), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
        }
        .accessibilityLabel("评分 \(String(format: "%.1f", rating))")
    }
}

// MARK: - 海报卡片

/// 海报卡片：2:3 海报 + 标题（+ 年份）。`width` 传 nil 时按容器宽度自适应，用于网格。
struct MediaPosterCard: View {
    let item: MediaItem
    var width: CGFloat?
    var showsYear: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    MediaArtwork(path: item.poster, size: "w342")
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .overlay(alignment: .topLeading) {
                    if let rating = item.rating {
                        MediaRatingBadge(rating: rating)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // 年份做成右上角角标，与评分左右对称，卡片下方只留标题。
                    if showsYear, !item.year.isEmpty {
                        Text(item.year)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .frame(height: 18)
                            .background(Color.black.opacity(0.62), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
                            }
                            .padding(6)
                    }
                }
                .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)

            Text(item.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HStack(alignment: .top, spacing: RexSpacing.md) {
        MediaPosterCard(
            item: MediaItem(
                id: "tmdb:movie:1",
                mediaType: "movie",
                title: "生化危机：爆发夜",
                poster: "/qMvRqzzDVfQpLi5ZoKwttTQdaJe.jpg",
                backdrop: "",
                overview: "",
                year: "2026",
                rating: 7.5
            ),
            width: 112
        )
    }
    .padding()
    .background(RexColor.background)
}
