import CoreGraphics
import Foundation

/// A page's ink frozen at one revision. Snapshots are plain values, so they can be rendered off the
/// main actor while the page keeps changing.
public struct PageSnapshot: Sendable {
    public let pageID: UUID
    /// The page's `revision` when the snapshot was taken.
    public let revision: Int
    public let pageSize: PageSize
    let strokes: [Stroke]

    /// True when the page has no ink to draw.
    public var isBlank: Bool {
        !strokes.contains { $0.tool != .pixelEraser }
    }
}

public extension CanvasDocument {
    /// The page's current ink, for rendering elsewhere (see `PageRenderer`).
    func snapshot() -> PageSnapshot {
        PageSnapshot(pageID: id, revision: revision, pageSize: pageSize, strokes: strokes)
    }
}

/// Draws a page's ink with the same `StrokeRenderer` geometry the canvas uses, for thumbnails and other
/// still images. Safe to call from any thread.
public enum PageRenderer {
    /// Draws the page's ink into `ctx`, which must already map canvas space (points from the page's
    /// top-left, y down) onto the destination.
    ///
    /// Ink is composited as one layer over whatever `ctx` already holds, so the pixel eraser removes ink
    /// only and never the paper or template drawn underneath. Ink beyond the page edge is clipped.
    public static func drawInk(_ page: PageSnapshot, in ctx: CGContext) {
        guard !page.isBlank else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: page.pageSize.bounds)
        PencilTexture.prepareContext(ctx)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for stroke in page.strokes {
            let geometry = StrokeRenderer.geometry(for: stroke)
            guard geometry.bounds.intersects(page.pageSize.bounds) else { continue }
            StrokeRenderer.draw(runs: geometry.runs, clip: geometry.bounds.insetBy(dx: -2, dy: -2),
                                kind: stroke.tool, color: stroke.color, in: ctx)
        }
        ctx.endTransparencyLayer()
    }

    /// The page rendered `pixelWidth` pixels wide (height follows the page's aspect ratio) in sRGB.
    /// `background` draws first, in pixel space with the origin at the top-left: fill the paper and its
    /// template there. Returns nil if the bitmap can't be created.
    public static func image(of page: PageSnapshot,
                             pixelWidth: Int,
                             background: (CGContext, CGSize) -> Void = { _, _ in }) -> CGImage? {
        let width = max(1, pixelWidth)
        let height = max(1, Int((CGFloat(width) * page.pageSize.height / page.pageSize.width).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Flip to UIKit's top-left origin, which canvas space shares.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        background(ctx, CGSize(width: width, height: height))
        let scale = CGFloat(width) / page.pageSize.width
        ctx.scaleBy(x: scale, y: scale)
        drawInk(page, in: ctx)
        return ctx.makeImage()
    }
}
