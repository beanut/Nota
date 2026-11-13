import CoreGraphics
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
            let h = StrokeRenderer.hulls(for: e.points, brush: e.brush)
            eraserHulls[e.id] = h
            return h
        }

        var splits: [CanvasDocument.Split] = []
        for (index, stroke) in strokes.enumerated() where !stroke.brush.erases {
            let bounds = geometry(for: stroke).bounds
            guard bounds.intersects(eraserBounds) else { continue }
            let region = bounds.insetBy(dx: -1, dy: -1)
            var coverage = StrokeSplitter.Coverage()
            for other in strokes[(index + 1)...] where other.brush.erases
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

    /// Stroke eraser: removes the ink strokes the eraser sweeps through.
    func eraseStrokes(along point: CGPoint) {
        guard var session = eraseSession, let controller else { return }
        let radius = CGFloat(controller.current.width) / 2 / inputTransform.scale
        let from = session.last ?? point
        let steps = max(1, Int((from.distance(to: point) / (radius * 0.5)).rounded(.up)))
        let sweep = CGRect(x: min(from.x, point.x), y: min(from.y, point.y),
                           width: abs(from.x - point.x), height: abs(from.y - point.y))
            .insetBy(dx: -radius, dy: -radius)

        var hits = Set<UUID>()
        // Pixel-eraser strokes are invisible; removing them would resurrect ink, so they're skipped.
        for stroke in document.strokes where !stroke.brush.erases {
            let bounds = geometry(for: stroke).bounds
            guard bounds.intersects(sweep) else { continue }
            for k in 0 ... steps {
                let t = CGFloat(k) / CGFloat(steps)
                if StrokeRenderer.hitTest(stroke, bounds: bounds, point: from + (point - from) * t, radius: radius) {
                    hits.insert(stroke.id)
                    break
                }
            }
        }
        if !hits.isEmpty {
            for id in hits {
                forgetGeometry(id)
            }
            session.removals += document.remove(ids: hits)
            dropOrphanedPendingStrokes()
            requestFullRender()
        }
        session.last = point
        eraseSession = session

        let c = inputTransform.toView(point), r = radius * inputTransform.scale
        setCursor(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil),
                  inZoomPanel: inputInZoomPanel)
    }
}
