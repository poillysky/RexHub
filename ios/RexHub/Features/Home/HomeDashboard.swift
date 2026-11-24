import Observation
import SwiftUI
import UIKit

// MARK: - 首页动作

/// 首页宫格与卡片的跳转意图。
enum HomeAction: Hashable {
    /// 切到某个底部标签。
    case tab(HomeTab)
    /// 推进本栈的二级页。
    case page(HomePage)
    /// 短剧源生成的站点入口。
    case drama(DramaSite)
}

/// 首页可推进本栈的二级页。
enum HomePage: Hashable {
    case panAccount
}

// MARK: - 首页状态

/// 首页轻量状态：只取 115 账号快照，供「存储空间」卡展示容量与绑定状态。
@MainActor
@Observable
final class HomeStatusModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// 网络或服务端失败；保留上一次成功的数据。
        case failed
    }

    private(set) var panAccount: PanAccount?
    private(set) var state: LoadState = .idle

    /// 回到首页时是否需要补一次：没加载过、上次失败、或 115 还没绑定时值得再试。
    var needsRefresh: Bool {
        switch state {
        case .idle: true
        case .loading: false
        case .failed: true
        case .loaded: panAccount?.bound != true
        }
    }

    func load(client: APIClient?) async {
        guard state != .loading, let client else { return }
        state = .loading

        do {
            panAccount = try await client.panAccount()
            state = .loaded
        } catch {
            // 页面切走 / 下拉刷新中断时请求会抛取消：那不是失败，回到 idle 让下次进页面重试。
            state = Task.isCancelled ? .idle : .failed
        }
    }
}

// MARK: - 背景

