import UIKit

/// 播放页与全屏按钮共用的方向切换：几何更新后同步通知根控制器刷新支持方向。
enum RexOrientation {
    /// 请求系统把界面转到指定方向。
    /// 模态转场未结束时系统会静默忽略请求，这里延迟校验方向并重试几次，
    /// 避免进入播放页时「自动横屏」偶发不生效。
    static func request(_ mask: UIInterfaceOrientationMask, attempt: Int = 0) {
        guard let scene else { return }

        // 先声明新的支持方向，再请求几何更新，顺序反了系统可能直接忽略。
        // 播放页是 fullScreenCover，方向声明要落到当前最上层的控制器上。
        let root = scene.keyWindow?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        topViewController(from: root)?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))

        guard attempt < 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard !matches(mask, scene.interfaceOrientation) else { return }
            request(mask, attempt: attempt + 1)
        }
    }

    /// 当前是否处于横屏。
    static var isLandscape: Bool {
        scene?.interfaceOrientation.isLandscape ?? false
    }

    /// 逐层找到当前最上层可见的控制器。
    private static func topViewController(from controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        return controller
    }

    /// 判断当前方向是否已经落在请求的方向集合里。
    private static func matches(_ mask: UIInterfaceOrientationMask, _ orientation: UIInterfaceOrientation) -> Bool {
        switch orientation {
        case .portrait: return mask.contains(.portrait)
        case .portraitUpsideDown: return mask.contains(.portraitUpsideDown)
        case .landscapeLeft: return mask.contains(.landscapeLeft)
        case .landscapeRight: return mask.contains(.landscapeRight)
        @unknown default: return false
        }
    }

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
