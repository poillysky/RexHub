import SwiftUI
import UIKit

enum RexColor {
    @MainActor static var brandBlue: Color { RexThemeStore.shared.brandColor.color }
    @MainActor static var brandBlueSoft: Color { RexThemeStore.shared.brandColor.softColor }

    static let lightBlue = Color(hex: 0xE6F0FF)

    static let background = dynamic(light: 0xF2F5FA, dark: 0x0E1116)
    /// 卡片弹窗底色：比页面背景更淡，避免顶部把手区和卡片间隙显得突兀。
    static let sheetBackground = dynamic(light: 0xF7F9FC, dark: 0x131820)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x171B22)
    /// 浮起层：用于需要与普通卡片拉开层级的卡片、弹层内卡片。
    static let elevatedSurface = dynamic(light: 0xFFFFFF, dark: 0x1D232C)
    static let field = dynamic(light: 0xF2F5FA, dark: 0x1C222B)
    /// 列表选中态底色，比页面背景深一档，避免和背景混在一起。
    static let selection = dynamic(light: 0xE1E7F0, dark: 0x262E3A)
    static let primaryText = dynamic(light: 0x0F172A, dark: 0xF2F5FA)
    /// 次级文字：浅色模式保证 4.5:1 以上对比度，深色模式自动提亮。
    static let secondaryText = dynamic(light: 0x5F6775, dark: 0x9CA5B4)
    /// 三级文字：用于图标、辅助说明等弱化信息。
    static let tertiaryText = dynamic(light: 0x98A0AD, dark: 0x6E7887)
    /// 卡片描边：浅色模式用细微冷灰，深色模式用一档亮面，避免卡片边界消失。
    static let cardBorder = dynamic(light: 0xE1E7F0, dark: 0x2B3340)
    static let fieldBorder = dynamic(light: 0xE4E9F1, dark: 0x2C3542)
    static let divider = dynamic(light: 0xE5E7EB, dark: 0x2A3038)
    /// 浮层遮罩与媒体控件底色。
    static let scrim = Color.black.opacity(0.55)

    static let success = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)
    static let error = Color(hex: 0xEF4444)
    static let info = Color(hex: 0x0A84FF)

    /// 品牌色 / 播放器黑底上的前景色，不随浅色深色变化。
    static let onBrand = Color.white
    /// 播放器专用：全屏黑底与黑底上的文字、图标。
    static let mediaBackground = Color.black
    static let onMedia = Color.white

    @MainActor static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brandBlueSoft, brandBlue],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// UIKit 容器用的表面色，与 `surface` 一致，用于铺满 sheet 的可视区域。
    static let surfaceUIColor = UIColor { traits in
        UIColor(hex: traits.userInterfaceStyle == .dark ? 0x171B22 : 0xFFFFFF)
    }

    /// UIKit 容器用的弹窗底色，与 `sheetBackground` 一致。
    static let sheetBackgroundUIColor = UIColor { traits in
        UIColor(hex: traits.userInterfaceStyle == .dark ? 0x131820 : 0xF7F9FC)
    }
}

// MARK: - 外观设置

enum RexAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "自动"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum RexTitleStyle: String, CaseIterable, Identifiable {
    /// 标准：顶栏使用正常字号。
    case standard
    /// 小标题：顶栏标题更小、导航栏更矮。
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "标准"
        case .compact: "小标题"
        }
    }
}

/// 品牌色八选一：与设置页色板一一对应。
enum RexBrandColor: String, CaseIterable, Identifiable {
    case blue
    case cyan
    case green
    case purple
    case orange
    case pink
    case red
    case indigo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "经典蓝"
        case .cyan: "天青"
        case .green: "青绿"
        case .purple: "紫罗兰"
        case .orange: "橙色"
        case .pink: "桃粉"
        case .red: "珊瑚红"
        case .indigo: "靛蓝"
        }
    }

    var color: Color { Color(hex: hex) }

    var softColor: Color { Color(hex: softHex) }

    private var hex: UInt32 {
        switch self {
        case .blue: 0x0066FF
        case .cyan: 0x0EA5E9
        case .green: 0x22C55E
        case .purple: 0xA855F7
        case .orange: 0xF97316
        case .pink: 0xEC4899
        case .red: 0xEF4444
        case .indigo: 0x4F46E5
        }
    }

    private var softHex: UInt32 {
        switch self {
        case .blue: 0x2E7BFF
        case .cyan: 0x38BDF8
        case .green: 0x4ADE80
        case .purple: 0xC084FC
        case .orange: 0xFB923C
        case .pink: 0xF472B6
        case .red: 0xF87171
        case .indigo: 0x818CF8
        }
    }
}

/// Logo 方案：目前只有一套，后续补素材时在此追加 case 即可。
enum RexLogoStyle: String, CaseIterable, Identifiable {
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "经典"
        }
    }

    var imageName: String {
        switch self {
        case .classic: "BrandMark"
        }
    }
}

