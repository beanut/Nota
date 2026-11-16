import UIKit

/// A canvas layer drawn as vectors at the canvas's transform: the template (`TemplateView`) and the page's
/// objects (`ObjectLayerView`). Redrawing at each new transform keeps lines one crisp width at every zoom
/// instead of scaling a bitmap.
///
/// The view is as large as the canvas (the viewport and its overscan when zoomed in: about 17 megapixels on
/// a 13-inch iPad), and a pan or zoom moves the canvas every frame. A redraw that takes a good part of a
/// frame (a page of pictures, a dense template) on every one of them is what makes zooming stutter. So the
/// view paces itself by what its last draw cost: a cheap draw (`cheapDraw`) still happens every frame,
/// while a dearer one rests for `restPerDraw` times as long as it took, and in between the last drawing
/// moves and scales with the canvas, which costs nothing. It always catches up: when the rest is over
/// (even if the canvas has stopped changing by then), and at once when the movement ends.
class TransformFollowingView: UIView {
    /// A draw this quick is done on every frame.
    static let cheapDraw: CFTimeInterval = 0.002
    /// How long a draw that isn't cheap rests before the next, as a multiple of the time it took, so
    /// drawing takes at most a tenth of the main thread while the canvas moves.
    static let restPerDraw: Double = 9

    /// Where the canvas is.
    private var canvasTransform = ViewTransform()
    /// The transform the contents are drawn at (or will be, at the next display).
    private(set) var drawnTransform = ViewTransform()
    /// No redraw before this, while the canvas is moving.
    private var restsUntil: CFTimeInterval = 0
    /// The view changed size since it was drawn, so part of it may not be drawn at all.
    private var isStale = false
    private var catchUp: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Not `.redraw`: a new size is drawn for when this view chooses (`fill`), like a new transform.
        contentMode = .topLeft
        isHidden = true
        // Scaled about its top-left corner, like the committed ink layer.
        layer.anchorPoint = .zero
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        catchUp?.invalidate()
    }

    /// Covers `rect` of the superview. Used instead of `frame`, which means nothing while the view is
    /// transformed.
    func fill(_ rect: CGRect) {
        let size = CGRect(origin: .zero, size: rect.size)
        if bounds != size {
            bounds = size
            // The canvas changes size in the middle of a pinch and as one ends; a dear draw waits its turn.
            isStale = true
            if CACurrentMediaTime() >= restsUntil {
                redraw()
            } else {
                scheduleCatchUp()
            }
        }
        if center != rect.origin {
            center = rect.origin
        }
    }

    /// Follows the canvas to `transform`. `moving` while a pan or zoom is under way: the redraw may then be
    /// put off (see the type's comment). Without it the view redraws now.
    func follow(_ transform: ViewTransform, moving: Bool = false) {
        canvasTransform = transform
        guard transform != drawnTransform || isStale else {
            place()
            return
        }
        if isHidden || !moving || CACurrentMediaTime() >= restsUntil {
            redraw()
        } else {
            place()
            scheduleCatchUp()
        }
    }

    /// Draws the contents again, at the canvas's transform. Subclasses call this, not `setNeedsDisplay()`.
    func redraw() {
        catchUp?.invalidate()
        catchUp = nil
        isStale = false
        drawnTransform = canvasTransform
        place()
        if !isHidden {
            setNeedsDisplay()
        }
    }

    /// Moves the drawing from where it was drawn to where the canvas is now.
    private func place() {
        let from = drawnTransform, to = canvasTransform
        var t = CGAffineTransform.identity
        if from != to, from.scale > 0 {
            let k = to.scale / from.scale
            t = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: to.offset.x - from.offset.x * k,
                                  ty: to.offset.y - from.offset.y * k)
        }
        guard layer.affineTransform() != t else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(t)
        CATransaction.commit()
    }

    /// Redraws once the rest is over, in case the canvas doesn't change again before the movement ends
    /// (scrolling moves an embedded page without changing its transform).
    private func scheduleCatchUp() {
        guard catchUp == nil else { return }
        let timer = Timer(timeInterval: max(restsUntil - CACurrentMediaTime(), 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.catchUp = nil
                if self.drawnTransform != self.canvasTransform || self.isStale {
                    self.redraw()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common) // also while a scroll is tracking
        catchUp = timer
    }

    /// Draws the contents in view space at `transform`, limited to `rect`.
    func drawContents(at _: ViewTransform, in _: CGRect, context _: CGContext) {}

    override final func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawContents(at: drawnTransform, in: rect, context: ctx)
    }

    /// Times the whole display, not `draw(_:)`: Core Graphics may only record what `draw(_:)` asks for and
    /// do the work (resampling a picture, say) once it has returned, as the layer's backing store is filled.
    private final class TimedLayer: CALayer {
        override func display() {
            let start = CACurrentMediaTime()
            super.display()
            let end = CACurrentMediaTime()
            (delegate as? TransformFollowingView)?.rest(afterDrawTaking: end - start, endingAt: end)
        }
    }

    override class var layerClass: AnyClass {
        TimedLayer.self
    }

    /// A draw that took `duration` ended at `end`: sets how long the next one waits while the canvas moves.
    func rest(afterDrawTaking duration: CFTimeInterval, endingAt end: CFTimeInterval = CACurrentMediaTime()) {
        restsUntil = duration <= Self.cheapDraw ? 0 : end + duration * Self.restPerDraw
    }
}
