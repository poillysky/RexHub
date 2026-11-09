import Foundation
import Observation

/// 播放页单指手势可绑定的动作，只描述「做什么」，具体执行留给播放器。
enum GestureAction: String, CaseIterable, Identifiable {
    case none
    case toggleControls
    case playPause
    case rewind
    case forward
    case speedUp
    case brightness
    case volume
    case seek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "无"
        case .toggleControls: "显示/隐藏菜单"
        case .playPause: "播放/暂停"
        case .rewind: "快退 10 秒"
        case .forward: "快进 10 秒"
        case .speedUp: "长按倍速"
        case .brightness: "调节亮度"
        case .volume: "调节音量"
        case .seek: "拖动查找"
        }
    }
}

/// 手势偏好：每个单指手势单独绑定动作，改动即时落盘。
@MainActor
@Observable
final class GestureSettingsStore {
    static let shared = GestureSettingsStore()

    private enum Key {
        static let singleTap = "rex.gesture.singleTap"
        static let doubleTapCenter = "rex.gesture.doubleTapCenter"
        static let doubleTapLeft = "rex.gesture.doubleTapLeft"
        static let doubleTapRight = "rex.gesture.doubleTapRight"
        static let longPress = "rex.gesture.longPress"
        static let horizontalDrag = "rex.gesture.horizontalDrag"
        static let leftVerticalDrag = "rex.gesture.leftVerticalDrag"
        static let rightVerticalDrag = "rex.gesture.rightVerticalDrag"
    }

    var singleTap: GestureAction {
        didSet { defaults.set(singleTap.rawValue, forKey: Key.singleTap) }
    }

    var doubleTapCenter: GestureAction {
        didSet { defaults.set(doubleTapCenter.rawValue, forKey: Key.doubleTapCenter) }
    }

    var doubleTapLeft: GestureAction {
        didSet { defaults.set(doubleTapLeft.rawValue, forKey: Key.doubleTapLeft) }
    }

    var doubleTapRight: GestureAction {
        didSet { defaults.set(doubleTapRight.rawValue, forKey: Key.doubleTapRight) }
    }

    var longPress: GestureAction {
        didSet { defaults.set(longPress.rawValue, forKey: Key.longPress) }
    }

    var horizontalDrag: GestureAction {
        didSet { defaults.set(horizontalDrag.rawValue, forKey: Key.horizontalDrag) }
    }

    var leftVerticalDrag: GestureAction {
        didSet { defaults.set(leftVerticalDrag.rawValue, forKey: Key.leftVerticalDrag) }
    }

    var rightVerticalDrag: GestureAction {
        didSet { defaults.set(rightVerticalDrag.rawValue, forKey: Key.rightVerticalDrag) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard

        singleTap = Self.action(defaults, Key.singleTap, default: .toggleControls)
        doubleTapCenter = Self.action(defaults, Key.doubleTapCenter, default: .playPause)
        doubleTapLeft = Self.action(defaults, Key.doubleTapLeft, default: .playPause)
        doubleTapRight = Self.action(defaults, Key.doubleTapRight, default: .playPause)
        longPress = Self.action(defaults, Key.longPress, default: .speedUp)
        horizontalDrag = Self.action(defaults, Key.horizontalDrag, default: .seek)
        leftVerticalDrag = Self.action(defaults, Key.leftVerticalDrag, default: .brightness)
        rightVerticalDrag = Self.action(defaults, Key.rightVerticalDrag, default: .volume)
    }

    private static func action(
        _ defaults: UserDefaults,
        _ key: String,
        default value: GestureAction
    ) -> GestureAction {
        guard let raw = defaults.string(forKey: key) else { return value }
        return GestureAction(rawValue: raw) ?? value
    }
}
