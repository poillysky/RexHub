import SwiftUI
import UIKit

struct HomeView: View {
    let session: AuthSession
    var isOffline: Bool = false
    var onLogout: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTab = 0
    @State private var reselectToken = 0

    private let theme = RexThemeStore.shared

    /// iPad 常规宽度改用侧栏，与底部 Tab 二选一。
    private var usesSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesSidebar {
                splitLayout
            } else {
                tabLayout
            }
        }
    }

    // MARK: - 底部标签栏

    /// 用系统 TabView：液态玻璃、安全区、无障碍全部原生；
    /// iOS 26 起由 `tabBarMinimizeBehavior` 在滑动时收缩成左侧小胶囊。
    private var tabLayout: some View {
        tabs
            .tint(RexColor.brandBlue)
            .modifier(TabBarMinimize(isEnabled: theme.collapseNavOnScroll))
            .onAppear { syncTabBarTitles() }
            .onChange(of: theme.showNavTitle) { _, _ in syncTabBarTitles() }
            .onChange(of: selectedTab) { _, _ in syncTabBarTitles() }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab(value: 0) {
                    libraryStack
                } label: {
                    tabLabel(.library)
                }

                Tab(value: 1) {
                    shortsStack
                } label: {
                    tabLabel(.shorts)
                }

                Tab(value: 2) {
                    driveStack
                } label: {
                    tabLabel(.drive)
                }

                Tab(value: 3) {
                    moreStack
                } label: {
                    tabLabel(.more)
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                libraryStack
                    .tabItem { tabLabel(.library) }
                    .tag(0)

                shortsStack
                    .tabItem { tabLabel(.shorts) }
                    .tag(1)

                driveStack
                    .tabItem { tabLabel(.drive) }
                    .tag(2)

                moreStack
                    .tabItem { tabLabel(.more) }
                    .tag(3)
            }
        }
    }

    /// 系统标签项只在创建时读取标题，之后的显隐不会重绘；
    /// 因此直接改 `UITabBarItem.title`，既立即生效又不用重建 TabView（否则导航栈会被弹回根页）。
    private func syncTabBarTitles(attempts: Int = 6) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))

            guard let tabBar = rexTabBar() else {
                if attempts > 1 { syncTabBarTitles(attempts: attempts - 1) }
                return
            }

            for (index, item) in (tabBar.items ?? []).enumerated() {
                guard let tab = HomeTab(rawValue: index) else { continue }
                let title = theme.showNavTitle ? tab.title : nil
                if item.title != title {
                    item.title = title
                }
                item.accessibilityLabel = tab.title
            }
        }
    }

    @MainActor
    private func rexTabBar() -> UITabBar? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rexFirstDescendant(of: UITabBar.self)
    }

    /// 「显示导航栏名称」关闭时只保留图标。
    private func tabLabel(_ tab: HomeTab) -> some View {
        Label(tab.title, systemImage: tab.symbol)
    }

    private var libraryStack: some View {
        NavigationStack {
            LibraryHomeView(
                name: session.user.name,
                isOffline: isOffline,
                reselectToken: reselectToken,
                onOpenMore: { selectedTab = 3 }
            )
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var shortsStack: some View {
        NavigationStack {
            PlaceholderView(
                title: "短剧",
                icon: "rectangle.stack",
                message: "短剧内容正在接入，敬请期待"
            )
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var driveStack: some View {
        NavigationStack {
            DriveView(reselectToken: reselectToken)
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var moreStack: some View {
        NavigationStack {
            MoreView(
                session: session,
                onLogout: onLogout,
                reselectToken: reselectToken,
                isOffline: isOffline
            )
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - iPad 侧栏

    private var splitLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
                .background(RexColor.surface.ignoresSafeArea())

            Rectangle()
                .fill(RexColor.divider)
                .frame(width: 1)
                .ignoresSafeArea()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RexColor.background.ignoresSafeArea())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(spacing: RexSpacing.md) {
                RexLogoMark(size: 32, hasShadow: false)

                Text("RexHub")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RexSpacing.md)
            .padding(.top, RexSpacing.lg)
            .padding(.bottom, RexSpacing.md)

            ForEach(HomeTab.allCases) { tab in
                Button {
                    if selectedTab == tab.rawValue {
                        reselectToken += 1
                    } else {
                        selectedTab = tab.rawValue
                    }
                } label: {
                    HStack(spacing: RexSpacing.md) {
                        Image(systemName: selectedTab == tab.rawValue ? tab.selectedSymbol : tab.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 24)

                        Text(tab.title)
                            .font(.system(size: 16, weight: selectedTab == tab.rawValue ? .semibold : .regular))

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selectedTab == tab.rawValue ? RexColor.brandBlue : RexColor.primaryText)
                    .padding(.horizontal, RexSpacing.md)
                    .frame(height: 44)
                    .background(
                        selectedTab == tab.rawValue ? RexColor.brandBlue.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab.rawValue ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, RexSpacing.md)
        .padding(.bottom, RexSpacing.lg)
    }

    @ViewBuilder
    private var detail: some View {
        switch HomeTab(rawValue: selectedTab) ?? .library {
        case .library:
            NavigationStack {
                LibraryHomeView(
                    name: session.user.name,
                    isOffline: isOffline,
                    reselectToken: reselectToken,
                    onOpenMore: { selectedTab = HomeTab.more.rawValue }
                )
                .toolbar(.hidden, for: .navigationBar)
            }

        case .shorts:
            NavigationStack {
                PlaceholderView(
                    title: "短剧",
                    icon: "rectangle.stack",
                    message: "短剧内容正在接入，敬请期待"
                )
                .toolbar(.hidden, for: .navigationBar)
            }

        case .drive:
            NavigationStack {
                DriveView(reselectToken: reselectToken)
                    .toolbar(.hidden, for: .navigationBar)
            }

        case .more:
            NavigationStack {
                MoreView(
                    session: session,
                    onLogout: onLogout,
                    reselectToken: reselectToken,
                    isOffline: isOffline
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

/// 侧栏与底部 Tab 共用的四项定义。
private enum HomeTab: Int, CaseIterable, Identifiable {
    case library
    case shorts
    case drive
    case more

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .library: "影视"
        case .shorts: "短剧"
        case .drive: "网盘"
        case .more: "更多"
        }
    }

    var symbol: String {
        switch self {
        case .library: "play.rectangle"
        case .shorts: "rectangle.stack"
        case .drive: "externaldrive"
        case .more: "ellipsis.circle"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .library: "play.rectangle.fill"
        case .shorts: "rectangle.stack.fill"
        case .drive: "externaldrive.fill"
        case .more: "ellipsis.circle.fill"
        }
    }
}

/// 滑动时收缩底部栏：iOS 26 起用系统原生最小化行为（收缩为左侧小胶囊）。
private struct TabBarMinimize: ViewModifier {
    var isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(isEnabled ? .onScrollDown : .never)
        } else {
            content
        }
    }
}

private extension UIView {
    /// 在子视图树中查找第一个指定类型的视图，用于定位系统底部标签栏。
    func rexFirstDescendant<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.rexFirstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}

private struct LibraryHomeView: View {
    let name: String
    let isOffline: Bool
    let reselectToken: Int
    var onOpenMore: () -> Void

    @State private var searchText = ""
    @State private var isScrolled = false
    @State private var avatars = AvatarStore.shared

    private let maxContentWidth: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                RexTopBar(
                    title: "RexHub",
                    subtitle: greetingText,
                    searchText: $searchText,
                    searchPlaceholder: "搜索电影、剧集",
                    isCollapsed: isScrolled,
                    onSearchTap: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("homeTop", anchor: .top)
                        }
                    }
                ) {
                    statusPill

                    Button(action: onOpenMore) {
                        RexAvatar(name: name, size: 36, selection: avatars.selection)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("打开更多")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: RexSpacing.xxl) {
                        librarySection
                            .id("homeTop")

                        serverSection
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: maxContentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .rexScrollTracking("homeScroll", isScrolled: $isScrolled)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: reselectToken) { _, _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("homeTop", anchor: .top)
                    }
                }
            }
        }
        .background(RexColor.background.ignoresSafeArea())
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOffline ? RexColor.warning : RexColor.success)
                .frame(width: 8, height: 8)

            Text(isOffline ? "未连接" : "在线")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(RexColor.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RexColor.surface, in: Capsule())
        .overlay(Capsule().stroke(RexColor.divider, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOffline ? "服务端未连接" : "服务端在线")
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<11: greeting = "早上好"
        case 11..<13: greeting = "中午好"
        case 13..<18: greeting = "下午好"
        case 18..<23: greeting = "晚上好"
        default: greeting = "夜深了"
        }
        return name.isEmpty ? greeting : "\(greeting)，\(name)"
    }

    // MARK: - 首页栏目

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            HStack(spacing: RexSpacing.sm) {
                Text("首页栏目")
                    .font(RexFont.title3)
                    .foregroundStyle(RexColor.primaryText)

                Spacer()

                Button(action: onOpenMore) {
                    Text("管理")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            emptyLibraryCard
        }
    }

    private var emptyLibraryCard: some View {
        VStack(spacing: RexSpacing.lg) {
            Image(systemName: "film.stack")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(RexColor.brandBlue)
                .frame(width: 64, height: 64)
                .background(
                    RexColor.brandBlue.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                )

            VStack(spacing: RexSpacing.xs) {
                Text("暂无栏目")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)

                Text("首页栏目正在接入，配置完成后电影与剧集会显示在这里")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Button(action: onOpenMore) {
                Text("去配置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RexColor.onBrand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHint("前往更多配置首页栏目")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxxl)
        .padding(.horizontal, RexSpacing.xl)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .stroke(RexColor.divider, lineWidth: 1)
        )
    }

    // MARK: - 服务端

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text("服务端")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)
                .padding(.horizontal, RexSpacing.xs)

            Button(action: onOpenMore) {
                HStack(spacing: RexSpacing.md) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 16))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(width: 36, height: 36)
                        .background(
                            RexColor.brandBlue.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前连接")
                            .font(.system(size: 15))
                            .foregroundStyle(RexColor.primaryText)

                        Text(serverAddress)
                            .font(.system(size: 13))
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: RexSpacing.sm)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RexColor.secondaryText.opacity(0.7))
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(height: 60)
                .background(
                    RexColor.surface,
                    in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                        .stroke(RexColor.divider, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("当前服务端 \(serverAddress)，前往更多")
        }
    }

    private var serverAddress: String {
        ServerConfig.baseURL?.absoluteString ?? "未设置"
    }
}

private struct PlaceholderView: View {
    let title: String
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(title: title)

            VStack(spacing: RexSpacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(width: 64, height: 64)
                    .background(
                        RexColor.brandBlue.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                    )

                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(RexColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RexSpacing.xxxl)
            .padding(.horizontal, RexSpacing.xl)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .stroke(RexColor.divider, lineWidth: 1)
            )
            .padding(.horizontal, RexSpacing.xl)
            .padding(.top, RexSpacing.md)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .background(RexColor.background.ignoresSafeArea())
    }
}

#Preview {
    HomeView(
        session: AuthSession(
            token: "preview",
            user: .init(id: "1", name: "poilly")
        ),
        onLogout: {}
    )
}
