import UIKit

// MARK: - Viewport

/// The canvas's own pan and zoom (`CanvasViewport` holds the state and rules): the gestures' steps, the
/// fitted transform, page swipes and the slide back to the fitted page. The committed ink follows through
/// the `RenderCoordinator`; the live layer, the page chrome and the overlays are moved here.
extension CanvasView {
    /// The transform that fits the whole page between the margins, on whole device pixels; while
    /// embedded, where the host put it.
    func fittedTransform() -> ViewTransform {
        if isEmbedded {
            return placement
        }
        let s = safeAreaInsets, m = controller?.pageMargins ?? CanvasController.defaultPageMargins
        var insets = UIEdgeInsets(top: s.top + m.top, left: s.left + m.left,
                                  bottom: s.bottom + m.bottom, right: s.right + m.right)
        if zoomPanel != nil {
            // The page sits above the writing panel, so the zoom box is never under it.
            insets.bottom = bounds.maxY - zoomPanelFrame().minY + Self.zoomPanelGap
        }
        return ViewTransform.fitting(page: document.pageBounds, in: bounds, insets: insets,
                                     scaleRange: .leastNonzeroMagnitude ... .greatestFiniteMagnitude)
            .snapped(toPixels: displayScale)
    }

    // MARK: Pan and zoom steps

    /// One frame of a pan: moves the page by `translation` (view points), as the pan gesture does. The
    /// canvas benchmarks drive gestures through this and `zoom(by:about:)` too, between `gestureBegan()`
    /// and `gestureEnded()`.
    func pan(by translation: CGPoint) {
        viewport.pan(by: translation, displayScale: displayScale)
        transformDidChange()
    }

    /// One frame of a pinch: zooms by `scale` about `focus` (view points), clamped to the zoom range, as
    /// the pinch gesture does.
    func zoom(by scale: CGFloat, about focus: CGPoint) {
        viewport.zoom(by: scale, about: focus, fitted: fittedTransform(), displayScale: displayScale)
        transformDidChange()
    }

    /// A pan or pinch began (`pan(by:)`, `zoom(by:about:)` follow, then `gestureEnded()`).
    func gestureBegan() {
        finishSettling()
        if viewport.activeGestureCount == 0, !viewport.didTransformInTouchSequence {
            viewport.gestureStartTransform = viewTransform
        }
        viewport.activeGestureCount += 1
    }

    /// A pan or pinch ended: once the last one has, the transform settles on the pixel grid and the ink is
    /// drawn sharp at it.
    func gestureEnded() {
        viewport.activeGestureCount = max(0, viewport.activeGestureCount - 1)
        guard !viewport.isCancellingGesture, viewport.activeGestureCount == 0 else { return }
        // Ending within 2% of a zoom already drawn (the fitted page, the last zoom) snaps to it, so its
        // tiles are reused rather than a level a hair away filled from scratch.
        var moved = false
        if let cached = coordinator.cachedScale(near: viewTransform.scale), cached != viewTransform.scale {
            viewport.zoom(by: cached / viewTransform.scale, about: CGPoint(x: bounds.midX, y: bounds.midY),
                          fitted: fittedTransform(), displayScale: displayScale)
            moved = true
        }
        if viewport.settleOnPixelGrid(displayScale: displayScale) || moved {
            updatePageChrome()
            updateLassoOverlay()
            controller?.zoomDidChange(viewTransform.scale)
        }
        liveView.settle(at: viewTransform)
        coordinator.requestRender()
    }

    /// The view transform changed under a gesture: moves the layers and asks for a render at it.
    func transformDidChange() {
        viewport.didTransformInTouchSequence = true
        updatePageChrome()
        liveView.follow(viewTransform)
        updateLassoOverlay()
        coordinator.requestRender()
        controller?.zoomDidChange(viewTransform.scale)
    }

    // MARK: Gestures

