import CoreGraphics
import Foundation

/// The canvas's committed layer: one screen-resolution bitmap holding every finished stroke.
///
/// `CanvasView` runs `render` on its render queue for every full re-render (opening a page, undo, erase,
/// the end of a zoom or pan). The benchmarks call the same code, so what they time is what the canvas does.
enum CommittedRenderer {
    /// One stroke to draw: its geometry if the canvas has it cached, otherwise the stroke to build it from.
    struct Item {
        let id: UUID
        let kind: InkKind
        let color: RGBA
        let geometry: StrokeGeometry?
        let stroke: Stroke?
    }

    /// A bitmap `pixelSize` pixels big, addressed in view points with UIKit's top-left origin.
    static func makeBitmap(pixelSize: CGSize, scale: CGFloat) -> CGContext? {
        guard pixelSize.width > 0, pixelSize.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: Int(pixelSize.width),
                                  height: Int(pixelSize.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: pixelSize.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)
        return ctx
    }

    /// Clears `bounds` (view points) of `ctx` and redraws every item that shows through it at `transform`.
    /// Items without cached geometry have it built here; that geometry is returned so the caller can cache it.
    @discardableResult
    static func render(_ items: [Item], into ctx: CGContext, bounds: CGRect,
                       transform: ViewTransform) -> [(UUID, StrokeGeometry)] {
        let visible = transform.toCanvas(bounds)
        var computed: [(UUID, StrokeGeometry)] = []

        struct DrawItem {
            let runs: [StrokeRun]
            let clip: CGRect
            let kind: InkKind
            let color: RGBA
        }
        var drawItems: [DrawItem] = []
        drawItems.reserveCapacity(items.count)

        for item in items {
            let geom: StrokeGeometry
            if let cached = item.geometry {
                geom = cached
            } else if let stroke = item.stroke {
                geom = StrokeRenderer.geometry(for: stroke)
                computed.append((item.id, geom))
            } else {
                continue
            }
            if geom.bounds.intersects(visible) {
                drawItems.append(DrawItem(runs: geom.runs, clip: geom.bounds.insetBy(dx: -2, dy: -2),
                                          kind: item.kind, color: item.color))
            }
        }

        ctx.clear(bounds)
        ctx.saveGState()
        ctx.concatenate(transform.affine)
        PencilTexture.prepareContext(ctx, phase: transform.offset)
        for item in drawItems {
            StrokeRenderer.draw(runs: item.runs, clip: item.clip, kind: item.kind, color: item.color, in: ctx)
        }
        ctx.restoreGState()
        return computed
    }
}
