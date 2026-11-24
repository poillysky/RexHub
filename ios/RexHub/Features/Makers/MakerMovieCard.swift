import SwiftUI

// MARK: - 影片卡片

struct MakerMovieCard: View {
    let movie: MakerMovie
    var width: CGFloat?

    private let radius = RexRadius.control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    MakerArtwork(movie.artworkURL, width: 480)
                }
                .overlay { PosterBottomShade() }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .overlay(alignment: .topLeading) {
                    if movie.hasCnsub {
                        MakerBadge(text: "中", tint: Color.black.opacity(0.55))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if movie.magnetsCount > 0 {
                        MakerBadge(
                            text: "\(movie.magnetsCount)",
                            tint: Color(hex: 0xF5C518),
                            foreground: Color(hex: 0x1A1200)
                        )
                        .padding(6)
                    }
                }
                .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
                .shadow(color: Color.black.opacity(0.10), radius: 24, y: 8)

            Text(movie.displayTitle)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(movie.displayTitle)
    }
}

/// 海报底部渐变遮罩，对齐 PWA 的 `.media-poster__frame::after`。
struct PosterBottomShade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.62),
                .init(color: Color.black.opacity(0.36), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MakerBadge: View {
    let text: String
    var tint: Color = RexColor.brandBlue
    var foreground: Color = .white

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minHeight: 18)
            .background(tint.opacity(0.88), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
            }
    }
}

// MARK: - 分区页头

struct MakerShelfHeader: View {
    let title: String
    var detail: String?
    var onOpenAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: RexSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let onOpenAll {
                Button {
                    RexHaptics.tap()
                    onOpenAll()
                } label: {
                    HStack(spacing: 2) {
                        Text("全部")
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2, weight: .semibold))
                    }
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("查看\(title)全部")
            }
        }
    }
}

// MARK: - 骨架

struct MakerCardSkeletons: View {
    var posterWidth: CGFloat
    var count: Int = 3
    /// 卡片宽高比：影视海报 2:3，片商横卡 16:10。
    var aspect: CGFloat = 2 / 3

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RexSkeleton(width: posterWidth, height: posterWidth / aspect, cornerRadius: RexRadius.control)
                    RexSkeleton(width: posterWidth * 0.72, height: 11, cornerRadius: 5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 电影列表网格

struct MakerMovieGrid: View {
    let movies: [MakerMovie]
    /// 指定列数；不传时按尺寸类自适应（手机 3 列 / 宽屏 4 列）。
    var columnCount: Int? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let count = max(1, columnCount ?? (horizontalSizeClass == .regular ? 4 : 3))
        return Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md, alignment: .top), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(movies) { movie in
                NavigationLink(value: MakerRoute.movie(movie)) {
                    MakerMovieCard(movie: movie)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("查看影片详情")
            }
        }
    }
}
