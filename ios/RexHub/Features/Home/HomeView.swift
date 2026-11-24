import SwiftUI
import UIKit

struct HomeView: View {
    let session: AuthSession
    var isOffline: Bool = false
    var onLogout: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTab = 0
    @State private var reselectToken = 0
    /// iPad 侧栏下已访问过的标签：只创建访问过的页面，之后常驻保留导航栈。
    @State private var visitedTabs: Set<Int> = [HomeTab.home.rawValue]

    /// 头像抽屉的开合进度：常驻挂载，只推进度做转场。
    @State private var drawerMotion = DrawerMotion()
    /// 抽屉里选中的设置页，挂在外层导航栈上压入。
    @State private var drawerPage: HomeDrawerPage?

    private let theme = RexThemeStore.shared

    /// iPad 常规宽度改用侧栏，与底部 Tab 二选一。
    private var usesSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    var body: some View {
        // iPhone 上标签栏必须在导航栈之外：TabView 套进 NavigationStack 后，
        // 标签页内的二级页压栈会把整个标签栏一起盖掉。
        // iPad 没有标签栏，保留外层导航栈，设置页整页压入。
        Group {
            if usesSidebar {
                NavigationStack {
                    splitLayout
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(item: $drawerPage) { page in
                            drawerDestination(page)
                        }
                }
            } else {
                tabLayout
                    .fullScreenCover(item: $drawerPage) { page in
                        NavigationStack {
                            drawerDestination(page)
                                .toolbar(.hidden, for: .navigationBar)
                        }
                    }
            }
        }
        .overlay {
            HomeDrawerOverlay(
                motion: drawerMotion,
                name: session.user.name,
                isAdmin: session.user.isAdmin,
                onSelect: { drawerPage = $0 },
                onLogout: onLogout
            )
        }
    }

    // MARK: - 抽屉

    private func openDrawer() {
        withAnimation(reduceMotion ? nil : RexMotion.spring) {
            drawerMotion.drag = 0
            drawerMotion.progress = 1
        }
    }

    @ViewBuilder
    private func drawerDestination(_ page: HomeDrawerPage) -> some View {
        switch page {
        case .account:
            AccountSettingsView(session: session, onLogout: onLogout)
        case .services:
            ServiceSettingsHubView(isAdmin: session.user.isAdmin)
        case .aiModels:
            AISettingsView(isAdmin: session.user.isAdmin)
        case .appearance:
            AppearanceSettingsView()
        case .fileList:
            FileListSettingsView()
        case .network:
            NetworkSettingsView(isAdmin: session.user.isAdmin)
        case .cache:
            CacheManagementView()
        case .videoPlayer:
            VideoPlayerSettingsView()
        case .gestures:
            GestureSettingsView()
        case .subtitles:
            SubtitleSettingsView()
        case .music:
            MusicPlayerSettingsView()
        }
    }

    // MARK: - 底部标签栏

