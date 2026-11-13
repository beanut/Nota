import CoreGraphics
import Foundation

/// The canvas's committed layer: one screen-resolution bitmap holding every finished stroke.
///
/// `CanvasView` runs `render` on its render queue for every full re-render (opening a page without a
/// `CommittedRaster`, undo, erase, the end of a zoom or pan). The benchmarks call the same code, so what
/// they time is what the canvas does.
///
/// A full render costs about 2 ms of Core Graphics fill per handwritten word at the fitted zoom, so it
/// spreads the work over every core: stroke geometry is built in parallel, then the bitmap is split into
/// horizontal bands that are filled at the same time, each band drawing, in page order, the strokes
/// that reach into it. That is still seconds for a dense page, which is why reopening a page restores
/// its `CommittedRaster` instead.
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
                                  bitmapInfo: bitmapInfo)
        else { return nil }
        ctx.translateBy(x: 0, y: pixelSize.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)
        return ctx
    }

    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Below this many strokes to draw, one thread fills the bitmap: bands only pay off on a busy page.
    static let parallelThreshold = 64

    /// Clears `bounds` (view points) of `ctx` and redraws every item that shows through it at `transform`.
    /// Items without cached geometry have it built here; that geometry is returned so the caller can cache it.
    /// `parallel: false` fills on the calling thread alone, for comparing the two.
    @discardableResult
    static func render(_ items: [Item], into ctx: CGContext, bounds: CGRect,
                       transform: ViewTransform, parallel: Bool = true) -> [(UUID, StrokeGeometry)] {
        let visible = transform.toCanvas(bounds)
        let geometries = buildGeometry(items)
        var computed: [(UUID, StrokeGeometry)] = []
        var drawItems: [DrawItem] = []
        drawItems.reserveCapacity(items.count)
        for (item, geom) in zip(items, geometries) {
            guard let geom else { continue }
            if item.geometry == nil {
                computed.append((item.id, geom))
            }
            if geom.bounds.intersects(visible) {
                drawItems.append(DrawItem(runs: geom.runs, bounds: geom.bounds,
                                          clip: geom.bounds.insetBy(dx: -2, dy: -2),
                                          kind: item.kind, color: item.color))
            }
        }

        if !parallel || drawItems.count < parallelThreshold || !fillInBands(drawItems, into: ctx, bounds: bounds,
                                                                            transform: transform) {
            fill(drawItems, into: ctx, bounds: bounds, transform: transform, patternShift: 0)
        }
        return computed
    }

    private struct DrawItem {
        let runs: [StrokeRun]
        let bounds: CGRect
        let clip: CGRect
        let kind: InkKind
        let color: RGBA
    }

    /// Every stroke's geometry, in order, built on every core.
    static func geometries(for strokes: [Stroke]) -> [StrokeGeometry] {
        let items = strokes.map { Item(id: $0.id, kind: $0.tool, color: $0.color, geometry: nil, stroke: $0) }
        return buildGeometry(items).map { $0! }
    }

    /// Each item's geometry, cached or built, in item order. Building runs on every core.
    private static func buildGeometry(_ items: [Item]) -> [StrokeGeometry?] {
        var result = items.map(\.geometry)
        let missing = items.indices.filter { items[$0].geometry == nil && items[$0].stroke != nil }
        guard !missing.isEmpty else { return result }
        if missing.count < parallelThreshold {
            for i in missing {
                result[i] = StrokeRenderer.geometry(for: items[i].stroke!)
            }
            return result
        }
        // Contiguous slices, several per core so a slice of long strokes doesn't hold up the rest.
        let slices = min(missing.count, ProcessInfo.processInfo.activeProcessorCount * 4)
        result.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: slices) { s in
                for k in (missing.count * s / slices) ..< (missing.count * (s + 1) / slices) {
                    let i = missing[k]
                    out[i] = StrokeRenderer.geometry(for: items[i].stroke!)
                }
            }
        }
        return result
    }

    /// Clears `bounds` of `ctx` and fills `items` into it, in order.
    /// `patternShift`: how far `ctx`'s base space sits above the full bitmap's, in pixels, so the pencil's
    /// paper tooth lines up across bands.
    private static func fill(_ items: [DrawItem], into ctx: CGContext, bounds: CGRect, transform: ViewTransform,
                             patternShift: CGFloat) {
        ctx.clear(bounds)
        ctx.saveGState()
        ctx.concatenate(transform.affine)
        PencilTexture.prepareContext(ctx, phase: CGPoint(x: transform.offset.x,
                                                         y: transform.offset.y - patternShift))
        for item in items {
            StrokeRenderer.draw(runs: item.runs, clip: item.clip, kind: item.kind, color: item.color, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Fills `items` into `ctx` band by band, the bands in parallel. Each band is a context over the same
    /// pixels, so nothing is copied, and every pixel belongs to exactly one band, so the bands' edges
    /// never show. Returns false, having drawn nothing, when `ctx` isn't a bitmap this can split.
    private static func fillInBands(_ items: [DrawItem], into ctx: CGContext, bounds: CGRect,
                                    transform: ViewTransform) -> Bool {
        guard let base = ctx.data, ctx.bitmapInfo.rawValue == bitmapInfo, ctx.bitsPerPixel == 32,
              let space = ctx.colorSpace
        else { return false }
        let width = ctx.width, height = ctx.height, bytesPerRow = ctx.bytesPerRow
        // View points → the full bitmap's pixels (bottom-left origin), as `makeBitmap` set it up.
        let toPixels = ctx.ctm
        let fromPixels = toPixels.inverted()
        let bands = min(height, ProcessInfo.processInfo.activeProcessorCount * 3)
        // Which bands each item reaches, by its bounds in pixel rows from the top.
        let toView = transform.affine.concatenating(toPixels)
        var bandItems = [[DrawItem]](repeating: [], count: bands)
        for item in items {
            let px = item.clip.applying(toView)
            let top = Int((CGFloat(height) - px.maxY).rounded(.down)), bottom = Int((CGFloat(height) - px.minY).rounded(.up))
            let first = max(0, top * bands / height), last = min(bands - 1, max(0, bottom) * bands / height)
            guard first <= last else { continue }
            for b in first ... last {
                bandItems[b].append(item)
            }
        }

        // The band's base space is the full bitmap's moved down by the rows below the band.
        struct Band {
            let ctx: CGContext
            let shift: CGFloat // pixels between the band's bottom and the bitmap's
            let rows: CGRect // the band in view points
        }
        var contexts: [Band] = []
        for b in 0 ..< bands {
            let top = height * b / bands, bottom = height * (b + 1) / bands
            guard let band = CGContext(data: base + top * bytesPerRow, width: width, height: bottom - top,
                                       bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                                       bitmapInfo: bitmapInfo)
            else { return false }
            let shift = CGFloat(height - bottom)
            band.concatenate(toPixels.concatenating(CGAffineTransform(translationX: 0, y: -shift)))
            band.setShouldAntialias(true)
            let rows = CGRect(x: 0, y: shift, width: CGFloat(width), height: CGFloat(bottom - top))
                .applying(fromPixels)
            contexts.append(Band(ctx: band, shift: shift, rows: rows))
        }
        DispatchQueue.concurrentPerform(iterations: bands) { b in
            let band = contexts[b]
            fill(bandItems[b], into: band.ctx, bounds: bounds.intersection(band.rows), transform: transform,
                 patternShift: band.shift)
        }
        return true
    }
}
