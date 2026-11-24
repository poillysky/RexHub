import SwiftUI
import UIKit

/// 监听系统 TabBar 的「重复点击当前标签」手势。
///
/// SwiftUI 的 `TabView` 不会把重复点击已选中标签的事件暴露出来，
/// 这里直接给底层 `UITabBar` 挂一个旁路手势：只有点中的是当前选中项时才回调，
/// 用于实现 iOS 原生的「再点一次回顶部 / 回根页」行为。
struct TabBarReselectObserver: UIViewControllerRepresentable {
    var onReselect: (Int) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onReselect: onReselect)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onReselect = onReselect
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onReselect: (Int) -> Void

        private weak var observedTabBar: UITabBar?

        init(onReselect: @escaping (Int) -> Void) {
            self.onReselect = onReselect
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach(retries: 10)
        }

        private func attach(retries: Int) {
            guard let tabBar = findTabBar() else {
                guard retries > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.attach(retries: retries - 1)
                }
                return
            }

            guard observedTabBar !== tabBar else { return }

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            tap.cancelsTouchesInView = false
            tabBar.addGestureRecognizer(tap)
            observedTabBar = tabBar
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let tabBar = observedTabBar,
                  let items = tabBar.items,
                  let selected = tabBar.selectedItem,
                  let selectedIndex = items.firstIndex(of: selected)
            else { return }

            let point = gesture.location(in: tabBar)
            let buttons = tabBar.subviews.filter {
                NSStringFromClass(type(of: $0)).contains("UITabBarButton")
            }
            guard let hit = buttons.first(where: { $0.frame.contains(point) }) else { return }

            let sorted = buttons.sorted { $0.frame.minX < $1.frame.minX }
            guard let index = sorted.firstIndex(of: hit), index == selectedIndex else { return }

            RexHaptics.tap()
            onReselect(index)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        private func findTabBar() -> UITabBar? {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else { return nil }

            return scene.windows
                .first(where: \.isKeyWindow)?
                .rexFirstDescendant(of: UITabBar.self)
        }
    }
}