/// 外观偏好：跟随系统 / 品牌色 / 顶栏行为，全部落在 `UserDefaults`。
@MainActor
@Observable
final class RexThemeStore {
    static let shared = RexThemeStore()

    private enum Key {
        static let appearance = "rex.appearance"
        static let brandColor = "rex.brandColor"
        static let titleStyle = "rex.titleStyle"
        static let collapseNav = "rex.collapseNav"
        static let showNavTitle = "rex.showNavTitle"
        static let logoStyle = "rex.logoStyle"
        static let iconLibraryURLs = "rex.iconLibraryURLs"
    }

    var appearance: RexAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var brandColor: RexBrandColor {
        didSet { defaults.set(brandColor.rawValue, forKey: Key.brandColor) }
    }

    var titleStyle: RexTitleStyle {
        didSet { defaults.set(titleStyle.rawValue, forKey: Key.titleStyle) }
    }

    /// 滑动时收缩导航栏
    var collapseNavOnScroll: Bool {
        didSet { defaults.set(collapseNavOnScroll, forKey: Key.collapseNav) }
    }

    /// 显示导航栏名称
    var showNavTitle: Bool {
        didSet { defaults.set(showNavTitle, forKey: Key.showNavTitle) }
    }

    /// Logo 方案
    var logoStyle: RexLogoStyle {
        didSet { defaults.set(logoStyle.rawValue, forKey: Key.logoStyle) }
    }

    /// GitHub 图标库地址列表；空数组表示不使用在线图标库
    var iconLibraryURLs: [String] {
        didSet { defaults.set(iconLibraryURLs, forKey: Key.iconLibraryURLs) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard
        appearance = RexAppearance(
            rawValue: defaults.string(forKey: Key.appearance) ?? ""
        ) ?? .system
        brandColor = RexBrandColor(
            rawValue: defaults.string(forKey: Key.brandColor) ?? ""
        ) ?? .blue
        titleStyle = RexTitleStyle(
            rawValue: defaults.string(forKey: Key.titleStyle) ?? ""
        ) ?? .standard
        collapseNavOnScroll = defaults.object(forKey: Key.collapseNav) as? Bool ?? false
        showNavTitle = defaults.object(forKey: Key.showNavTitle) as? Bool ?? true
        logoStyle = RexLogoStyle(
            rawValue: defaults.string(forKey: Key.logoStyle) ?? ""
        ) ?? .classic
        iconLibraryURLs = defaults.stringArray(forKey: Key.iconLibraryURLs) ?? []
    }
}

/// 字号映射到系统文字样式，全部跟随 Dynamic Type 缩放；
/// 页面里的文字优先使用这里的语义字号，避免散落的固定 pt 字号破坏层级一致性。
enum RexFont {
    static let title1 = Font.system(.largeTitle, weight: .semibold)
    static let title2 = Font.system(.title2, weight: .semibold)
    static let title3 = Font.system(.title3, weight: .semibold)
    static let headline = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let callout = Font.system(.callout)
    static let subheadline = Font.system(.subheadline)
    static let footnote = Font.system(.footnote)
    static let caption = Font.system(.caption)
    static let caption2 = Font.system(.caption2)

    /// 页面分区标题。
    static let section = Font.system(.footnote, weight: .semibold)
    /// 设置 / 列表主标题与右侧值。
    static let row = Font.system(.body)
    static let rowValue = Font.system(.subheadline)
    /// 主操作按钮。
    static let button = Font.system(.headline, weight: .semibold)
    /// 标签、胶囊徽标。
    static let badge = Font.system(.caption2, weight: .semibold)
    /// 关键数字，使用圆润字面增强可读性。
    static let metric = Font.system(.title2, design: .rounded, weight: .bold)
    /// 链接、提取码等需要等宽对齐的文本。
    static let mono = Font.system(.subheadline, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
}

enum RexRadius {
    static let small: CGFloat = 10
    static let control: CGFloat = 14
    static let card: CGFloat = 16
    static let chip: CGFloat = 18
    /// 大卡片 / 详情页信息面板。
    static let largeCard: CGFloat = 20
    /// 设置中心的分组面板：比普通卡片更圆，贴近 iOS 原生分组列表。
    static let panel: CGFloat = 24
    static let iconTile: CGFloat = 22
    static let brand: CGFloat = 26
}

enum RexSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 48
}

/// 布局常量：所有页面共用同一套内容宽度与触控尺寸。
enum RexLayout {
    /// 手机 / iPad 共用的内容最大宽度。
    static let contentMaxWidth: CGFloat = 720
    /// 登录、表单等需要更窄阅读宽度的页面。
    static let readableMaxWidth: CGFloat = 520
    /// 表单控件的舒适宽度上限。
    static let formMaxWidth: CGFloat = 460
    /// iOS HIG 最小触控尺寸。
    static let minTouch: CGFloat = 44
    /// 设置行统一高度。
    static let rowHeight: CGFloat = 56
}

/// 动效规范：交互反馈快、状态切换稳、强调动画有回弹。
enum RexMotion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let standard = Animation.easeInOut(duration: 0.24)
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

extension View {
    /// 全局底部弹窗：系统卡片呈现，底层页面由 UISheetPresentationController 自动收缩后退。
    /// 内容较多的页面（如目录选择）可只给 `.large`，避免默认中档高度截断内容。
    func rexSheetStyle(
        detents: Set<PresentationDetent> = [.medium, .large]
    ) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .background(RexSheetPresentationConfigurator())
    }

