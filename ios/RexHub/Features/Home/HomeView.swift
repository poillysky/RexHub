import SwiftUI
import UIKit

struct HomeView: View {
    let session: AuthSession
    var isOffline: Bool = false
    var onLogout: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTab = 0
    @State private var reselectToken = 0
    /// 递增后搜索页会自动聚焦输入框。
    @State private var searchFocusToken = 0

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
                    searchStack
                } label: {
                    tabLabel(.search)
                }

                Tab(value: 1) {
                    libraryStack
                } label: {
                    tabLabel(.library)
                }

                Tab(value: 2) {
                    makersStack
                } label: {
                    tabLabel(.makers)
                }

                Tab(value: 3) {
                    dramaStack
                } label: {
                    tabLabel(.drama)
                }

                Tab(value: 4) {
                    moreStack
                } label: {
                    tabLabel(.more)
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                searchStack
                    .tabItem { tabLabel(.search) }
                    .tag(0)

                libraryStack
                    .tabItem { tabLabel(.library) }
                    .tag(1)

                makersStack
                    .tabItem { tabLabel(.makers) }
                    .tag(2)

                dramaStack
                    .tabItem { tabLabel(.drama) }
                    .tag(3)

                moreStack
                    .tabItem { tabLabel(.more) }
                    .tag(4)
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

    private var searchStack: some View {
        NavigationStack {
            SearchHomeView(
                focusToken: searchFocusToken,
                name: session.user.name,
                onOpenMore: { selectedTab = HomeTab.more.rawValue },
                isAdmin: session.user.isAdmin
            )
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var libraryStack: some View {
        MoviePilotHomeView()
    }

    private var makersStack: some View {
        MakerHomeView()
    }

    /// 影视页顶栏搜索框：切到搜索页并聚焦输入框。
    private func openSearch() {
        searchFocusToken += 1
        selectedTab = HomeTab.search.rawValue
    }

    private var dramaStack: some View {
        DramaHomeView()
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
                            .font(.system(size: 18, weight: .medium))
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

    @ViewBuilder
    private var detail: some View {
        switch HomeTab(rawValue: selectedTab) ?? .search {
        case .search:
            NavigationStack {
                SearchHomeView(
                    focusToken: searchFocusToken,
                    name: session.user.name,
                    onOpenMore: { selectedTab = HomeTab.more.rawValue },
                    isAdmin: session.user.isAdmin
                )
                .toolbar(.hidden, for: .navigationBar)
            }

        case .library:
            MoviePilotHomeView()

        case .makers:
            MakerHomeView()

        case .drama:
            DramaHomeView()

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

/// 侧栏与底部 Tab 共用的五项定义。
private enum HomeTab: Int, CaseIterable, Identifiable {
    case search
    case library
    case makers
    case drama
    case more

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .search: "搜索"
        case .library: "影视"
        case .makers: "片商"
        case .drama: "短剧"
        case .more: "更多"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .library: "play.rectangle"
        case .makers: "rectangle.stack"
        case .drama: "popcorn"
        case .more: "ellipsis.circle"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .library: "play.rectangle.fill"
        case .makers: "rectangle.stack.fill"
        case .drama: "popcorn.fill"
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

#Preview {
    HomeView(
        session: AuthSession(
            token: "preview",
            user: .init(id: "1", name: "poilly")
        ),
        onLogout: {}
    )
}
