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

    struct EraseSession {
        /// Which ink it erases.
        var target: EraserTarget
        /// For a standard erase (which cuts strokes rather than removing them), the strokes as they were
        /// when it began, for its undo command; nil for a stroke erase.
        var before: [Stroke]?
        var removals: [CanvasDocument.Removal] = []
        var last: CGPoint?

        var isStandard: Bool {
            before != nil
        }
    }

    /// Ends a stroke or standard erase, recording everything it changed as one undoable command.
    func finishErasing() {
        guard let session = eraseSession else { return }
        editDocument {
            if let before = session.before {
                document.recordReplace(before: before)
            } else {
                document.recordErase(session.removals)
            }
        }
        eraseSession = nil
        setCursor(nil)
    }

    /// Stroke and standard erasers: removes the ink strokes the eraser sweeps through, or for a standard
    /// erase cuts away the parts of them it passes over. Only ink the eraser's target allows is touched.
    func eraseStrokes(along point: CGPoint) {
        guard var session = eraseSession, let controller else { return }
        let radius = CGFloat(controller.current.width) / 2 / inputTransform.scale
        let from = session.last ?? point
        let steps = max(1, Int((from.distance(to: point) / (radius * 0.5)).rounded(.up)))
        let sweep = CGRect(x: min(from.x, point.x), y: min(from.y, point.y),
                           width: abs(from.x - point.x), height: abs(from.y - point.y))
            .insetBy(dx: -radius, dy: -radius)

        var hits = Set<UUID>()
        var cuts: [(id: UUID, pieces: [Stroke])] = []
        for stroke in document.strokes where session.target.erases(stroke.tool) {
            let bounds = geometry(for: stroke).bounds
            guard bounds.intersects(sweep) else { continue }
            if session.isStandard {
                if let pieces = StrokeSplitter.remainder(of: stroke, erasedFrom: from, to: point, radius: radius) {
                    cuts.append((stroke.id, pieces))
                }
                continue
            }
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
        }
        for cut in cuts {
            forgetGeometry(cut.id)
            document.replace(id: cut.id, with: cut.pieces)
        }
        if !hits.isEmpty || !cuts.isEmpty {
            dropOrphanedPendingStrokes()
            requestFullRender()
        }
        session.last = point
        eraseSession = session
        showEraserCursor(at: point)
    }

    /// The eraser's outline at `point` (canvas space), at its on-screen size, while it's erasing.
    func showEraserCursor(at point: CGPoint) {
        guard let controller else { return }
        let c = inputTransform.toView(point), r = CGFloat(controller.current.width) / 2
        setCursor(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil),
                  inZoomPanel: inputInZoomPanel)
    }
}
