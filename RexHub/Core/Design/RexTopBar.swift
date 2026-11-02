import SwiftUI

/// 全局顶栏：固定在安全区下方，不随页面滚动。
/// 展开态显示副标题与搜索框；页面滚动后收拢为单行，并铺 `surface` 底色 + 1px 分隔线。
struct RexTopBar<Trailing: View>: View {
    enum Leading {
        /// 一级页：品牌标 + 标题
        case logo
        /// 一级页（非首页）：只有标题，没有返回
        case none
        /// 二级页：返回按钮（chevron + 文字），点击 pop 回上一页
        case back(title: String, action: () -> Void)
    }

    var title: String
    var subtitle: String?
    var leading: Leading
    var searchText: Binding<String>?
    var searchPlaceholder: String
    var isCollapsed: Bool
    var onSearchTap: (() -> Void)?
    private let trailing: Trailing

    @Environment(\.displayScale) private var displayScale

    /// 页面滚动后收拢为单行。
    private var collapsed: Bool { isCollapsed }

    init(
        title: String,
        subtitle: String? = nil,
        leading: Leading = .logo,
        searchText: Binding<String>? = nil,
        searchPlaceholder: String = "搜索",
        isCollapsed: Bool = false,
        onSearchTap: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.isCollapsed = isCollapsed
        self.onSearchTap = onSearchTap
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RexSpacing.md) {
                leadingView

                titleBlock

                Spacer(minLength: RexSpacing.sm)

                if collapsed, searchText != nil, let onSearchTap {
                    Button(action: onSearchTap) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(RexColor.secondaryText)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("展开搜索")
                }

                trailing
            }
            .padding(.horizontal, RexSpacing.xl)
            .frame(height: collapsed ? 52 : 56)

            if let searchText {
                RexSearchField(text: searchText, placeholder: searchPlaceholder)
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.bottom, collapsed ? 0 : RexSpacing.md)
                    .frame(height: collapsed ? 0 : 56)
                    .opacity(collapsed ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!collapsed)
                    .accessibilityHidden(collapsed)
            }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(collapsed ? RexColor.surface : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)
                .opacity(collapsed ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: collapsed)
    }

    // MARK: - 组成

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .logo:
            RexLogoMark(size: collapsed ? 28 : 36, hasShadow: false)
                .animation(.easeOut(duration: 0.2), value: collapsed)
        case .none:
            EmptyView()
        case .back(let text, let action):
            Button(action: action) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))

                    Text(text)
                        .font(.system(size: 15))
                }
                .foregroundStyle(RexColor.brandBlue)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("返回\(text)")
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: collapsed ? 17 : 20, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: collapsed ? 0 : 14, alignment: .top)
                    .opacity(collapsed ? 0 : 1)
                    .clipped()
                    .accessibilityHidden(collapsed)
            }
        }
        .layoutPriority(1)
    }
}

// MARK: - 通用顶栏

/// 通用顶栏遮罩：固定在安全区下方，不随内容滚动。
/// 结构固定为「左返回（一级页没有）+ 居中标题 + 右侧快捷操作」，页面只传自己的快捷操作。
/// 顶栏未滚动时与页面融合，滚动后铺 `surface` 并出现 1px 分隔线。
struct RexNavBar: View {
    enum Leading {
        /// 一级页：没有返回
        case none
        /// 二级页：返回上一页
        case back(action: () -> Void)
        /// 文字按钮，如多选态的「取消」。
        case text(String, action: () -> Void)
        /// 描边胶囊文字按钮，如多选态的「全选」。
        case pill(String, action: () -> Void)
    }

    var title: String
    var leading: Leading = .none
    var actions: [RexNavAction] = []
    /// 多个操作整体套一个胶囊描边，图标改为黑白主色。
    var groupsActions: Bool = false
    /// 页面是否已滚动；由 `rexScrollTracking` 驱动。
    var isScrolled: Bool = false

    private let theme = RexThemeStore.shared

    @Environment(\.displayScale) private var displayScale

    /// 页面滚动后收拢。
    private var isCollapsed: Bool {
        isScrolled
    }

    private var barHeight: CGFloat {
        if isCollapsed { return 44 }
        return theme.titleStyle == .compact ? 48 : 52
    }

    private var titleSize: CGFloat {
        if isCollapsed { return 15 }
        return theme.titleStyle == .compact ? 15 : 17
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 96)
                .frame(maxWidth: .infinity)

            HStack(spacing: RexSpacing.xs) {
                leadingView

                Spacer(minLength: 0)

                actionsView
            }
            .padding(.horizontal, RexSpacing.md)
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        // 未滚动时与页面融合（透明、无分隔线），滚动后才铺 `surface` 并出现分隔线。
        .background(
            RexColor.surface
                .opacity(isScrolled ? 1 : 0)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)
                .opacity(isScrolled ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: isScrolled)
    }

    @ViewBuilder
    private var actionsView: some View {
        if groupsActions, !actions.isEmpty {
            if #available(iOS 26.0, *) {
                // 与系统标签栏一致的液态玻璃胶囊，滚动前后都由材质本身分层。
                GlassEffectContainer(spacing: 0) {
                    groupedButtons
                        .glassEffect(.regular, in: Capsule(style: .continuous))
                }
            } else {
                groupedButtons
                    .background(
                        Capsule(style: .continuous)
                            .stroke(RexColor.primaryText.opacity(isScrolled ? 0.22 : 0.16), lineWidth: 1)
                    )
            }
        } else {
            ForEach(actions) { action in
                RexNavBarButton(action: action)
            }
        }
    }

    private var groupedButtons: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                RexNavBarButton(
                    action: action,
                    tint: RexColor.primaryText,
                    width: 40,
                    height: 34
                )
            }
        }
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .none:
            EmptyView()
        case .back(let action):
            Button(action: action) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .frame(width: 44, height: 44)
            .accessibilityLabel("返回")
        case .text(let text, let action):
            Button(action: action) {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(text)
        case .pill(let text, let action):
            Button(action: action) {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, RexSpacing.md)
                    .frame(height: 34)
                    .background(RexColor.surface, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(RexColor.primaryText.opacity(0.16), lineWidth: 1)
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(text)
        }
    }
}

