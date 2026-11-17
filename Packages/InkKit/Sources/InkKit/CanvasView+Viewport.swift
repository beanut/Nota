import CoreGraphics

// MARK: - Pan and zoom steps

/// One frame of the canvas's own pan and pinch (`handlePan`, `handlePinch`), between `gestureBegan()` and
/// `gestureEnded()`. The canvas benchmarks drive gestures through these too.
extension CanvasView {
    /// One frame of a pan: moves the page by `translation` (view points), as the pan gesture does.
    func pan(by translation: CGPoint) {
        viewTransform.offset.x += translation.x
        viewTransform.offset.y += translation.y
        transformDidChange()
    }

    /// One frame of a pinch: zooms by `scale` about `focus` (view points), clamped to the zoom range, as
    /// the pinch gesture does.
    func zoom(by scale: CGFloat, about focus: CGPoint) {
        let fitted = fittedTransform()
        let range = ViewTransform.zoomRange(fitScale: fitted.scale)
        let newScale = min(max(viewTransform.scale * scale, range.lowerBound), range.upperBound)
        let oldScale = viewTransform.scale
        let k = newScale / oldScale
        // Zoom about the pinch centroid: keep the canvas point under it fixed.
        viewTransform.offset = CGPoint(x: focus.x - (focus.x - viewTransform.offset.x) * k,
                                       y: focus.y - (focus.y - viewTransform.offset.y) * k)
        viewTransform.scale = newScale
        // Near the zoom-out limit, ease the page back to the centre so it lands exactly on the fitted
        // view rather than stopping wherever the pinch left it.
        let pull = ViewTransform.recentringAmount(from: oldScale, to: newScale, fitScale: fitted.scale)
        if pull > 0 {
            viewTransform.offset = CGPoint(x: viewTransform.offset.x + (fitted.offset.x - viewTransform.offset.x) * pull,
                                           y: viewTransform.offset.y + (fitted.offset.y - viewTransform.offset.y) * pull)
        }
        transformDidChange()
    }
}