    /// 用系统 TabView：液态玻璃、安全区、无障碍全部原生；
    /// iOS 26 起由 `tabBarMinimizeBehavior` 在滑动时收缩成左侧小胶囊。
    private var tabLayout: some View {
        tabs
            .tint(RexColor.brandBlue)
            .modifier(TabBarMinimize(isEnabled: theme.collapseNavOnScroll))
            .background(
                TabBarReselectObserver { index in
                    guard index == selectedTab else { return }
                    reselectToken += 1
                }
                .frame(width: 0, height: 0)
            )
            .onAppear { syncTabBarTitles() }
            .onChange(of: theme.showNavTitle) { _, _ in syncTabBarTitles() }
            .onChange(of: selectedTab) { _, _ in syncTabBarTitles() }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab(value: 0) {
                    homeStack
                } label: {
                    tabLabel(.home)
                }

                Tab(value: 1) {
                    postersStack
                } label: {
                    tabLabel(.posters)
                }

                Tab(value: 2) {
                    resourcesStack
                } label: {
                    tabLabel(.resources)
                }

                Tab(value: 3) {
                    driveStack
                } label: {
                    tabLabel(.drive)
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                homeStack
                    .tabItem { tabLabel(.home) }
                    .tag(0)

                postersStack
                    .tabItem { tabLabel(.posters) }
                    .tag(1)

                resourcesStack
                    .tabItem { tabLabel(.resources) }
                    .tag(2)

                driveStack
                    .tabItem { tabLabel(.drive) }
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

    private var homeStack: some View {
        NavigationStack {
            HomeDashboardView(
                name: session.user.name,
                isAdmin: session.user.isAdmin,
                isOffline: isOffline,
                reselectToken: reselectToken,
                onOpenDrawer: openDrawer,
                onAction: handleHomeAction
            )
        }
    }

    /// 首页只往外抛「切标签」，二级页与弹窗都由首页自己处理。
    private func handleHomeAction(_ action: HomeAction) {
        guard case let .tab(tab) = action else { return }

        if selectedTab == tab.rawValue {
            reselectToken += 1
        } else {
            selectedTab = tab.rawValue
        }
    }

    private var postersStack: some View {
        PosterWallHomeView(reselectToken: reselectToken)
    }

    private var resourcesStack: some View {
        LibraryView(reselectToken: reselectToken)
    }

    private var driveStack: some View {
        NavigationStack {
            DriveView(reselectToken: reselectToken, isAdmin: session.user.isAdmin)
        }
    }

    // MARK: - iPad 侧栏

    private var splitLayout: some View {
        ZStack {
            RexPageBackground()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 288)
                    .background(.ultraThinMaterial)

                Rectangle()
                    .fill(RexColor.divider)
                    .frame(width: 1)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(spacing: RexSpacing.md) {
                RexLogoMark(size: 36, hasShadow: false)

                Text("RexHub")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RexSpacing.lg)
            .padding(.top, RexSpacing.xl)
            .padding(.bottom, RexSpacing.xl)

            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1)
                .padding(.horizontal, RexSpacing.lg)
                .padding(.bottom, RexSpacing.md)

            Text("浏览")
                .font(RexFont.section)
                .foregroundStyle(RexColor.tertiaryText)
                .padding(.horizontal, RexSpacing.lg)

            ForEach(HomeTab.allCases) { tab in
                Button {
                    RexHaptics.selection()
                    visitedTabs.insert(tab.rawValue)
                    if selectedTab == tab.rawValue {
                        reselectToken += 1
                    } else {
                        withAnimation(RexMotion.spring) {
                            selectedTab = tab.rawValue
                        }
                    }
                } label: {
                    HStack(spacing: RexSpacing.md) {
                        Image(systemName: selectedTab == tab.rawValue ? tab.selectedSymbol : tab.symbol)
                            .font(.system(.headline, weight: .medium))
                            .foregroundStyle(selectedTab == tab.rawValue ? RexColor.brandBlue : RexColor.secondaryText)
                            .frame(width: 26)
                            .contentTransition(.symbolEffect(.replace))

                        Text(tab.title)
                            .font(.system(.body, weight: selectedTab == tab.rawValue ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab.rawValue ? RexColor.primaryText : RexColor.secondaryText)

                        Spacer(minLength: 0)

                        if selectedTab == tab.rawValue {
                            Capsule()
                                .fill(RexColor.brandBlue)
                                .frame(width: 3, height: 18)
                                .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .padding(.horizontal, RexSpacing.md)
                    .frame(minHeight: 48)
                    .background(
                        selectedTab == tab.rawValue ? RexColor.brandBlue.opacity(0.11) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(RexRowButtonStyle())
                .accessibilityAddTraits(selectedTab == tab.rawValue ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, RexSpacing.md)
        .padding(.bottom, RexSpacing.lg)
        .animation(RexMotion.spring, value: selectedTab)
    }

    /// 四个页面的导航栈常驻，仅切换可见性：
    /// 这样在 iPad 上切标签不会重建 NavigationStack，二级页与滚动位置都保留。
    private var detail: some View {
        ZStack {
            ForEach(HomeTab.allCases) { tab in
                if visitedTabs.contains(tab.rawValue) {
                    page(tab, stack: stack(for: tab))
                }
            }
        }
    }

    @ViewBuilder
    private func stack(for tab: HomeTab) -> some View {
        switch tab {
        case .home: homeStack
        case .posters: postersStack
        case .resources: resourcesStack
        case .drive: driveStack
        }
    }

    private func page<Content: View>(_ tab: HomeTab, stack: Content) -> some View {
        let isActive = selectedTab == tab.rawValue
        return stack
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

/// 侧栏与底部 Tab 共用的四项定义。
enum HomeTab: Int, CaseIterable, Identifiable {
    case home
    case posters
    case resources
    case drive

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: "首页"
        case .posters: "海报墙"
        case .resources: "资源库"
        case .drive: "115网盘"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .posters: "square.grid.2x2"
        case .resources: "rectangle.stack"
        case .drive: "externaldrive"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .home: "house.fill"
        case .posters: "square.grid.2x2.fill"
        case .resources: "rectangle.stack.fill"
        case .drive: "externaldrive.fill"
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

extension UIView {
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

#Preview {
    HomeView(
        session: AuthSession(
            token: "preview",
            user: .init(id: "1", name: "poilly")
        ),
        onLogout: {}
    )
}