/// 顶栏右侧的快捷操作：一个图标只做一件事，最多两个。
struct RexNavAction: Identifiable {
    let systemImage: String
    let label: String
    var isEnabled: Bool = true
    /// 是否给图标加浅底 + 描边轮廓（用于需要强调的成对操作，如放大 / 缩小）。
    var showsOutline: Bool = false
    /// 只在图标外加一圈描边，不加底色。
    var showsCircleOutline: Bool = false
    /// 有值时按钮改为下拉菜单，点击弹出这里的菜单项。
    var menu: (() -> AnyView)? = nil
    var action: () -> Void = {}

    var id: String { "\(systemImage)-\(label)" }
}

private struct RexNavBarButton: View {
    let action: RexNavAction
    var tint: Color = RexColor.brandBlue
    var width: CGFloat = 44
    var height: CGFloat = 44

    var body: some View {
        Group {
            if let menu = action.menu {
                Menu {
                    menu()
                } label: {
                    icon
                }
            } else {
                Button(action: action.action) {
                    icon
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .frame(width: width, height: height)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.35)
        .accessibilityLabel(action.label)
    }

    private var icon: some View {
        let isSmall = action.showsOutline || action.showsCircleOutline

        return Image(systemName: action.systemImage)
            .font(.system(size: isSmall ? 14 : 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: isSmall ? 26 : 36, height: isSmall ? 26 : 36)
            .background {
                if action.showsOutline {
                    Circle().fill(RexColor.field)
                }
            }
            .modifier(
                RexNavIconOutline(
                    showsOutline: action.showsOutline,
                    showsCircleOutline: action.showsCircleOutline
                )
            )
            .contentShape(Circle())
    }
}

/// 图标外轮廓：iOS 26 起用原生玻璃，低版本退回描边。
private struct RexNavIconOutline: ViewModifier {
    let showsOutline: Bool
    let showsCircleOutline: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), showsCircleOutline {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else if showsOutline {
            content.overlay(Circle().stroke(RexColor.divider, lineWidth: 1))
        } else if showsCircleOutline {
            content.overlay(
                Circle().stroke(RexColor.primaryText.opacity(0.18), lineWidth: 1)
            )
        } else {
            content
        }
    }
}

/// 滚动位置读取：放在 ScrollView 内容顶部，配合 `rexScrollTracking` 使用。
struct RexScrollOffsetReader: View {
    let space: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RexScrollOffsetKey.self,
                value: proxy.frame(in: .named(space)).minY
            )
        }
    }
}

struct RexScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// 滚动超过 8pt 时把 `isScrolled` 置为 true，驱动顶栏与底部标签栏收缩。
    @ViewBuilder
    func rexScrollTracking(_ space: String, isScrolled: Binding<Bool>) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                rexApplyScroll(offset: offset, isScrolled: isScrolled)
            }
        } else {
            coordinateSpace(name: space)
                .onPreferenceChange(RexScrollOffsetKey.self) { offset in
                    rexApplyScroll(offset: -offset, isScrolled: isScrolled)
                }
        }
    }
}

/// `offset` 统一为「向下滚动的距离」：顶部为 0，向下为正。
@MainActor
private func rexApplyScroll(offset: CGFloat, isScrolled: Binding<Bool>) {
    let scrolled = offset > 8

    guard scrolled != isScrolled.wrappedValue else { return }
    withAnimation(.easeOut(duration: 0.2)) {
        isScrolled.wrappedValue = scrolled
    }
}

/// 顶栏内搜索框：聚焦时品牌蓝描边，无阴影。
struct RexSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索"

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)

            TextField(placeholder, text: $text)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(placeholder)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(RexColor.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(height: 44)
        .background(
            RexColor.field,
            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                .stroke(
                    isFocused ? RexColor.brandBlue.opacity(0.6) : RexColor.divider,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview("品牌顶栏（影视页）") {
    VStack(spacing: 0) {
        RexTopBar(
            title: "RexHub",
            subtitle: "下午好，poilly",
            searchText: .constant("")
        ) {
            Text("在线")
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RexColor.surface, in: Capsule())
        }

        Spacer()
    }
    .background(RexColor.background)
}

#Preview("通用顶栏 · 一级页（未滚动，与页面融合）") {
    VStack(spacing: 0) {
        RexNavBar(
            title: "网盘",
            actions: [
                RexNavAction(systemImage: "arrow.clockwise", label: "刷新", action: {})
            ]
        )

        Spacer()
    }
    .background(RexColor.background)
}

#Preview("通用顶栏 · 二级页（已滚动，出现分界）") {
    VStack(spacing: 0) {
        RexNavBar(
            title: "账号设置",
            leading: .back(action: {}),
            actions: [
                RexNavAction(systemImage: "square.and.arrow.up", label: "分享", action: {}),
                RexNavAction(systemImage: "ellipsis.circle", label: "更多操作", action: {})
            ],
            isScrolled: true
        )

        Spacer()
    }
    .background(RexColor.background)
}