/// 首页背景：顶部一档更亮，向下收到页面底色。
enum HomeBackdrop {
    /// 渐变只构建一次，避免每次求解 body 都重新拼 `ShapeStyle`。
    static let style = AnyShapeStyle(
        LinearGradient(
            stops: [
                .init(color: RexColor.surface, location: 0),
                // 白只留最顶部一条：再往下立刻收到页面底色，
                // 否则白卡片、白搜索框会和背景糊成一层。
                .init(color: RexColor.background, location: 0.18),
                .init(color: RexColor.background, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    )
}

/// 顶部品牌蓝染色：铺在首屏顶部，往下淡到全透明。
///
/// 高度只占屏幕 42%，保证白卡片、白搜索框始终比背景亮一档。
struct HomeBackdropGlow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: [
                    .init(color: RexColor.brandBlue.opacity(scheme == .dark ? 0.22 : 0.14), location: 0),
                    .init(color: RexColor.brandBlue.opacity(scheme == .dark ? 0.10 : 0.055), location: 0.45),
                    .init(color: RexColor.brandBlue.opacity(0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: proxy.size.width, height: proxy.size.height * 0.42)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 顶栏

/// 首页顶栏：字母头像 + 胶囊搜索框 + 通知。
struct HomeHeaderBar: View {
    let avatarName: String
    var avatarSelection: AvatarStore.Selection = .initial
    let onOpenSearch: () -> Void
    let onAvatar: () -> Void
    let onNotifications: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            avatarButton

            // 两侧图标视觉宽度不同，按视觉边缘配平，胶囊才落在正中间。
            searchField
                .padding(.leading, 11)
                .padding(.trailing, 8)

            iconButton(symbol: "bell", label: "通知", action: onNotifications)
        }
    }

    private var avatarButton: some View {
        Button {
            RexHaptics.tap()
            onAvatar()
        } label: {
            RexAvatar(name: avatarName, size: 40, selection: avatarSelection)
                .shadow(color: Color.black.opacity(0.06), radius: 5, x: 0, y: 2)
                // 头像视觉 40，命中区补到 44。
                .frame(width: RexLayout.minTouch, height: RexLayout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("账号与设置")
    }

    private func iconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: RexLayout.minTouch, height: RexLayout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private var searchField: some View {
        Button {
            RexHaptics.tap()
            onOpenSearch()
        } label: {
            HStack(spacing: RexSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)

                Text("搜索")
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.tertiaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .homeSearchCapsule()
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("搜索影视或番号")
    }
}

/// 首页风格搜索胶囊：亮面卡片 + 轻阴影，首页入口与搜索列表页共用。
struct HomeSearchCapsuleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minHeight: 46)
            .background {
                Capsule(style: .continuous)
                    .fill(RexColor.surface)
                    .shadow(color: Color.black.opacity(0.07), radius: 7, x: 0, y: 3)
            }
    }
}

extension View {
    func homeSearchCapsule() -> some View {
        modifier(HomeSearchCapsuleStyle())
    }
}

// MARK: - 首页

/// 参考稿样式首页：顶栏 + 设备头 + 功能宫格 + 资源监控 + 存储空间。
struct HomeDashboardView: View {
    let name: String
    let isAdmin: Bool
    let isOffline: Bool
    var reselectToken: Int = 0
    /// 点头像滑出侧栏抽屉。
    let onOpenDrawer: () -> Void
    let onAction: (HomeAction) -> Void

    @Environment(\.apiClient) private var apiClient

    private let appsStore = HomeAppsStore.shared
    private let avatars = AvatarStore.shared

    @State private var status = HomeStatusModel()
    @State private var page: HomePage?
    @State private var dramaSite: DramaSite?
    @State private var isSearchOpen = false
    @State private var allAppsOpen = false
    @State private var notificationsOpen = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.lg) {
                    HomeServerSummary(
                        isAdmin: isAdmin,
                        isOffline: isOffline,
                        serverText: ServerConfig.savedText,
                        onOpen: onOpenDrawer
                    )

                    HomeFeatureGrid(
                        apps: appsStore.homeApps,
                        onAction: handle,
                        onMore: { allAppsOpen = true }
                    )
                    .padding(.top, RexSpacing.xs)

                    HomeResourceMonitorCard()
                        .padding(.top, RexSpacing.sm)

                    storageCard
                        .padding(.top, RexSpacing.sm)
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.sm)
                .padding(.bottom, RexSpacing.xxxl)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .id("homeTop")
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            // 重复点「首页」标签：回到顶部并补一次状态。
            .onChange(of: reselectToken) { _, _ in
                withAnimation(RexMotion.standard) {
                    proxy.scrollTo("homeTop", anchor: .top)
                }
                Task { await status.load(client: apiClient) }
            }
        }
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(HomeBackdrop.style)
                HomeBackdropGlow()
            }
            .ignoresSafeArea()
        }
        // 顶栏钉在安全区上：滚动时留在原位，内容自动避开。
        .safeAreaInset(edge: .top, spacing: 0) {
            HomeHeaderBar(
                avatarName: name,
                avatarSelection: avatars.selection,
                onOpenSearch: { isSearchOpen = true },
                onAvatar: onOpenDrawer,
                onNotifications: { notificationsOpen = true }
            )
            .padding(.horizontal, RexSpacing.xl)
            .padding(.top, RexSpacing.sm)
            .padding(.bottom, RexSpacing.lg)
            .frame(maxWidth: .infinity)
            .background { HomeHeaderBackdrop() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await status.load(client: apiClient)
            await appsStore.reload(client: apiClient)
        }
        .navigationDestination(item: $page) { page in
            Group {
                switch page {
                case .panAccount:
                    PanAccountView(isAdmin: isAdmin)
                }
            }
            .rexPushedScreen()
        }
        .navigationDestination(item: $dramaSite) { site in
            DramaSiteView(site: site)
        }
        .navigationDestination(isPresented: $isSearchOpen) {
            // 顶栏沿用首页同款搜索框，下方为搜索结果列表。
            ScopeSearchView(
                keyword: "",
                scope: ScopeSelectionStore.load(),
                editableHeader: true
            )
        }
        .sheet(isPresented: $notificationsOpen) {
            HomeNotificationsView()
                .rexSheetStyle(detents: [.large])
        }
        .fullScreenCover(isPresented: $allAppsOpen) {
            AllAppsView(onAction: handle)
        }
        .task {
            await status.load(client: apiClient)
        }
        .task {
            await appsStore.reload(client: apiClient)
        }
    }

    // MARK: 卡片

    /// 存储卡状态：有数据就先展示（刷新失败也不退回占位）。
    private var storageStatus: HomeStorageStatus {
        if let account = status.panAccount {
            guard account.bound else { return .unbound }
            if let total = account.total, total > 0, let used = account.used {
                return .ready(total: total, used: used)
            }
            return status.state == .loading ? .loading : .unavailable
        }

        switch status.state {
        case .failed:
            return .failed
        case .idle, .loading, .loaded:
            return .loading
        }
    }

    private var storageCard: some View {
        HomeStorageCard(
            storage: storageStatus,
            accountName: status.panAccount?.username ?? "",
            isVIP: status.panAccount?.vipActive == true || status.panAccount?.vipForever == true,
            onOpenLibrary: { onAction(.tab(.drive)) },
            onRetry: { Task { await status.load(client: apiClient) } }
        )
    }

    // MARK: 动作

    private func handle(_ action: HomeAction) {
        switch action {
        case let .tab(tab):
            onAction(.tab(tab))
        case let .page(page):
            self.page = page
        case let .drama(site):
            dramaSite = site
        }
    }
}

// MARK: - 顶栏底色

/// 顶栏底色：把首页那两层背景按整屏尺寸再画一遍，只露出最上面一段。
///
/// 顶栏必须不透明（滚动内容会从后面经过），所以不能靠透明去看真背景；
/// 只要尺寸取自同一个整屏高度，边界那一行就落在页面背景的同一个像素上。
private struct HomeHeaderBackdrop: View {
    private var windowHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .bounds.height ?? 0
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .top) {
                Rectangle().fill(HomeBackdrop.style)
                HomeBackdropGlow()
            }
            .frame(width: proxy.size.width, height: max(windowHeight, height), alignment: .top)
            .frame(width: proxy.size.width, height: height, alignment: .top)
            .clipped()
        }
        .ignoresSafeArea(edges: .top)
        // `clipped()` 只裁视觉、不裁命中区域，不关掉命中测试会盖住下面的 ScrollView。
        .allowsHitTesting(false)
    }
}

// MARK: - 通知

/// 系统通知占位页：接入通知接口前只给空状态。
private struct HomeNotificationsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "通知",
                leading: .back(action: { dismiss() }),
                isScrolled: true
            )

            Spacer(minLength: 0)

            RexStateCard(symbol: "bell", title: "暂无通知", tone: .neutral)
                .padding(.horizontal, RexSpacing.xl)
                .frame(maxWidth: RexLayout.contentMaxWidth)

            Spacer(minLength: 0)
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}
