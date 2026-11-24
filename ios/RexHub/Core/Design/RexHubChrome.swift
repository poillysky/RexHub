import SwiftUI

// MARK: - Hub 页头（对齐 PWA 的 app-hub 结构）

/// 居中大标题 + 右侧圆形操作按钮：与 PWA 的 Hub 顶部一致，不用系统导航栏。
///
/// 传入 `menuOptions` 后标题变为可点击下拉菜单，用于在同一入口内切换同级页面。
struct RexHubTitle<Trailing: View>: View {
    let title: String
    var menuOptions: [RexHubMenuOption] = []
    /// 左侧控件：二级页放返回按钮，一级页留空。
    var leading: AnyView? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            titleContent
                .frame(maxWidth: .infinity)

            HStack(spacing: RexSpacing.xs) {
                if let leading {
                    leading
                }
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.xs)
    }

    @ViewBuilder
    private var titleContent: some View {
        if menuOptions.isEmpty {
            titleText
                .frame(maxWidth: .infinity)
        } else {
            Menu {
                ForEach(menuOptions) { option in
                    Button {
                        option.action()
                    } label: {
                        if option.isSelected {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                titleText
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("切换页面，当前\(title)")
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.system(.title, design: .rounded, weight: .bold))
            .foregroundStyle(RexColor.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// 页头下拉菜单的一项。
struct RexHubMenuOption: Identifiable {
    let id: String
    let title: String
    var isSelected: Bool
    var action: () -> Void
}

/// 页头纯图标按钮：不带底色与外轮廓，只保留可点区域。
struct RexCircleIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// 页头返回按钮：与 `RexNavBar` 的 `.back` 同一套尺寸与配色。
struct RexHubBackButton: View {
    var action: () -> Void

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(RexColor.brandBlue)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .frame(width: 44, height: 44)
        .accessibilityLabel("返回")
    }
}

/// 胶囊分段选择：对应 PWA 的 `media-source-switch`（浅色槽 + 白色选中块）。
/// 每项宽度跟随文字自适应；总宽放不下时横向滚动，避免文字被压缩重叠。
struct RexPillTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    @ScaledMetric(relativeTo: .footnote) private var itemHeight: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                PillRowLayout(availableWidth: max(0, proxy.size.width - 6)) {
                    ForEach(items, id: \.self) { item in
                        pill(item)
                    }
                }
                .padding(3)
                .background(
                    RexColor.field,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: itemHeight + 6)
        .padding(.horizontal, RexSpacing.xl)
        .padding(.bottom, RexSpacing.sm)
    }

    private func pill(_ item: Item) -> some View {
        let selected = selection == item
        return Button {
            guard !selected else { return }
            RexHaptics.selection()
            withAnimation(RexMotion.spring) {
                selection = item
            }
        } label: {
            Text(title(item))
                .font(.system(.footnote, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? RexColor.primaryText : RexColor.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: itemHeight)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(RexColor.surface)
                            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 胶囊行布局：内容放得下时均分铺满，放不下时保持文字自然宽度交给外层滚动。
private struct PillRowLayout: Layout {
    var availableWidth: CGFloat
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentWidth = sizes.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, sizes.count - 1))
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: max(contentWidth, availableWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard !subviews.isEmpty else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentWidth = sizes.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, sizes.count - 1))

        var x = bounds.minX
        if contentWidth <= availableWidth + 0.5 {
            // 放得下：等分铺满整行。
            let each = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
            for subview in subviews {
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: each, height: bounds.height)
                )
                x += each + spacing
            }
        } else {
            // 放不下：保持文字宽度，由外层横向滚动。
            for (index, subview) in subviews.enumerated() {
                let width = sizes[index].width
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: bounds.height)
                )
                x += width + spacing
            }
        }
    }
}

// MARK: - 设置入口行（对齐 PWA settings-nav）

/// 彩色图标块 + 标题（可带标签）+ 箭头，用于「更多」页的分组入口。
struct RexSettingsNavLink<Destination: View>: View {
    var icon: String = ""
    /// 品牌图片（Asset 名）；设置后替代 SF Symbol 图标。
    var imageName: String? = nil
    var tint: Color = RexColor.brandBlue
    let title: String
    var tag: String?
    var tags: [String] = []
    var subtitle: String?
    @ViewBuilder var destination: Destination

    @State private var isPresented = false

    var body: some View {
        HStack(spacing: RexSpacing.md) {
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: tint.opacity(0.24), radius: 6, y: 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: RexSpacing.sm)

            HStack(spacing: 5) {
                ForEach(allTags, id: \.self) { item in
                    Text(item)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(imageName == nil ? tint : RexColor.secondaryText)
                        .padding(.horizontal, 5)
                        .frame(minHeight: 17)
                        .background(
                            (imageName == nil ? tint : RexColor.secondaryText).opacity(0.12),
                            in: Capsule(style: .continuous)
                        )
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(RexColor.tertiaryText)
                .padding(.leading, allTags.isEmpty ? 0 : RexSpacing.xs)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .rexRowAction { isPresented = true }
        .navigationDestination(isPresented: $isPresented) {
            destination
        }
    }

    private var allTags: [String] {
        var list: [String] = []
        if let tag, !tag.isEmpty { list.append(tag) }
        list.append(contentsOf: tags.filter { !$0.isEmpty })
        return list
    }
}

/// 纯操作行（无跳转），外观与 `RexSettingsNavLink` 一致。
struct RexSettingsNavButton: View {
    let icon: String
    var tint: Color = RexColor.brandBlue
    let title: String
    var value: String?
    var isDestructive: Bool = false
    var action: () -> Void

    var body: some View {
        HStack(spacing: RexSpacing.md) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(.white)
                }

            Text(title)
                .font(RexFont.row)
                .foregroundStyle(isDestructive ? RexColor.error : RexColor.primaryText)
                .lineLimit(1)

            Spacer(minLength: RexSpacing.sm)

            if let value, !value.isEmpty {
                Text(value)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(1)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .rexRowAction(action)
    }
}

// MARK: - 站点卡片（短剧 Hub 与设置入口共用）

struct RexSiteCard: View {
    let title: String
    var subtitle: String
    var symbol: String = "clapperboard"
    var tint: Color = RexColor.brandBlue
    var badge: String?
    var action: () -> Void

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: RexSpacing.md) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(.title3, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: tint.opacity(0.28), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: RexSpacing.sm) {
                        Text(title)
                            .font(.system(.headline, weight: .semibold))
                            .foregroundStyle(RexColor.primaryText)
                            .lineLimit(1)

                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 5)
                                .frame(minHeight: 17)
                                .background(tint.opacity(0.12), in: Capsule(style: .continuous))
                        }
                    }

                    Text(subtitle)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: 68)
            .background(RexColor.surface, in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}
