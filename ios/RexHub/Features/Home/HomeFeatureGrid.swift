import SwiftUI

/// 5 列入口宫格：展示用户配置的首页应用，末尾固定一个「更多」。
///
/// 图标按参考稿做成实色渐变圆角方块（白符号 + 顶部高光 + 淡色投影），
/// 而不是「淡色底 + 线条符号」——宫格是首屏面积最大的视觉块，实色图标才立得住。
/// 带品牌图的入口（115 网盘）直接用官方方形图标铺满，插件短剧入口用插件 logo。
///
/// 无障碍字号（AX1 起）自动收到 4 列并允许标题折两行：5 列在 AX3 下每格只剩 60pt 宽，
/// 「云下载」这类三字标题会被压到最小字号甚至截断。
struct HomeFeatureGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let apps: [HomeAppItem]
    let onAction: (HomeAction) -> Void
    let onMore: () -> Void

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 4 : 5
        // 列间距 16：5 列时每列 (358-64)/5 = 58.8pt，正好等于图标宽度，
        // 图标铺满整列后左边缘与上面的徽章、标题落在同一条竖线上（间距 8 时每列 65.2pt，
        // 图标被居中会右移约 3pt，三行左边缘对不齐）。
        return Array(repeating: GridItem(.flexible(), spacing: RexSpacing.lg), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: RexSpacing.lg) {
            ForEach(apps) { app in
                Button {
                    RexHaptics.tap()
                    onAction(app.action)
                } label: {
                    VStack(spacing: RexSpacing.sm) {
                        HomeAppIcon(
                            symbol: app.symbol,
                            accent: app.accent,
                            brandImage: app.brandImage,
                            logoURL: app.logoURL
                        )

                        Text(app.title)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(app.title)
            }

            moreButton
        }
    }

    private var moreButton: some View {
        Button {
            RexHaptics.tap()
            onMore()
        } label: {
            VStack(spacing: RexSpacing.sm) {
                HomeMoreIcon()

                Text("更多")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("更多应用")
    }
}

/// 宫格图标：宽度自适应列宽（小屏自动缩），上限 60，保证 5 列不挤。
///
/// 颜色处理是这一块的关键：底色用不满分的实色，再用一层「上白下黑」的覆盖层压出体积。
/// 早前版本用 `color.opacity(0.72)` 做渐变下半段，等于让背景透上来把颜色洗淡，
/// 图标因此发灰；压深才是对的。
struct HomeAppIcon: View {
    let symbol: String
    let accent: RexBrandColor
    var brandImage: String? = nil
    var logoURL: URL? = nil
    /// 图标边长上限：首页宫格是 60，编辑页的「首页应用」卡缩到一半。
    var maxWidth: CGFloat = 60

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: maxWidth * 0.3, style: .continuous)
    }

    var body: some View {
        Group {
            if let brandImage {
                brandTile(brandImage)
            } else if let logoURL {
                remoteTile(logoURL)
            } else {
                accentTile
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: maxWidth)
    }

    /// 品牌入口：直接用官方方形图标铺满，和第三方 App 图标同一个观感。
    private func brandTile(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .shadow(color: Color.black.opacity(0.10), radius: maxWidth * 0.1, x: 0, y: maxWidth * 0.05)
    }

    /// 插件入口：logo 直接满铺到圆角方块里，不再套白底/内边距/描边，
    /// 避免深色 logo 外面出现一圈白框。
    private func remoteTile(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    }
                    .clipShape(shape)
                    .shadow(color: Color.black.opacity(0.10), radius: maxWidth * 0.1, x: 0, y: maxWidth * 0.05)
            } else {
                accentTile
            }
        }
    }

    private var accentTile: some View {
        shape
            .fill(accent.color)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.24), location: 0),
                        .init(color: Color.white.opacity(0), location: 0.42),
                        .init(color: Color.black.opacity(0.15), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: maxWidth * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: accent.color.opacity(0.30), radius: maxWidth * 0.14, x: 0, y: maxWidth * 0.08)
    }
}

/// 「更多」入口：中性灰方块 + 省略号，和彩色应用图标拉开层级。
private struct HomeMoreIcon: View {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Color(hex: 0x8E8E93))
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.24), location: 0),
                        .init(color: Color.white.opacity(0), location: 0.42),
                        .init(color: Color.black.opacity(0.15), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            }
            .overlay {
                Image(systemName: "ellipsis")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 5)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 60)
    }
}