    /// 由 UIKit 直接呈现系统大卡片，保留下层页面的原生收缩后退动画。
    func rexCardSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        background(RexCardSheetPresenter(item: item, content: content))
    }
}

private struct RexCardSheetPresenter<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let content: (Item) -> Content

    func makeUIViewController(context: Context) -> RexCardSheetAnchorViewController {
        let controller = RexCardSheetAnchorViewController()
        controller.onDismiss = { item = nil }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: RexCardSheetAnchorViewController,
        context: Context
    ) {
        uiViewController.onDismiss = { item = nil }
        if let item {
            uiViewController.presentSheet(
                rootView: content(item).environment(\.self, context.environment)
            )
        } else {
            uiViewController.dismissSheet()
        }
    }
}

private final class RexCardSheetAnchorViewController: UIViewController {
    var onDismiss: (() -> Void)?
    private weak var presentedSheet: UIViewController?

    func presentSheet<Content: View>(rootView: Content) {
        guard presentedSheet == nil,
              let presenter = rootPresenter,
              presenter.presentedViewController == nil else { return }

        let sheetContent = rootView
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, RexSpacing.sm)

        let controller = RexSheetHostingController(rootView: sheetContent)
        controller.onDismiss = { [weak self] in
            self?.presentedSheet = nil
            self?.onDismiss?()
        }
        // sheet 容器自身铺底色，避免顶部把手区和底部安全区露出透明。
        controller.view.backgroundColor = RexColor.sheetBackgroundUIColor
        controller.modalPresentationStyle = .pageSheet

        let contentHeight = measuredContentHeight(of: controller, in: presenter)
        let bottomInset = presenter.view.window?.safeAreaInsets.bottom ?? 0

        if let sheet = controller.sheetPresentationController {
            let detent: UISheetPresentationController.Detent = .custom(
                identifier: .init("rex.card")
            ) { _ in
                contentHeight + bottomInset
            }
            sheet.detents = [detent]
            sheet.selectedDetentIdentifier = detent.identifier
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.largestUndimmedDetentIdentifier = nil
        }

        presentedSheet = controller
        presenter.present(controller, animated: true)
    }

    /// 按弹窗实际内容测量高度，避免固定占满屏幕。
    private func measuredContentHeight<Content: View>(
        of controller: UIHostingController<Content>,
        in presenter: UIViewController
    ) -> CGFloat {
        let width = presenter.view.bounds.width

        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        controller.view.layoutIfNeeded()
        let fitting = controller.sizeThatFits(
            in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        )
        return max(fitting.height, 1)
    }

    func dismissSheet() {
        guard let presentedSheet else { return }
        self.presentedSheet = nil
        presentedSheet.dismiss(animated: true)
    }

    private var rootPresenter: UIViewController? {
        var presenter = parent
        while let parent = presenter?.parent {
            presenter = parent
        }
        return presenter
    }
}

/// 系统 sheet 关闭（下滑、点遮罩、内容里 dismiss）后回调，保证绑定状态同步清空。
private final class RexSheetHostingController<Content: View>: UIHostingController<Content> {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?()
        }
    }
}

private struct RexSheetPresentationConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> RexSheetConfigurationViewController {
        RexSheetConfigurationViewController()
    }

    func updateUIViewController(
        _ uiViewController: RexSheetConfigurationViewController,
        context: Context
    ) {
        uiViewController.configureSheet()
    }
}

private final class RexSheetConfigurationViewController: UIViewController {
    private weak var configuredSheet: UISheetPresentationController?

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        configureSheet()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureSheet()
    }

    func configureSheet() {
        var controller = parent
        while let current = controller {
            if let sheet = current.sheetPresentationController {
                guard configuredSheet !== sheet else { return }

                // 高度档位交给页面用 `.presentationDetents` 自行声明，
                // 这里只补系统外观，避免把弹窗一律强制成中档高度。
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 20
                sheet.prefersScrollingExpandsWhenScrolledToEdge = true
                sheet.largestUndimmedDetentIdentifier = nil
                configuredSheet = sheet
                return
            }
            controller = current.parent
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(RexMotion.quick, value: configuration.isPressed)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
