import SwiftUI

// MARK: - 影片卡片

struct MakerMovieCard: View {
    let movie: MakerMovie
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    MakerArtwork(movie.artworkURL, width: 360)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .overlay(alignment: .topLeading) {
                    if movie.hasCnsub {
                        MakerBadge(text: "中字", tint: RexColor.success)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if movie.magnetsCount > 0 {
                        MakerBadge(text: "\(movie.magnetsCount) 磁", tint: Color(hex: 0x64D2FF))
                            .padding(6)
                    }
                }
                .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)

            Text(movie.displayTitle)
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
        .accessibilityLabel(movie.displayTitle)
    }
}

struct MakerBadge: View {
    let text: String
    var tint: Color = RexColor.brandBlue

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 18)
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
                    .font(.system(size: 17, weight: .semibold))
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
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5, weight: .medium))
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RexSkeleton(width: posterWidth, height: posterWidth * 1.5, cornerRadius: 10)
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

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 5 : 3
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
