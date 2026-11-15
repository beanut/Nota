import CoreGraphics
import Foundation

/// Pure geometry for the Pencil's scribble gestures, in canvas space. **Circle to select:** drawing a
/// loop around ink and holding the Pencil still selects the strokes mostly inside the loop.
enum Scribble {
    /// A stroke that a gesture might act on: its id, centreline and bounds.
    struct Candidate {
        let id: UUID
        let points: [CGPoint]
        let bounds: CGRect
    }

    /// Whether `points` close into a loop at least `minSize` across: the ends meet, the stroke goes round
    /// about once and it winds (nearly) all the way round its centre.
    static func isClosedLoop(_ points: [CGPoint], minSize: CGFloat) -> Bool {
        guard points.count >= 8, let first = points.first, let last = points.last else { return false }
        let b = LassoGeometry.bounds(of: points)
        guard min(b.width, b.height) >= minSize,
              first.distance(to: last) <= max(0.3 * max(b.width, b.height), minSize / 2) else { return false }
        // About once round: a scribble that fills its bounds runs far longer than their perimeter.
        let perimeter = CGFloat.pi * (b.width + b.height) / 2 // an ellipse's, near enough
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        guard length <= 1.6 * perimeter else { return false }
        let c = CGPoint(x: b.midX, y: b.midY)
        var winding: CGFloat = 0
        var previous = atan2(first.y - c.y, first.x - c.x)
        for p in points.dropFirst() {
            let angle = atan2(p.y - c.y, p.x - c.x)
            var d = angle - previous
            if d > .pi {
                d -= 2 * .pi
            } else if d < -.pi {
                d += 2 * .pi
            }
            winding += d
            previous = angle
        }
        return abs(winding) >= 1.75 * .pi
    }

    /// Strokes the loop selects: those with at least 60% of their points inside it.
    static func loopSelection(_ loop: [CGPoint], candidates: [Candidate]) -> Set<UUID> {
        let lb = LassoGeometry.bounds(of: loop)
        var hit = Set<UUID>()
        for c in candidates where c.bounds.intersects(lb) && !c.points.isEmpty {
            let inside = c.points.reduce(0) { $0 + (LassoGeometry.contains(loop, $1) ? 1 : 0) }
            if inside * 5 >= c.points.count * 3 {
                hit.insert(c.id)
            }
        }
        return hit
    }
}
