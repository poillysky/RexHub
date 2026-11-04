import SwiftUI
import UIKit

/// 全局行为：输入框聚焦、键盘弹起时，点击输入框以外的区域自动取消聚焦并收起键盘。
///
/// 通过挂在 key window 上的点击手势实现，`cancelsTouchesInView = false`
/// 保证按钮、列表等原有交互不受影响。
struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        KeyboardDismissView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class KeyboardDismissView: UIView, UIGestureRecognizerDelegate {
    private var isAttached = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, !isAttached else { return }
        isAttached = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        guard window?.currentFirstResponder != nil else { return }
        window?.endEditing(true)
    }

    /// 点在输入框本身时不做处理，避免切换输入框或移动光标时误收起键盘。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var view: UIView? = touch.view
        while let current = view {
            if current is UITextField || current is UITextView {
                return false
            }
            view = current.superview
        }
        return true
    }
}

private extension UIView {
    var currentFirstResponder: UIResponder? {
        if isFirstResponder {
            return self
        }
        for subview in subviews {
            if let responder = subview.currentFirstResponder {
                return responder
            }
        }
        return nil
    }
}
