import CoreGraphics
import Foundation

/// Hooks for packages that build on InkKit to put ink on a page in their own tests, where there's no
/// Pencil to draw with. Import with `@_spi(Testing) import InkKit`; the app never uses them.
@_spi(Testing)
public extension CanvasDocument {
    /// Draws a straight pen stroke through `points` (canvas space) as one undoable edit, as if the user had.
    func drawTestStroke(through points: [CGPoint]) {
        let samples = points.enumerated().map { i, point in
            StrokePoint(location: point, force: 0.5, altitude: .pi / 2, azimuth: 0, timestamp: Double(i))
        }
        add(Stroke(id: UUID(), color: RGBA.swatches[0], brush: .pen, points: samples))
    }

    /// Undoes the page's last edit, as the undo button would.
    func undoForTesting() {
        undo()
    }
}