    @objc func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if g.state == .began {
                gestureBegan()
                viewport.panTranslation = .zero
            }
            let t = g.translation(in: self)
            viewport.panTranslation.x += t.x
            viewport.panTranslation.y += t.y
            g.setTranslation(.zero, in: self)
            pan(by: t)
        case .ended:
            gestureEnded()
            if !turnPageIfSwiped(velocity: g.velocity(in: self)) {
                settleIfFitted()
            }
        case .cancelled, .failed:
            gestureEnded()
        default:
            break
        }
    }

    @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if g.state == .began {
                gestureBegan()
            }
            if abs(g.scale - 1) > 0.01 {
                viewport.didPinchInSequence = true
            }
            zoom(by: g.scale, about: g.location(in: self))
            g.scale = 1
        case .ended, .cancelled, .failed:
            gestureEnded()
        default:
            break
        }
    }

    /// Turns the page after a sideways swipe, but only while the whole page is in view: zoomed in, a pan
    /// scrolls around the page instead. Pinches and three-finger swipes (undo/redo) never turn the page.
    /// Returns whether the swipe was handed on to turn the page.
    private func turnPageIfSwiped(velocity: CGPoint) -> Bool {
        guard viewport.maxDirectTouchesInSequence <= 2, !viewport.didPinchInSequence, isAtFittedZoom,
              let swipe = PageSwipe.detect(translation: viewport.panTranslation, velocity: velocity,
                                           viewWidth: bounds.width),
              let controller, controller.canSwipe(swipe)
        else { return false }
        controller.swipeToPage(swipe)
        return true
    }

    private var isAtFittedZoom: Bool {
        viewTransform.scale <= fittedTransform().scale * 1.02
    }

    // MARK: Sliding back to the fitted page

    /// While the whole page is in view there's nothing to pan to, so a drag that didn't turn the page
    /// (too short, or past the first or last page) slides the page back to the centre.
    private func settleIfFitted() {
        guard isAtFittedZoom, viewport.activeGestureCount == 0 else { return }
        let target = fittedTransform()
        guard target != viewTransform else { return }
        settleLink?.invalidate()
        viewport.slide = CanvasViewport.Slide(from: viewTransform, to: target, start: CACurrentMediaTime())
        let link = CADisplayLink(target: self, selector: #selector(stepSettling(_:)))
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    @objc private func stepSettling(_: CADisplayLink) {
        guard let slide = viewport.slide else { return }
        let step = slide.transform(at: CACurrentMediaTime())
        viewTransform = step.transform
        coordinator.updateLayerTransform()
        updatePageChrome()
        liveView.follow(viewTransform)
        updateLassoOverlay()
        if step.done {
            finishSettling()
        }
    }

    /// Jumps to the end of the slide back, if one is running.
    func finishSettling() {
        guard let link = settleLink else { return }
        link.invalidate()
        settleLink = nil
        if let slide = viewport.slide {
            viewTransform = slide.to
        }
        viewport.slide = nil
        coordinator.updateLayerTransform()
        updatePageChrome()
        liveView.settle(at: viewTransform)
        updateLassoOverlay()
        coordinator.requestRender()
        controller?.zoomDidChange(viewTransform.scale)
    }

    /// Cancels any incidental pan/pinch from multi-finger taps or swipes and restores the transform from
    /// before them. Returns true if the transform was reverted and needs a full render when undo/redo is a no-op.
    func cancelIncidentalPanZoom() -> Bool {
        guard viewport.activeGestureCount > 0 || viewport.didTransformInTouchSequence else { return false }
        viewport.isCancellingGesture = true
        for r in [pan, pinch] as [UIGestureRecognizer] {
            r.isEnabled = false
            r.isEnabled = true
        }
        viewport.isCancellingGesture = false
        viewport.activeGestureCount = 0
        viewport.didTransformInTouchSequence = false
        viewTransform = viewport.gestureStartTransform
        coordinator.discardInFlight()
        coordinator.updateLayerTransform()
        updatePageChrome()
        liveView.settle(at: viewTransform)
        controller?.zoomDidChange(viewTransform.scale)
        return !coordinator.isSettled
    }
}
