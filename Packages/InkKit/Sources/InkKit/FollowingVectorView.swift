import UIKit

/// A view that draws part of the page as vectors at the canvas's transform (the template, the page's
/// objects, tape), and follows the page as it pans and zooms.
///
/// Redrawing it costs main-thread time in proportion to its size, which mid-pinch means every frame.
/// So while the page is moving it shows what it last drew, scaled and moved to where the page is now,
/// and only draws again when that would look too soft or leave part of the page uncovered
/// (`ViewTransform.canReuse`). Once the page settles it draws crisp at the new transform. Lines are a
/// little thicker or thinner mid-pinch, the way Notability and Xournal++ show a page while zooming.
class FollowingVectorView: UIView {
    /// The transform the view's content was drawn at; subclasses draw at this.
    private(set) var drawnTransform = ViewTransform()
    /// The transform the canvas is at now.
    private(set) var canvasTransform = ViewTransform()

    /// Sizes the view to `rect` in its superview. Use instead of `frame`, which a scaled view can't take.
    func place(in rect: CGRect) {
        bounds = CGRect(origin: .zero, size: rect.size)
        center = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Follows the canvas to `transform`. `moving`: a pan or pinch is under way, so the content drawn
    /// before may be scaled instead of drawn again, as long as it covers the part of `page` (canvas space)
    /// shown in `visible` (view points).
    func follow(_ transform: ViewTransform, moving: Bool, visible: CGRect, page: CGRect) {
        guard transform != canvasTransform || (!moving && transform != drawnTransform) else { return }
        canvasTransform = transform
        if isHidden || bounds.isEmpty {
            drawnTransform = transform
            resetScaling()
            return
        }
        if moving, transform.canReuse(drawnAt: drawnTransform, over: bounds, visible: visible, page: page) {
            let t = transform.layerTransform(from: drawnTransform)
            // `transform` turns about the centre; `layerTransform` maps from the top-left.
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            self.transform = CGAffineTransform(a: t.a, b: 0, c: 0, d: t.d,
                                               tx: t.tx + c.x * (t.a - 1), ty: t.ty + c.y * (t.d - 1))
            return
        }
        redraw()
    }

    /// Draws again at the canvas's current transform.
    func redraw() {
        drawnTransform = canvasTransform
        resetScaling()
        setNeedsDisplay()
    }

    private func resetScaling() {
        if transform != .identity {
            transform = .identity
        }
    }
}
