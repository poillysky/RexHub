import SwiftUI

/// 全局顶栏：固定在安全区下方，不随页面滚动。
/// 单行结构固定为「左品牌标 + 中搜索框 + 右操作」，页面滚动后铺 `surface` 底色 + 1px 分隔线。
struct RexTopBar<Trailing: View>: View {
    var searchText: Binding<String>?
    var searchPlaceholder: String
    /// 传入时顶栏中间改为一句话标题（不显示搜索框）。
    var title: String?
    var isCollapsed: Bool
    /// 传入时搜索框只做入口：点击执行该动作，不在此处输入。
    var onSearchTap: (() -> Void)?
    /// 是否在左侧显示品牌标；需要自定义左侧内容时关掉。
    var showsLogo: Bool
    /// 自定义左侧内容（如头像），优先于品牌标显示。
    var leading: AnyView?
    private let trailing: Trailing

    @Environment(\.displayScale) private var displayScale

    private let theme = RexThemeStore.shared

    /// 页面滚动后铺底色并略微收拢。
    private var collapsed: Bool { isCollapsed }

    /// 只有在没有搜索框时，标题才作为顶栏中间的一行文字显示。
    private var showsTitle: Bool {
        title != nil && onSearchTap == nil && searchText == nil
    }

    /// 与 `RexNavBar` 保持同一套标题字号。
    private var titleFont: Font {
        if collapsed || theme.titleStyle == .compact {
            return .system(.subheadline, weight: .semibold)
        }
        return .system(.headline, weight: .semibold)
    }

    init(
        searchText: Binding<String>? = nil,
        searchPlaceholder: String = "搜索",
        title: String? = nil,
        isCollapsed: Bool = false,
        onSearchTap: (() -> Void)? = nil,
        showsLogo: Bool = true,
        leading: AnyView? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.title = title
        self.isCollapsed = isCollapsed
        self.onSearchTap = onSearchTap
        self.showsLogo = showsLogo
        self.leading = leading
        self.trailing = trailing()
    }

    /// 带自定义左侧内容（头像等）的顶栏，避免调用处包一层 `AnyView`。
    init<Leading: View>(
        title: String? = nil,
        isCollapsed: Bool = false,
        showsLogo: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.searchText = nil
        self.searchPlaceholder = "搜索"
        self.title = title
        self.isCollapsed = isCollapsed
        self.onSearchTap = nil
        self.showsLogo = showsLogo
        self.leading = AnyView(leading())
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: RexSpacing.md) {
            if let leading {
                leading
            } else if showsLogo {
                RexLogoMark(size: collapsed ? 28 : 32, hasShadow: false)
                    .animation(.easeOut(duration: 0.2), value: collapsed)
            }

            if let onSearchTap {
                Button(action: onSearchTap) {
                    RexSearchFieldPlaceholder(placeholder: searchPlaceholder)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
            } else if let searchText {
                RexSearchField(text: searchText, placeholder: searchPlaceholder)
            } else {
                Spacer(minLength: 0)
            }

            trailing
        }
        .padding(.horizontal, RexSpacing.xl)
        .frame(height: collapsed ? 52 : 56)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .overlay {
            if showsTitle, let title {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 96)
                    .contentTransition(.opacity)
            }
        }
        // 滚动后改用半透明材质，保留内容在顶栏下方透出的层级感，接近原生大标题导航栏。
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
                .opacity(collapsed ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)
                .opacity(collapsed ? 1 : 0)
        }
        .animation(RexMotion.standard, value: collapsed)
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

    private var titleFont: Font {
        if isCollapsed || theme.titleStyle == .compact {
            return .system(.subheadline, weight: .semibold)
        }
        return .system(.headline, weight: .semibold)
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(titleFont)
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
        // 未滚动时与页面融合（透明、无分隔线），滚动后改用半透明材质并出现发丝分隔线。
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
                .opacity(isScrolled ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)
                .opacity(isScrolled ? 1 : 0)
        }
        .animation(RexMotion.standard, value: isScrolled)
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
                    .frame(height: 36)
                    .background(RexColor.surface, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(RexColor.cardBorder, lineWidth: 1)
                    )
                    .contentShape(Capsule(style: .continuous))
                    .frame(minHeight: RexLayout.minTouch)
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

/// 搜索框的静态外观：供「点击跳转到搜索页」的入口复用，保持与输入态一致。
private struct RexSearchFieldPlaceholder: View {
    var placeholder: String

    var body: some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)

            Text(placeholder)
                .font(RexFont.body)
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, 4)
        .frame(minHeight: 46)
        .background(
            RexColor.field,
            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                .strokeBorder(RexColor.fieldBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous))
    }
}

/// 顶栏内搜索框：聚焦时品牌蓝描边，无阴影。
struct RexSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索"
    /// 外部要求聚焦时递增，用于「从其他页面跳转过来直接弹出键盘」。
    var focusToken: Int = 0
    var onSubmit: (() -> Void)?

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
                .onSubmit { onSubmit?() }
                .accessibilityLabel(placeholder)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(RexColor.secondaryText)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, 4)
        .frame(minHeight: 46)
        .background(
            RexColor.field,
            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                .strokeBorder(
                    isFocused ? RexColor.brandBlue.opacity(0.65) : RexColor.fieldBorder,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .shadow(
            color: RexColor.brandBlue.opacity(isFocused ? 0.12 : 0),
            radius: 10,
            y: 2
        )
        .animation(RexMotion.quick, value: isFocused)
        .onChange(of: focusToken) { _, _ in isFocused = true }
    }
}

#Preview("品牌顶栏（影视页）") {
    VStack(spacing: 0) {
        RexTopBar(
            searchText: .constant(""),
            searchPlaceholder: "搜索电影、剧集"
        ) {
            RexAvatar(name: "poilly", size: 36)
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
