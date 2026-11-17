import UIKit

/// The canvas layer that draws the page's objects, between the template and the ink. Like the template,
/// it's redrawn as vectors at the canvas's transform once the page settles after a pan or zoom, and while a selection
/// with objects in it is dragged. A page without objects hides it, so ink-only pages draw nothing extra.
///
/// Pictures never make it wait: it draws the size `ImageAssets` has decoded and redraws when the size it
/// needs arrives (`ImageAssets.didLoadImageNotification`).
final class ObjectLayerView: FollowingVectorView {
    private(set) var objects: [any PageObject] = []
    private var pageBounds = CGRect.zero
    /// The pictures shown, to redraw when one of them finishes decoding.
    private var assetIDs: Set<ImageAssetID> = []
    private var imageObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        isHidden = true
        imageObserver = NotificationCenter.default.addObserver(forName: ImageAssets.didLoadImageNotification,
                                                               object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? ImageAssetID else { return }
            MainActor.assumeIsolated {
                guard let self, self.assetIDs.contains(id), !self.isHidden else { return }
                self.setNeedsDisplay()
            }
        }
    }

    deinit {
        if let imageObserver {
            NotificationCenter.default.removeObserver(imageObserver)
        }
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
        assetIDs = objects.imageAssetIDs
        isHidden = objects.isEmpty
        setNeedsDisplay()
    }

    override var coveredPageRect: CGRect {
        pageBounds
    }

    /// Draws the objects in view space at `transform`, limited to `viewRect`. Also part of the live
    /// layer's backdrop under highlighter strokes, so a highlighter previews over an object as it commits.
    func drawObjects(at transform: ViewTransform, viewRect: CGRect, in ctx: CGContext) {
        guard !objects.isEmpty, transform.scale > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(transform.affine)
        ImageDrawing.with(ImageDrawing.Options(defersDecoding: true)) {
            PageRenderer.draw(objects, clip: pageBounds, visible: transform.toCanvas(viewRect), in: ctx)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawObjects(at: drawnTransform, viewRect: rect, in: ctx)
    }
}
