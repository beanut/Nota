import UIKit

/// The canvas layer that draws the page's objects, between the template and the ink. Like the template,
/// it's redrawn as vectors at the canvas's transform when the page pans or zooms, and while a selection
/// with objects in it is dragged. A page without objects hides it, so ink-only pages draw nothing extra.
final class ObjectLayerView: UIView {
    private(set) var objects: [any PageObject] = []
    private var pageBounds = CGRect.zero
    private var canvasTransform = ViewTransform()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `objects` (lowest `zIndex` first) clipped to the page.
    func show(_ objects: [any PageObject], pageBounds: CGRect) {
        guard !(objects.isEmpty && self.objects.isEmpty && pageBounds == self.pageBounds) else { return }
        self.objects = objects
        self.pageBounds = pageBounds
        isHidden = objects.isEmpty
        setNeedsDisplay()
    }

    /// Follows the canvas to `transform`.
    func follow(_ transform: ViewTransform) {
        guard transform != canvasTransform else { return }
        canvasTransform = transform
        if !isHidden {
            setNeedsDisplay()
        }
    }

    /// Draws the objects in view space at `transform`, limited to `viewRect`. Also part of the live
    /// layer's backdrop under highlighter strokes, so a highlighter previews over an object as it commits.
    func drawObjects(at transform: ViewTransform, viewRect: CGRect, in ctx: CGContext) {
        guard !objects.isEmpty, transform.scale > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(transform.affine)
        PageRenderer.draw(objects, clip: pageBounds, visible: transform.toCanvas(viewRect), in: ctx)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawObjects(at: canvasTransform, viewRect: rect, in: ctx)
    }
}
