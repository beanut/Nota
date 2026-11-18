import QuartzCore
import UIKit

/// Objects lifted off their tiles while they move (NOT-109): a selection being dragged, turned or
/// resized, and the shape or tape being drawn. They're drawn once into an image, which is moved with the
/// drag rather than drawn again each frame; it's drawn again only when the drag stretches it past what an
/// image can stand in for (magnified more than 1.5×, or a text box resized, which rewraps it) or the zoom
/// changes that much. Their tiles leave them out meanwhile, and get them back when the drag ends.
@MainActor
final class FloatingObjectsLayer {
    /// Clipped to the page; the host puts it over the layer the objects belong to.
    let layer = CALayer()
    private let content = CALayer()

    /// What the image shows: these objects, moved by `moved`, drawn over `rect` (page points) at
    /// `pixelsPerPoint`.
    private var drawn: Drawn?
    private struct Drawn {
        let objects: [any PageObject]
        let moved: CGAffineTransform
        let rect: CGRect
        let pixelsPerPoint: CGFloat
    }

    private var objects: [any PageObject] = []
    private var moved = CGAffineTransform.identity
    /// Images drawn, for tests.
    private(set) var drawCount = 0
    /// Goes up with every `show`.
    private(set) var generation = 0

    /// The longest side, in pixels, of the image: a big selection at a high zoom is drawn coarser.
    static let maxPixels: CGFloat = 4096
    /// How far the image may be magnified before it's drawn again.
    static let maxMagnification: CGFloat = 1.5

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "transform": NSNull(),
        "contents": NSNull(), "frame": NSNull()
    ]

    init() {
        for layer in [layer, content] {
            layer.anchorPoint = .zero
            layer.actions = Self.noActions
        }
        layer.masksToBounds = true
        layer.isHidden = true
        content.contentsGravity = .resize
        content.magnificationFilter = .linear
        layer.addSublayer(content)
    }

    var isShowing: Bool {
        !objects.isEmpty
    }

    /// Shows `objects` moved by `moved` (page space), or nothing.
    func show(_ objects: [any PageObject], moved: CGAffineTransform = .identity) {
        generation &+= 1
        self.objects = objects
        self.moved = moved
        if objects.isEmpty {
            drawn = nil
        }
    }

    /// Lays the objects out for the page at `t` on a view of `bounds` and `scale` pixels per point, drawing
    /// them again only if the image drawn can't stand in.
    func place(at t: ViewTransform, pageBounds: CGRect, viewBounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !objects.isEmpty, t.scale > 0 else {
            layer.isHidden = true
            content.contents = nil
            drawn = nil
            return
        }
        layer.isHidden = false
        layer.frame = t.toView(pageBounds)
        let ppp = t.scale * scale
        if !reuses(at: ppp) {
            draw(pixelsPerPoint: ppp, visible: t.toCanvas(viewBounds))
        }
        guard let drawn else { return }
        // Image space → page (at the drag drawn) → page now → view → this layer (the page's frame).
        let image = CGAffineTransform(translationX: drawn.rect.minX, y: drawn.rect.minY)
        let since = drawn.moved.inverted().concatenating(moved)
        let frame = layer.frame
        let m = image.concatenating(since).concatenating(t.affine)
            .concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
        content.bounds = CGRect(origin: .zero, size: drawn.rect.size)
        content.position = .zero
        content.setAffineTransform(m)
    }

    /// Whether the image drawn still stands in for the objects as they are now at `ppp`.
    private func reuses(at ppp: CGFloat) -> Bool {
        guard let drawn, drawn.objects.count == objects.count,
              zip(drawn.objects, objects).allSatisfy({ $0.id == $1.id && ObjectDiff.same($0, $1) })
        else { return false }
        let since = drawn.moved.inverted().concatenating(moved)
        let stretch = sqrt(abs(since.a * since.d - since.b * since.c))
        let magnification = stretch * ppp / max(drawn.pixelsPerPoint, 1e-6)
        guard magnification <= Self.maxMagnification, magnification >= 1 / (Self.maxMagnification * 2) else { return false }
        // A text box keeps its letters' size when stretched, and rewraps: an image can't show that.
        if abs(stretch - 1) > 0.001 || abs(since.a - since.d) > 0.001, objects.contains(where: { $0 is TextObject }) {
            return false
        }
        return true
    }

    private func draw(pixelsPerPoint ppp: CGFloat, visible: CGRect) {
        let placed = objects.map { $0.applying(moved) }
        var rect = placed.reduce(CGRect.null) { $0.union(ObjectDiff.reach(of: $1)) }
        // Only what's in view or near it: a huge selection at a high zoom isn't drawn whole.
        let near = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 2)
        rect = rect.intersection(near)
        guard !rect.isNull, !rect.isEmpty else {
            content.contents = nil
            drawn = Drawn(objects: objects, moved: moved, rect: CGRect(x: 0, y: 0, width: 1, height: 1), pixelsPerPoint: ppp)
            return
        }
        var pixels = ppp
        let longest = max(rect.width, rect.height) * pixels
        if longest > Self.maxPixels {
            pixels *= Self.maxPixels / longest
        }
        let width = max(1, Int((rect.width * pixels).rounded(.up))), height = max(1, Int((rect.height * pixels).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: TileBitmap.bitmapInfo)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ImageDrawing.with(ImageDrawing.Options(defersDecoding: true)) {
            PageRenderer.draw(placed, clip: rect, in: ctx)
        }
        content.contents = ctx.makeImage()
        drawn = Drawn(objects: objects, moved: moved, rect: rect, pixelsPerPoint: ppp)
        drawCount += 1
    }
}
