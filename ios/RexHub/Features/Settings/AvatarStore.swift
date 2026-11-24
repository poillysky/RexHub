import Observation
import SwiftUI

/// 内置彩色头像：渐变底 + SF Symbol，作为固定素材，不依赖网络、图标库与 emoji 字体。
struct RexAvatarStyle: Identifiable, Hashable, Sendable {
    let id: String
    let symbol: String
    let title: String
    let startHex: UInt32
    let midHex: UInt32
    let endHex: UInt32

    var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: startHex), Color(hex: midHex), Color(hex: endHex)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// 头像选择：`.initial` 用昵称首字母，`.builtIn` 用固定的彩色头像。
/// 全 App 共用一个实例，首页、更多页、账号设置页读同一个值。
@MainActor
@Observable
final class AvatarStore {
    static let shared = AvatarStore()

    static let styles: [RexAvatarStyle] = [
        RexAvatarStyle(id: "cinema", symbol: "film.fill", title: "影院", startHex: 0x8B7CFF, midHex: 0x6A5BFF, endHex: 0x4A35E0),
        RexAvatarStyle(id: "player", symbol: "gamecontroller.fill", title: "玩家", startHex: 0xC06BFF, midHex: 0x9B4DFF, endHex: 0x6D28D9),
        RexAvatarStyle(id: "music", symbol: "headphones", title: "音乐", startHex: 0x4FD8E8, midHex: 0x3BA9F0, endHex: 0x2563EB),
        RexAvatarStyle(id: "cat", symbol: "pawprint.fill", title: "猫咪", startHex: 0xFFCF8A, midHex: 0xFFA08B, endHex: 0xFF7A6B),
        RexAvatarStyle(id: "rainbow", symbol: "rainbow", title: "彩虹", startHex: 0xFF9AD5, midHex: 0xD07BFF, endHex: 0x8B5CF6),
        RexAvatarStyle(id: "bolt", symbol: "bolt.fill", title: "闪电", startHex: 0xFFE066, midHex: 0xFFC233, endHex: 0xFF8A00),
        RexAvatarStyle(id: "night", symbol: "moon.stars.fill", title: "夜空", startHex: 0x8FA6FF, midHex: 0x6B7BF5, endHex: 0x3B3DA8),
        RexAvatarStyle(id: "clover", symbol: "leaf.fill", title: "四叶", startHex: 0x7DEBA8, midHex: 0x3ECF7E, endHex: 0x159A55),
        RexAvatarStyle(id: "blossom", symbol: "sparkles", title: "闪耀", startHex: 0xFFB3D1, midHex: 0xFF7FB0, endHex: 0xF43F7E),
        RexAvatarStyle(id: "flame", symbol: "flame.fill", title: "火焰", startHex: 0xFFB057, midHex: 0xFF7A3C, endHex: 0xF03B3B),
        RexAvatarStyle(id: "ice", symbol: "snowflake", title: "冰雪", startHex: 0xA8ECFF, midHex: 0x63CFF5, endHex: 0x2F86E8)
    ]

    static func style(id: String) -> RexAvatarStyle? {
        styles.first { $0.id == id }
    }

    enum Selection: Equatable, Hashable, Sendable {
        case initial
        case builtIn(String)
    }

    private static let key = "rexhub.avatar.selection"

    private let defaults: UserDefaults
    private(set) var selection: Selection

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selection = Self.load(from: defaults)
    }

    /// `nil` 表示用昵称首字母。
    func select(_ id: String?) {
        selection = id.flatMap { Self.style(id: $0) != nil ? .builtIn($0) : nil } ?? .initial
        defaults.set(Self.rawValue(for: selection), forKey: Self.key)
    }

    private static func load(from defaults: UserDefaults) -> Selection {
        guard let raw = defaults.string(forKey: key) else { return .initial }
        let prefix = "builtin:"
        guard raw.hasPrefix(prefix) else { return .initial }
        let id = String(raw.dropFirst(prefix.count))
        return style(id: id) == nil ? .initial : .builtIn(id)
    }

    private static func rawValue(for selection: Selection) -> String {
        switch selection {
        case .initial:
            return "initial"
        case .builtIn(let id):
            return "builtin:\(id)"
        }
    }
}

/// 圆形头像：内置彩色头像，或浅品牌蓝底 + 昵称首字母。
struct RexAvatar: View {
    let name: String
    var size: CGFloat = 36
    var selection: AvatarStore.Selection = .initial

    private var initial: String {
        name.isEmpty ? "R" : String(name.prefix(1)).uppercased()
    }

    private var style: RexAvatarStyle? {
        guard case .builtIn(let id) = selection else { return nil }
        return AvatarStore.style(id: id)
    }

    var body: some View {
        ZStack {
            if let style {
                backdrop(for: style)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.35), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.32
                        )
                    )
                    .frame(width: size * 0.66, height: size * 0.66)
                    .blendMode(.softLight)

                Image(systemName: style.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.26), radius: size * 0.045, y: size * 0.022)
            } else {
                LinearGradient(
                    colors: [RexColor.brandBlue.opacity(0.16), RexColor.brandBlue.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(RexColor.brandBlue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if style != nil {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.65), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(1, size * 0.025)
                )
            } else {
                Circle().strokeBorder(RexColor.brandBlue.opacity(0.14), lineWidth: 0.5)
            }
        }
        .shadow(
            color: style.map { Color(hex: $0.endHex).opacity(0.24) } ?? .clear,
            radius: size * 0.14,
            y: size * 0.06
        )
        .accessibilityHidden(true)
    }

    /// 渐变底 + 左上柔光 + 边缘暗角 + 顶部高光，做出有体积感的圆形质感。
    private func backdrop(for style: RexAvatarStyle) -> some View {
        ZStack {
            style.gradient

            RadialGradient(
                colors: [.white.opacity(0.42), .clear],
                center: UnitPoint(x: 0.2, y: 0.14),
                startRadius: 0,
                endRadius: size * 0.85
            )

            RadialGradient(
                colors: [.clear, .black.opacity(0.28)],
                center: UnitPoint(x: 0.3, y: 0.24),
                startRadius: size * 0.3,
                endRadius: size * 1.05
            )

            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .white.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.62, height: size * 0.26)
                .rotationEffect(.degrees(-22))
                .offset(x: -size * 0.12, y: -size * 0.26)
                .blur(radius: size * 0.045)
                .blendMode(.softLight)
        }
    }
}
