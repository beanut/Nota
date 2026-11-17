import UIKit

/// A view drawn as vectors at the canvas's transform (the template, the page's objects) that follows the
/// committed ink's settle rule (NOT-105): settled, it's drawn sharp at the transform; while the view moves
/// (a pan, a pinch, a scroll) it scales and moves what it last drew instead of drawing again every frame,
/// and draws again only once that no longer covers the page in view or is magnified past `maxMagnification`.
/// So paper, objects and ink sharpen together when the fingers lift.
///
/// Subclasses draw at `drawnTransform` in `draw(_:)`, and say which part of the page they cover
/// (`coveredPageRect`). Any `setNeedsDisplay()` draws again at the current transform. Size it with
/// `fill(_:)`, not `frame`, as it may carry a transform.
class FollowingVectorView: UIView {
    /// How far what was drawn may be magnified mid-gesture before it's drawn again.
    static let maxMagnification: CGFloat = 1.5

    /// The transform the view follows.
    private(set) var canvasTransform = ViewTransform()
    /// The transform its content was last drawn at.
    private(set) var drawnTransform = ViewTransform()

    /// The page rect (page points) the view draws in; outside it nothing shows, so it needn't be covered.
    var coveredPageRect: CGRect {
        .null
    }

    /// Sizes the view to `rect` in its superview, whatever transform it carries.
    func fill(_ rect: CGRect) {
        bounds = CGRect(origin: .zero, size: rect.size)
        center = CGPoint(x: rect.midX, y: rect.midY)
        placeContent()
    }

    override func setNeedsDisplay() {
        drawnTransform = canvasTransform
        if !layer.affineTransform().isIdentity {
            layer.setAffineTransform(.identity)
        }
        super.setNeedsDisplay()
    }

    /// Follows the canvas to `transform`; `moving` while a gesture or scroll is under way.
    func follow(_ transform: ViewTransform, moving: Bool) {
        guard transform != canvasTransform || (!moving && drawnTransform != transform) else { return }
        canvasTransform = transform
        guard !isHidden else {
            drawnTransform = transform
            return
        }
        if moving, reuses(drawnTransform, at: transform) {
            placeContent()
        } else {
            setNeedsDisplay()
        }
    }

    /// Whether what was drawn at `drawn` can stand in, scaled, at `t`: not magnified past
    /// `maxMagnification`, and still covering the page in view.
    func reuses(_ drawn: ViewTransform, at t: ViewTransform) -> Bool {
        guard drawn.scale > 0, t.scale / drawn.scale <= Self.maxMagnification else { return false }
        let page = coveredPageRect
        guard !page.isNull else { return true }
        let needed = t.toView(page).intersection(bounds)
        guard !needed.isNull, !needed.isEmpty else { return true }
        // What was drawn covers the view in its own coordinates: where that lands now.
        let drawnArea = t.toView(drawn.toCanvas(bounds))
        return drawnArea.insetBy(dx: -0.5, dy: -0.5).contains(needed)
    }

    /// Scales and moves the drawn content to where `canvasTransform` puts it.
    private func placeContent() {
        let d = drawnTransform, t = canvasTransform
        guard d != t, d.scale > 0 else {
            if !layer.affineTransform().isIdentity {
                layer.setAffineTransform(.identity)
            }
            return
        }
        // A point drawn at `v` in the view belongs at k·v + (t.offset − k·d.offset); the layer's transform
        // applies about its centre `c`.
        let k = t.scale / d.scale, c = CGPoint(x: bounds.midX, y: bounds.midY)
        let tx = t.offset.x - k * d.offset.x + (k - 1) * c.x
        let ty = t.offset.y - k * d.offset.y + (k - 1) * c.y
        layer.setAffineTransform(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: tx, ty: ty))
    }
}
