import SwiftUI
import UIKit

/// Observes the window passively; never competes with SwiftUI buttons or scrolling.
struct MobileActivityObserver: UIViewRepresentable {
  let onActivity: () -> Void
  func makeUIView(context: Context) -> ActivityView {
    let view = ActivityView()
    view.onActivity = onActivity
    view.isUserInteractionEnabled = false
    return view
  }
  func updateUIView(_ view: ActivityView, context: Context) { view.onActivity = onActivity }
  static func dismantleUIView(_ view: ActivityView, coordinator: ()) { view.detach() }

  final class ActivityView: UIView {
    var onActivity: (() -> Void)?
    private var observer: ActivityTouches?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      detach()
      guard let window else { return }
      let touches = ActivityTouches()
      touches.onActivity = { [weak self] in self?.onActivity?() }
      touches.cancelsTouchesInView = false
      touches.delaysTouchesBegan = false
      touches.delaysTouchesEnded = false
      window.addGestureRecognizer(touches)
      observer = touches
      for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(typed(_:)), name: name, object: nil)
      }
    }
    @objc private func typed(_ notification: Notification) {
      guard let input = notification.object as? UIView, input.window === window else { return }
      onActivity?()
    }
    func detach() {
      if let observer { observer.view?.removeGestureRecognizer(observer) }
      observer = nil
      NotificationCenter.default.removeObserver(self)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
  }
  final class ActivityTouches: UIGestureRecognizer {
    var onActivity: (() -> Void)?
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onActivity?() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { onActivity?() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
  }
}
