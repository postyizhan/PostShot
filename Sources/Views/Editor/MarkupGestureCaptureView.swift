// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Captures strictly single-finger drawing gestures in normalized (`0...1`) coordinates,
/// automatically cancelling an uncommitted stroke if a second touch joins for 2-finger pan/zoom.
struct MarkupGestureCaptureView: UIViewRepresentable {
    var isEnabled: Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> CaptureContainerView {
        let view = CaptureContainerView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let recognizer = SingleFingerDrawRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDraw(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        context.coordinator.recognizer = recognizer
        syncState(view: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: CaptureContainerView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        syncState(view: uiView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded, onCancelled: onCancelled)
    }

    private func syncState(view: CaptureContainerView, coordinator: Coordinator) {
        view.isCaptureEnabled = isEnabled
        view.isUserInteractionEnabled = isEnabled
        coordinator.recognizer?.isEnabled = isEnabled
    }

    final class CaptureContainerView: UIView {
        var isCaptureEnabled = false

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            isCaptureEnabled && super.point(inside: point, with: event)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var recognizer: SingleFingerDrawRecognizer?
        var onBegan: (CGPoint) -> Void
        var onChanged: (CGPoint) -> Void
        var onEnded: () -> Void
        var onCancelled: () -> Void

        init(
            onBegan: @escaping (CGPoint) -> Void,
            onChanged: @escaping (CGPoint) -> Void,
            onEnded: @escaping () -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPanGestureRecognizer
        }

        @objc func handleDraw(_ gesture: SingleFingerDrawRecognizer) {
            switch gesture.state {
            case .began:
                if let pt = gesture.currentNormalizedPoint { onBegan(pt) }
            case .changed:
                if let pt = gesture.currentNormalizedPoint { onChanged(pt) }
            case .ended:
                onEnded()
            case .cancelled, .failed:
                onCancelled()
            default:
                break
            }
        }
    }
}

final class SingleFingerDrawRecognizer: UIGestureRecognizer {
    private var activeTouch: UITouch?
    private(set) var currentNormalizedPoint: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if activeTouch != nil || activeTouchCount(in: event) > 1 || touches.count > 1 {
            cancelActiveStrokeIfNeeded()
            return
        }
        guard let touch = touches.first else {
            state = .failed
            return
        }
        activeTouch = touch
        currentNormalizedPoint = normalizedPoint(for: touch)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if activeTouchCount(in: event) > 1 {
            cancelActiveStrokeIfNeeded()
            return
        }
        guard let activeTouch, touches.contains(activeTouch) else { return }
        currentNormalizedPoint = normalizedPoint(for: activeTouch)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let activeTouch, touches.contains(activeTouch) else { return }
        currentNormalizedPoint = normalizedPoint(for: activeTouch)
        self.activeTouch = nil
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        cancelActiveStrokeIfNeeded()
    }

    override func reset() {
        super.reset()
        activeTouch = nil
        currentNormalizedPoint = nil
    }

    private func cancelActiveStrokeIfNeeded() {
        let hadTouch = (activeTouch != nil)
        activeTouch = nil
        currentNormalizedPoint = nil
        state = hadTouch ? .cancelled : .failed
    }

    private func activeTouchCount(in event: UIEvent?) -> Int {
        guard let all = event?.allTouches else { return 0 }
        return all.reduce(0) { count, touch in
            (touch.phase != .ended && touch.phase != .cancelled) ? count + 1 : count
        }
    }

    private func normalizedPoint(for touch: UITouch) -> CGPoint {
        guard let view else { return .zero }
        let loc = touch.location(in: view)
        let w = max(1, view.bounds.width)
        let h = max(1, view.bounds.height)
        return CGPoint(x: min(1, max(0, loc.x / w)), y: min(1, max(0, loc.y / h)))
    }
}
