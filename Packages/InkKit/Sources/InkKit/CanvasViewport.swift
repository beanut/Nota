import CoreGraphics
import QuartzCore

/// A canvas's pan and zoom, as state and rules with no views: the transform, where it stood when the
/// fingers came down, the gestures under way, and the slide back to the fitted page. `CanvasView+Viewport`
/// applies it to the layers and asks the `RenderCoordinator` for ink at the transform.
struct CanvasViewport {
    /// Canvas → view mapping, set by the view's own pan and zoom, or by the host while embedded. The
    /// steps of a pan or pinch keep its offset on whole device pixels (see `pan(by:displayScale:)`).
    var transform: ViewTransform {
        get { shown }
        set {
            shown = newValue
            exact = newValue
        }
    }

    /// What's shown: `exact` with its offset snapped to device pixels while a gesture moves it.
    private var shown = ViewTransform()
    /// Where the gesture's steps have taken the page, unrounded, so slow pans and pinches don't lose
    /// their sub-pixel movement to the rounding.
    private var exact = ViewTransform()

    /// The transform when the current touch sequence's first finger came down, to go back to when a
    /// multi-finger tap or swipe (undo, redo) turns out not to be a pan or pinch.
    var gestureStartTransform = ViewTransform()
    /// Pans and pinches under way.
    var activeGestureCount = 0
    var didTransformInTouchSequence = false
    /// True while `cancelIncidentalPanZoom` resets the recognizers, whose `ended` callbacks are then ignored.
    var isCancellingGesture = false
    /// Most fingers down at once since the last time none were; a three-finger swipe is undo/redo, not a page turn.
    var maxDirectTouchesInSequence = 0
    var didPinchInSequence = false
    /// Total movement of the current pan, for page swipes (the recognizer's translation is reset every frame).
    var panTranslation = CGPoint.zero

    /// The short slide back to the fitted page after a swipe that didn't turn the page, while it runs.
    var slide: Slide?

    struct Slide {
        static let duration: CFTimeInterval = 0.25

        let from: ViewTransform
        let to: ViewTransform
        let start: CFTimeInterval

        /// Where the slide is at `time`, and whether it has arrived.
        func transform(at time: CFTimeInterval) -> (transform: ViewTransform, done: Bool) {
            let t = min((time - start) / Self.duration, 1)
            let e = 1 - pow(1 - t, 3) // ease out
            let transform = ViewTransform(
                scale: from.scale + (to.scale - from.scale) * e,
                offset: CGPoint(x: from.offset.x + (to.offset.x - from.offset.x) * e,
                                y: from.offset.y + (to.offset.y - from.offset.y) * e)
            )
            return (transform, t >= 1)
        }
    }

    /// One frame of a pan: moves the page by `translation` (view points). The transform shown has its
    /// offset on whole device pixels (`displayScale` per point; 0 doesn't round), so the gesture's last
    /// step is already where it settles and the render for it is the one that stays.
    mutating func pan(by translation: CGPoint, displayScale: CGFloat) {
        exact.offset.x += translation.x
        exact.offset.y += translation.y
        shown = exact.snapped(toPixels: displayScale)
    }

    /// One frame of a pinch: zooms by `scale` about `focus` (view points), clamped to the zoom range of
    /// `fitted`, the transform that shows the whole page. Rounded as `pan(by:displayScale:)` is.
    mutating func zoom(by scale: CGFloat, about focus: CGPoint, fitted: ViewTransform, displayScale: CGFloat) {
        var transform = exact
        defer {
            exact = transform
            shown = transform.snapped(toPixels: displayScale)
        }
        let range = ViewTransform.zoomRange(fitScale: fitted.scale)
        let newScale = min(max(transform.scale * scale, range.lowerBound), range.upperBound)
        let oldScale = transform.scale
        let k = newScale / oldScale
        // Zoom about the pinch centroid: keep the canvas point under it fixed.
        transform.offset = CGPoint(x: focus.x - (focus.x - transform.offset.x) * k,
                                   y: focus.y - (focus.y - transform.offset.y) * k)
        transform.scale = newScale
        // Near the zoom-out limit, ease the page back to the centre so it lands exactly on the fitted
        // view rather than stopping wherever the pinch left it.
        let pull = ViewTransform.recentringAmount(from: oldScale, to: newScale, fitScale: fitted.scale)
        if pull > 0 {
            transform.offset = CGPoint(x: transform.offset.x + (fitted.offset.x - transform.offset.x) * pull,
                                       y: transform.offset.y + (fitted.offset.y - transform.offset.y) * pull)
        }
    }

    /// The last pan or pinch ended: the transform settles with its offset on whole device pixels, so the
    /// committed ink's pixel grid lands on the screen's (which the tiled committed layer relies on).
    /// The steps already round, so this only moves a transform set some other way. Returns whether it did.
    mutating func settleOnPixelGrid(displayScale: CGFloat) -> Bool {
        let snapped = transform.snapped(toPixels: displayScale)
        guard snapped != transform else { return false }
        transform = snapped
        return true
    }
}

extension ViewTransform {
    /// The same scale with the offset rounded to whole device pixels (`displayScale` pixels per point).
    /// Snapping twice gives the same transform.
    func snapped(toPixels displayScale: CGFloat) -> ViewTransform {
        guard displayScale > 0, displayScale.isFinite else { return self }
        return ViewTransform(scale: scale,
                             offset: CGPoint(x: (offset.x * displayScale).rounded() / displayScale,
                                             y: (offset.y * displayScale).rounded() / displayScale))
    }
}
