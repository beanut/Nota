import Foundation

/// Pixel eraser splits: cutting the ink strokes a pixel-eraser stroke severs into separate strokes.
extension CanvasView {
    /// Ink strokes that `eraser` (about to be appended on top) cuts clean through, with their pieces.
    /// Only strokes overlapping the eraser are examined. Coverage is the union of every pixel eraser
    /// above each stroke that overlaps it, so two partial erases that together sever a line count too.
    /// `hulls` are the eraser's own, reused from its `LiveStroke` (identical to a fresh build once it ended).
    func splits(cutBy eraser: Stroke, hulls eraserOwnHulls: [Hull]) -> [CanvasDocument.Split] {
        let eraserBounds = geometry(for: eraser).bounds
        guard !eraserBounds.isNull else { return [] }
        let strokes = document.strokes
        var eraserHulls: [UUID: [Hull]] = [eraser.id: eraserOwnHulls]
        func hulls(of e: Stroke) -> [Hull] {
            if let h = eraserHulls[e.id] {
                return h
            }
            let h = StrokeRenderer.hulls(for: e.points, style: e.style)
            eraserHulls[e.id] = h
            return h
        }

        var splits: [CanvasDocument.Split] = []
        for (index, stroke) in strokes.enumerated() where stroke.tool != .pixelEraser {
            let bounds = geometry(for: stroke).bounds
            guard bounds.intersects(eraserBounds) else { continue }
            let region = bounds.insetBy(dx: -1, dy: -1)
            var coverage = StrokeSplitter.Coverage()
            for other in strokes[(index + 1)...] where other.tool == .pixelEraser
                && geometry(for: other).bounds.intersects(region) {
                coverage.add(hulls(of: other), within: region)
            }
            coverage.add(hulls(of: eraser), within: region)
            if let pieces = StrokeSplitter.pieces(of: stroke, coverage: coverage) {
                splits.append(CanvasDocument.Split(index: index, original: stroke, pieces: pieces))
            }
        }
        return splits
    }
}
