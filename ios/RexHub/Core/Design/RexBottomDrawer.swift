import SwiftUI
import UIKit

// MARK: - 入口

/// 抽屉高度策略。
enum RexDrawerSizing {
    /// 固定占屏幕高度的 92%（不低于 320），适合目录浏览这类长内容。
    case fill
    /// 跟随内容高度：最低 `minHeight`，最高仍不超过屏幕的 92%，适合详情、操作面板等短内容。
    case content(minHeight: CGFloat = 260)
}

extension View {
    /// 贴边底部抽屉（替代系统 sheet 的浮卡外观）。
    /// 全宽、顶部圆角、带遮罩，从底部弹入；点遮罩或下拉顶部区域可关闭。
    func rexBottomDrawer<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        sizing: RexDrawerSizing = .fill,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(RexDrawerItemModifier(item: item, sizing: sizing, drawerContent: content))
    }

    func rexBottomDrawer<Content: View>(
        isPresented: Binding<Bool>,
        sizing: RexDrawerSizing = .fill,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(RexDrawerFlagModifier(isPresented: isPresented, sizing: sizing, drawerContent: content))
    }
}

// MARK: - SwiftUI 桥接

private struct RexDrawerItemModifier<Item: Identifiable, DrawerContent: View>: ViewModifier {
    @Binding var item: Item?
    var sizing: RexDrawerSizing = .fill
    let drawerContent: (Item) -> DrawerContent

    func body(content: Content) -> some View {
        content.background {
            RexDrawerItemAnchor(item: $item, sizing: sizing, build: drawerContent)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

private struct RexDrawerFlagModifier<DrawerContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var sizing: RexDrawerSizing = .fill
    let drawerContent: () -> DrawerContent

    func body(content: Content) -> some View {
        content.background {
            RexDrawerFlagAnchor(isPresented: $isPresented, sizing: sizing, build: drawerContent)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

private struct RexDrawerItemAnchor<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    var sizing: RexDrawerSizing = .fill
    let build: (Item) -> Content

    @Environment(\.apiClient) private var apiClient

    func makeUIViewController(context: Context) -> RexDrawerAnchorController {
        RexDrawerAnchorController()
    }

    func updateUIViewController(_ controller: RexDrawerAnchorController, context: Context) {
        let binding = $item
        controller.onDismiss = { binding.wrappedValue = nil }

        if let item {
            // 抽屉用的 UIHostingController 是手动创建的，不会继承 SwiftUI 环境，需要手动注入。
            controller.show(build(item).environment(\.apiClient, apiClient), sizing: sizing)
        } else {
            controller.hide()
        }
    }
}

private struct RexDrawerFlagAnchor<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var sizing: RexDrawerSizing = .fill
    let build: () -> Content

    @Environment(\.apiClient) private var apiClient

    func makeUIViewController(context: Context) -> RexDrawerAnchorController {
        RexDrawerAnchorController()
    }

    func updateUIViewController(_ controller: RexDrawerAnchorController, context: Context) {
        let binding = $isPresented
        controller.onDismiss = { binding.wrappedValue = false }

        if isPresented {
            controller.show(build().environment(\.apiClient, apiClient), sizing: sizing)
        } else {
            controller.hide()
        }
    }
}

// MARK: - 挂载点

private final class RexDrawerAnchorController: UIViewController {
    var onDismiss: (() -> Void)?

    private let drawerDelegate = RexDrawerTransitioningDelegate()
    private var presentedHost: UIViewController?
    private var isShowing = false
    private var pendingShow: (() -> Void)?

    override func loadView() {
        view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
    }

    func show<Content: View>(_ content: Content, sizing: RexDrawerSizing = .fill) {
        guard !isShowing, presentedHost == nil else { return }
        guard view.window != nil else {
            pendingShow = { [weak self] in self?.show(content, sizing: sizing) }
            return
        }

        isShowing = true
        drawerDelegate.sizing = sizing

        let host = RexDrawerHostController(rootView: content)
        if case .content(let minHeight) = sizing {
            // 先量一次内容高度，再交给展示控制器贴底摆放，避免小面板被拉满全屏。
            let bounds = view.window?.bounds.size ?? CGSize(width: 390, height: 844)
            let width = min(bounds.width, 760)
            let fitting = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            host.preferredContentSize = CGSize(
                width: width,
                height: min(max(fitting.height, minHeight), bounds.height * 0.92)
            )
        }
        host.modalPresentationStyle = .custom
        host.transitioningDelegate = drawerDelegate
        host.onDidDisappear = { [weak self] in
            guard let self else { return }
            self.isShowing = false
            self.presentedHost = nil
            self.onDismiss?()
        }
        presentedHost = host
        present(host, animated: true)
    }

    func hide() {
        pendingShow = nil
        guard isShowing, let host = presentedHost else { return }
        isShowing = false
        host.dismiss(animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let pendingShow {
            self.pendingShow = nil
            pendingShow()
        }
    }
}

// MARK: - 宿主

@MainActor
private protocol RexDrawerHostProtocol: AnyObject {
    var onDidDisappear: (() -> Void)? { get set }
}

private final class RexDrawerHostController<Content: View>: UIHostingController<Content>, RexDrawerHostProtocol {
    var onDidDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDidDisappear?()
        }
    }
}

// MARK: - 转场

private final class RexDrawerTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    var sizing: RexDrawerSizing = .fill

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        RexDrawerPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            sizing: sizing
        )
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        RexDrawerAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        RexDrawerAnimator(isPresenting: false)
    }
}

