import SwiftUI

// MARK: - Hub 页头（对齐 PWA 的 app-hub 结构）

/// 居中大标题 + 右侧圆形操作按钮：与 PWA 的 Hub 顶部一致，不用系统导航栏。
struct RexHubTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.xs)
    }
}

/// 半透明圆形图标按钮，对应 PWA 的 `media-hub__search-btn`。
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 40, height: 40)
                .background(
                    RexColor.surface.opacity(0.78),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// 胶囊分段选择：对应 PWA 的 `media-source-switch`（浅色槽 + 白色选中块）。
struct RexPillTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(items, id: \.self) { item in
                    let selected = selection == item
                    Button {
                        guard !selected else { return }
                        RexHaptics.selection()
                        withAnimation(RexMotion.spring) {
                            selection = item
                        }
                    } label: {
                        Text(title(item))
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? RexColor.primaryText : RexColor.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
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
            .padding(3)
            .background(
                RexColor.field,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .padding(.horizontal, RexSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, RexSpacing.sm)
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

    var body: some View {
        NavigationLink {
            destination
        } label: {
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
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: tint.opacity(0.24), radius: 6, y: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(RexFont.row)
                            .foregroundStyle(RexColor.primaryText)
                            .lineLimit(1)

                        ForEach(allTags, id: \.self) { item in
                            Text(item)
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(imageName == nil ? tint : RexColor.secondaryText)
                                .padding(.horizontal, 5)
                                .frame(height: 17)
                                .background(
                                    (imageName == nil ? tint : RexColor.secondaryText).opacity(0.12),
                                    in: Capsule(style: .continuous)
                                )
                        }
                    }

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: RexSpacing.sm)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: RexLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RexRowButtonStyle())
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
        Button(action: action) {
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
                            .font(.system(size: 17, weight: .medium))
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: RexLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RexRowButtonStyle())
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
                            .font(.system(size: 20, weight: .medium))
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
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 5)
                                .frame(height: 17)
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
                    .font(.system(size: 13, weight: .semibold))
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
