import SwiftUI
import UIKit

/// 恢复系统侧滑返回手势。
///
/// 页面统一用 `.toolbar(.hidden, for: .navigationBar)` 隐藏系统导航栏，
/// 这会连带禁用 `interactivePopGestureRecognizer`，导致二级页只能点返回按钮。
/// 这里在每个导航容器上重新挂回手势代理，保持 HIG 的原生返回手感。
struct SwipeBackEnabler: UIViewControllerRepresentable {
    /// 页内覆盖层打开时临时关掉系统侧滑返回，避免右滑误把整个页面弹掉。
    var isEnabled: Bool = true

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.isEnabled = isEnabled
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isEnabled = isEnabled
        controller.applyState()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var isEnabled = true {
            didSet {
                guard isEnabled != oldValue else { return }
                applyState()
            }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attach()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        func applyState() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = isEnabled
        }

        private func attach() {
            var candidate = parent
            while let current = candidate, !(current is UINavigationController) {
                candidate = current.parent
            }
            guard let navigationController = (navigationController ?? candidate as? UINavigationController) else { return }
            guard navigationController.viewControllers.count > 1 else { return }

            let gesture = navigationController.interactivePopGestureRecognizer
            gesture?.delegate = self
            gesture?.isEnabled = isEnabled
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled && (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

extension View {
    /// 隐藏系统导航栏后仍保留侧滑返回。
    func rexSwipeBack(_ enabled: Bool = true) -> some View {
        background(SwipeBackEnabler(isEnabled: enabled).frame(width: 0, height: 0))
    }

    /// 二级页统一外壳：隐藏系统导航栏，并保留侧滑返回。
    /// 底部标签栏保持可见，避免进入二级页后导航栏消失、只能一路返回。
    /// 新增二级页只需挂这一个修饰符，避免漏掉其中一项导致交互断点。
    func rexPushedScreen(_ swipeBackEnabled: Bool = true) -> some View {
        self
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.visible, for: .tabBar)
            .rexSwipeBack(swipeBackEnabled)
    }
}