private final class RexDrawerAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.42 : 0.30
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView

        if isPresenting {
            guard
                let toView = transitionContext.view(forKey: .to),
                let toController = transitionContext.viewController(forKey: .to)
            else {
                transitionContext.completeTransition(false)
                return
            }
            let finalFrame = transitionContext.finalFrame(for: toController)
            toView.frame = finalFrame
            container.addSubview(toView)

            // 非动画转场（例如手动拖拽后 dismiss(animated: false)）直接完成，避免再跑一次动画。
            guard transitionContext.isAnimated else {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }

            toView.transform = CGAffineTransform(translationX: 0, y: finalFrame.height)
            UIView.animate(
                withDuration: transitionDuration(using: transitionContext),
                delay: 0,
                usingSpringWithDamping: 0.92,
                initialSpringVelocity: 0.2,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                toView.transform = .identity
            } completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }

            // 拖拽关闭时视图已经被手动移出屏幕，这里不能再播一遍下滑动画。
            guard transitionContext.isAnimated else {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }

            let height = fromView.bounds.height
            // 临界阻尼弹簧：起步快、收尾不弹跳，比线性 easeIn 更接近系统面板的收回手感。
            UIView.animate(
                withDuration: transitionDuration(using: transitionContext),
                delay: 0,
                usingSpringWithDamping: 1,
                initialSpringVelocity: 0.25,
                options: [.curveEaseIn, .allowUserInteraction]
            ) {
                fromView.transform = CGAffineTransform(translationX: 0, y: height)
            } completion: { _ in
                fromView.transform = .identity
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        }
    }
}

// MARK: - 展示控制器

private final class RexDrawerPresentationController: UIPresentationController, UIGestureRecognizerDelegate {
    private let dimmingView = UIView()
    private let sizing: RexDrawerSizing
    private let heightRatio: CGFloat = 0.92
    private var isDismissingAfterDrag = false

    init(presentedViewController: UIViewController, presenting: UIViewController?, sizing: RexDrawerSizing) {
        self.sizing = sizing
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        let maxHeight = max(320, containerView.bounds.height * heightRatio)
        let height: CGFloat
        switch sizing {
        case .fill:
            height = maxHeight
        case .content(_):
            let preferred = presentedViewController.preferredContentSize.height
            height = preferred > 0 ? min(preferred, maxHeight) : maxHeight
        }
        let width = min(containerView.bounds.width, 760)
        return CGRect(
            x: (containerView.bounds.width - width) / 2,
            y: containerView.bounds.height - height,
            width: width,
            height: height
        )
    }

    override func presentationTransitionWillBegin() {
        guard let containerView, let presentedView else { return }

        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dimmingView.frame = containerView.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimmingView.alpha = 0
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleDimTap)))
        containerView.addSubview(dimmingView)
        containerView.sendSubviewToBack(dimmingView)

        presentedView.layer.cornerRadius = 22
        presentedView.layer.cornerCurve = .continuous
        presentedView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        presentedView.clipsToBounds = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        presentedView.addGestureRecognizer(pan)

        presentedViewController.transitionCoordinator?.animate { _ in
            self.dimmingView.alpha = 1
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed {
            dimmingView.removeFromSuperview()
        }
    }

    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate { _ in
            self.dimmingView.alpha = 0
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed {
            dimmingView.removeFromSuperview()
        }
    }

    override func containerViewDidLayoutSubviews() {
        super.containerViewDidLayoutSubviews()
        // 拖动/收走过程中 transform 不是 identity，此时重设 frame 会让视图跳动。
        guard let presentedView, presentedView.transform == .identity else { return }
        presentedView.frame = frameOfPresentedViewInContainerView
    }

    // MARK: 手势

    /// 只在抽屉顶部的标题区域开启下拉，避免和内部 ScrollView 抢手势。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let presentedView else { return false }
        return gestureRecognizer.location(in: presentedView).y <= 76
    }

    @objc private func handleDimTap() {
        presentedViewController.dismiss(animated: true)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let presentedView, !isDismissingAfterDrag else { return }
        let translation = max(0, gesture.translation(in: presentedView).y)
        let height = presentedView.bounds.height

        switch gesture.state {
        case .changed:
            presentedView.transform = CGAffineTransform(translationX: 0, y: translation)
            // 遮罩随拖动距离等比淡出，跟手且不突变。
            dimmingView.alpha = max(0, 1 - translation / max(height, 1))

        case .ended, .cancelled:
            let velocity = gesture.velocity(in: presentedView).y
            // 用速度做一点投影，快速轻扫也能顺滑收走，而不是必须拖过半屏。
            let projected = translation + velocity * 0.16
            let shouldDismiss = gesture.state == .ended
                && (projected > height * 0.28 || velocity > 1_000)

            guard shouldDismiss else {
                UIView.animate(
                    withDuration: 0.38,
                    delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: 0.3,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    presentedView.transform = .identity
                    self.dimmingView.alpha = 1
                }
                return
            }

            isDismissingAfterDrag = true
            // 剩余距离越短、手速越快，动画越短，接续手指的惯性。
            let remaining = max(height - translation, 1)
            let speed = max(velocity, 900)
            let duration = min(0.34, max(0.16, remaining / speed))

            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseIn, .allowUserInteraction]
            ) {
                presentedView.transform = CGAffineTransform(translationX: 0, y: height)
                self.dimmingView.alpha = 0
            } completion: { _ in
                // 保持当前 transform，交给非动画 dismiss 直接移除，避免复位后重新下滑。
                self.presentedViewController.dismiss(animated: false)
            }

        default:
            break
        }
    }
}
