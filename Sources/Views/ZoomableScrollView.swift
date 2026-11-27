// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Tracks the visible normalized center `(0...1)` of `ZoomableScrollView` without triggering SwiftUI re-renders.
final class ZoomViewportTracker {
    var normalizedCenter = CGPoint(x: 0.5, y: 0.5)
}

/// A `UIScrollView`-backed container that provides pinch-to-zoom and free scrolling around
/// arbitrarily tall content. Double-tapping toggles between 1× and 2.2× with the tap point
/// as the zoom center. Supports dynamic 2-finger pan mode while a drawing tool is active.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    private let content: Content
    /// Scale to jump to on a double-tap. 1.0 ↔ zoomedScale.
    var zoomedScale: CGFloat = 2.2
    /// When true, pan requires 2 touches so single-finger drawing gestures pass to content.
    var isDrawingActive: Bool = false
    /// Controls whether double-tap zoom is enabled.
    var isDoubleTapZoomEnabled: Bool = true
    /// Optional tracker updated with the viewport's normalized center on scroll/zoom.
    var viewportTracker: ZoomViewportTracker? = nil
    /// Called when scrolling or pinching begins so any uncommitted 1-finger stroke can cancel.
    var onScrollOrZoomBegan: (() -> Void)? = nil
    /// Optional single-tap callback, deferred until double-tap fails.
    var onSingleTap: (() -> Void)? = nil

    init(
        zoomedScale: CGFloat = 2.2,
        isDrawingActive: Bool = false,
        isDoubleTapZoomEnabled: Bool = true,
        viewportTracker: ZoomViewportTracker? = nil,
        onScrollOrZoomBegan: (() -> Void)? = nil,
        onSingleTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.zoomedScale = zoomedScale
        self.isDrawingActive = isDrawingActive
        self.isDoubleTapZoomEnabled = isDoubleTapZoomEnabled
        self.viewportTracker = viewportTracker
        self.onScrollOrZoomBegan = onScrollOrZoomBegan
        self.onSingleTap = onSingleTap
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false

        let hosting = context.coordinator.hostingController
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        scrollView.addSubview(hosting.view)

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hosting.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.doubleTapRecognizer = doubleTap

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        context.coordinator.singleTapRecognizer = singleTap

        applyTouchPolicy(to: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.zoomedScale = zoomedScale
        context.coordinator.viewportTracker = viewportTracker
        context.coordinator.onScrollOrZoomBegan = onScrollOrZoomBegan
        context.coordinator.onSingleTap = onSingleTap
        applyTouchPolicy(to: scrollView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            hostingController: UIHostingController(rootView: content),
            zoomedScale: zoomedScale,
            viewportTracker: viewportTracker,
            onScrollOrZoomBegan: onScrollOrZoomBegan,
            onSingleTap: onSingleTap
        )
    }

    private func applyTouchPolicy(to scrollView: UIScrollView, coordinator: Coordinator) {
        let targetPanTouches = isDrawingActive ? 2 : 1
        if scrollView.panGestureRecognizer.minimumNumberOfTouches != targetPanTouches {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = targetPanTouches
        }
        let shouldDelay = !isDrawingActive
        if scrollView.delaysContentTouches != shouldDelay {
            scrollView.delaysContentTouches = shouldDelay
        }
        if !scrollView.canCancelContentTouches {
            scrollView.canCancelContentTouches = true
        }
        let enableDoubleTap = !isDrawingActive && isDoubleTapZoomEnabled
        if coordinator.doubleTapRecognizer?.isEnabled != enableDoubleTap {
            coordinator.doubleTapRecognizer?.isEnabled = enableDoubleTap
        }
        let enableSingleTap = !isDrawingActive && (onSingleTap != nil)
        if coordinator.singleTapRecognizer?.isEnabled != enableSingleTap {
            coordinator.singleTapRecognizer?.isEnabled = enableSingleTap
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        var zoomedScale: CGFloat
        weak var viewportTracker: ZoomViewportTracker?
        var onScrollOrZoomBegan: (() -> Void)?
        var onSingleTap: (() -> Void)?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        weak var singleTapRecognizer: UITapGestureRecognizer?

        init(
            hostingController: UIHostingController<Content>,
            zoomedScale: CGFloat,
            viewportTracker: ZoomViewportTracker?,
            onScrollOrZoomBegan: (() -> Void)?,
            onSingleTap: (() -> Void)?
        ) {
            self.hostingController = hostingController
            self.zoomedScale = zoomedScale
            self.viewportTracker = viewportTracker
            self.onScrollOrZoomBegan = onScrollOrZoomBegan
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onScrollOrZoomBegan?()
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            onScrollOrZoomBegan?()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateViewportCenter(in: scrollView)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateViewportCenter(in: scrollView)
        }

        private func updateViewportCenter(in scrollView: UIScrollView) {
            guard let tracker = viewportTracker else { return }
            let contentW = max(1, scrollView.contentSize.width)
            let contentH = max(1, scrollView.contentSize.height)
            let cx = (scrollView.contentOffset.x + scrollView.bounds.width * 0.5) / contentW
            let cy = (scrollView.contentOffset.y + scrollView.bounds.height * 0.5) / contentH
            tracker.normalizedCenter = CGPoint(
                x: min(0.94, max(0.06, cx)),
                y: min(0.94, max(0.06, cy))
            )
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onSingleTap?()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: hostingController.view)
                let scale = zoomedScale
                let w = scrollView.bounds.width / scale
                let h = scrollView.bounds.height / scale
                let zoomRect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}
