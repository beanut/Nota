import CoreGraphics
@testable import InkKit

/// The strokes drawn whole, in one bitmap the size of a view, at `transform`: what assembled tiles are held
/// to. The canvas never draws like this (it fills tiles); it's the plainest picture of the page to check
/// them against. Its grain phase follows `transform`'s offset rather than the page's pixel origin, so
/// grain differs from tiles by more than those checks allow.
func wholePageImage(of strokes: [Stroke], bounds: CGRect, transform: ViewTransform, scale: CGFloat) -> CGImage? {
    let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    guard let ctx = TileBitmap.viewBitmap(pixelSize: pixels, scale: scale) else { return nil }
    let visible = transform.toCanvas(bounds)
    ctx.concatenate(transform.affine)
    PencilTexture.prepareContext(ctx, phase: transform.offset)
    for stroke in strokes {
        let geometry = StrokeRenderer.geometry(for: stroke)
        guard geometry.bounds.intersects(visible) else { continue }
        StrokeRenderer.draw(runs: geometry.runs, clip: geometry.bounds.insetBy(dx: -2, dy: -2), brush: stroke.brush,
                            color: stroke.color, in: ctx)
    }
    return ctx.makeImage()
}
