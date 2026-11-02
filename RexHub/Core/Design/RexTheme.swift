import SwiftUI
import UIKit

enum RexColor {
    static var brandBlue: Color { RexThemeStore.shared.brandColor.color }
    static var brandBlueSoft: Color { RexThemeStore.shared.brandColor.softColor }

    static let lightBlue = Color(hex: 0xE6F0FF)

    static let background = dynamic(light: 0xF2F5FA, dark: 0x0E1116)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x171B22)
    static let field = dynamic(light: 0xF2F5FA, dark: 0x1C222B)
    /// 列表选中态底色，比页面背景深一档，避免和背景混在一起。
    static let selection = dynamic(light: 0xE1E7F0, dark: 0x262E3A)
    static let primaryText = dynamic(light: 0x0F172A, dark: 0xF2F5FA)
    static let secondaryText = dynamic(light: 0x8B8F98, dark: 0x8B93A1)
    static let divider = dynamic(light: 0xE5E7EB, dark: 0x2A3038)

    static let success = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)
    static let error = Color(hex: 0xEF4444)

    /// 品牌色 / 播放器黑底上的前景色，不随浅色深色变化。
    static let onBrand = Color.white
    /// 播放器专用：全屏黑底与黑底上的文字、图标。
    static let mediaBackground = Color.black
    static let onMedia = Color.white

    static var brandGradient: LinearGradient {
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

/// 字号映射到系统文字样式，跟随 Dynamic Type 缩放；品牌字与装饰数字才用固定字号。
enum RexFont {
    static let title1 = Font.system(.largeTitle, weight: .semibold)
    static let title2 = Font.system(.title2, weight: .semibold)
    static let title3 = Font.system(.title3, weight: .medium)
    static let body = Font.system(.callout)
    static let caption = Font.system(.subheadline)
}

enum RexRadius {
    static let control: CGFloat = 14
    static let card: CGFloat = 16
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

extension View {
    /// 全局底部弹窗样式：交给系统 sheet 呈现，半高 / 全高两档，顶部带拖拽条。
    func rexSheetStyle() -> some View {
        presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
