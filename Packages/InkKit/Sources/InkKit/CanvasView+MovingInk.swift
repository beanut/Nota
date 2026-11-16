import UIKit

// MARK: - Ink while the page moves

extension CanvasView {
    /// While the page pans or zooms, the ink on screen is the last render, moved and scaled with the page
    /// (`updateCommittedLayerTransform`), and it's drawn again only when that falls short: when it no
    /// longer covers the part of the page in this view, or it's shown at more than `movingScaleLimit` times
    /// (or less than the inverse of) the scale it was drawn at. Rendering on every frame instead hands Core
    /// Animation a new view-sized image (tens of megabytes zoomed in) every frame, which is what made
    /// zooming stutter. The ink is drawn sharp again once the movement ends.
    func renderIfShownInkFallsShort() {
        // What will be on screen once the render in flight lands, or what's there now.
        let shown = fullRenderInFlight ? (transform: bitmapTransform, size: bitmapSize)
            : (transform: displayedTransform, size: displayedSize)
        if Self.inkFallsShort(shownAt: shown.transform, size: shown.size, viewTransform: viewTransform,
                              page: document.pageBounds, in: bounds) {
            requestFullRender()
        }
    }

    /// How far the ink may be scaled from the scale it was drawn at while the page moves.
    static let movingScaleLimit: CGFloat = 1.5

    /// Whether ink drawn at `drawn` into an image `size` points large, shown now at `viewTransform`, leaves
    /// part of `page` within `bounds` uncovered or is scaled past `movingScaleLimit`.
    static func inkFallsShort(shownAt drawn: ViewTransform, size: CGSize, viewTransform: ViewTransform,
                              page: CGRect, in bounds: CGRect) -> Bool {
        guard drawn.scale > 0, size.width > 0, size.height > 0 else { return true }
        let k = viewTransform.scale / drawn.scale
        guard k <= movingScaleLimit, k >= 1 / movingScaleLimit else { return true }
        let needed = viewTransform.toView(page).intersection(bounds)
        guard !needed.isNull, !needed.isEmpty else { return false }
        // The image's rectangle in this view: drawn at `drawn`, moved to `viewTransform`.
        let covered = CGRect(origin: .zero, size: size).applying(
            CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: viewTransform.offset.x - drawn.offset.x * k,
                              ty: viewTransform.offset.y - drawn.offset.y * k)
        )
        return !covered.insetBy(dx: -1, dy: -1).contains(needed)
    }
}
