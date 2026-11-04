import Observation
import SwiftUI

/// 内置彩色头像：渐变底 + emoji，作为固定素材，不依赖网络或图标库。
struct RexAvatarStyle: Identifiable, Hashable, Sendable {
    let id: String
    let emoji: String
    let title: String
    let startHex: UInt32
    let endHex: UInt32

    var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: startHex), Color(hex: endHex)],
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
        RexAvatarStyle(id: "cinema", emoji: "🎬", title: "影院", startHex: 0x5B8CFF, endHex: 0x7C4DFF),
        RexAvatarStyle(id: "popcorn", emoji: "🍿", title: "爆米花", startHex: 0xFFB65C, endHex: 0xFF6B9A),
        RexAvatarStyle(id: "player", emoji: "🎮", title: "玩家", startHex: 0x9D7BFF, endHex: 0xD05CE8),
        RexAvatarStyle(id: "music", emoji: "🎧", title: "音乐", startHex: 0x33D6E8, endHex: 0x3B82F6),
        RexAvatarStyle(id: "rocket", emoji: "🚀", title: "启程", startHex: 0x4FD1FF, endHex: 0x6366F1),
        RexAvatarStyle(id: "cat", emoji: "🐱", title: "猫咪", startHex: 0xFFC078, endHex: 0xFF85A8),
        RexAvatarStyle(id: "fox", emoji: "🦊", title: "狐狸", startHex: 0xFFA94D, endHex: 0xFF5E3A),
        RexAvatarStyle(id: "panda", emoji: "🐼", title: "熊猫", startHex: 0xA7B4C6, endHex: 0x64748B),
        RexAvatarStyle(id: "rainbow", emoji: "🌈", title: "彩虹", startHex: 0xF78BEA, endHex: 0x8B5CF6),
        RexAvatarStyle(id: "bolt", emoji: "⚡", title: "闪电", startHex: 0xFFE066, endHex: 0xFFA000),
        RexAvatarStyle(id: "night", emoji: "🌙", title: "夜晚", startHex: 0x7A8CFF, endHex: 0x3B2F8F),
        RexAvatarStyle(id: "clover", emoji: "🍀", title: "幸运", startHex: 0x5BE49B, endHex: 0x18A058),
        RexAvatarStyle(id: "blossom", emoji: "🌸", title: "樱花", startHex: 0xFFB3D1, endHex: 0xFF5C8A),
        RexAvatarStyle(id: "whale", emoji: "🐳", title: "鲸鱼", startHex: 0x69C9FF, endHex: 0x2F6BFF),
        RexAvatarStyle(id: "flame", emoji: "🔥", title: "火焰", startHex: 0xFF9A3C, endHex: 0xFF3B4E),
        RexAvatarStyle(id: "ice", emoji: "❄️", title: "冰雪", startHex: 0x9BE7FF, endHex: 0x3AA6E8),
        RexAvatarStyle(id: "palette", emoji: "🎨", title: "调色盘", startHex: 0xFF8FCF, endHex: 0x9B5DE5),
        RexAvatarStyle(id: "orange", emoji: "🍊", title: "橙子", startHex: 0xFFC44D, endHex: 0xFF7A1A),
        RexAvatarStyle(id: "planet", emoji: "🪐", title: "星球", startHex: 0xA78BFA, endHex: 0x3B82F6),
        RexAvatarStyle(id: "avocado", emoji: "🥑", title: "牛油果", startHex: 0xB8E986, endHex: 0x4CAF50)
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

                Text(style.emoji)
                    .font(.system(size: size * 0.47))
                    .shadow(color: .black.opacity(0.22), radius: size * 0.035, y: size * 0.02)
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
