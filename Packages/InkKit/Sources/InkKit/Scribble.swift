import CoreGraphics
import Foundation

/// Pure geometry for the Pencil's scribble gestures, in canvas space:
///
/// - **Scratch-out:** scribbling back and forth over ink erases the strokes underneath. A stroke counts
///   as a scratch when it runs to and fro along one axis at least four times; it only erases if strokes
///   lie mostly inside it, otherwise it's kept as ink (shading, a zigzag).
/// - **Circle to select:** drawing a loop around ink and holding the Pencil still selects the strokes
///   mostly inside the loop.
enum Scribble {
    /// A stroke that a gesture might act on: its id, centreline and bounds.
    struct Candidate {
        let id: UUID
        let points: [CGPoint]
        let bounds: CGRect
    }

    /// Back-and-forth passes a scratch needs.
    static let minReversals = 4

    /// Whether `points` scribble back and forth: at least `minReversals` turns along their main axis,
    /// each pass covering a good part of the scratch, and the scratch at least `minSize` long.
    static func isScratchOut(_ points: [CGPoint], minSize: CGFloat) -> Bool {
        guard points.count >= 12 else { return false }
        let axis = principalAxis(points)
        let s = points.map { $0.x * axis.x + $0.y * axis.y }
        guard let lo = s.min(), let hi = s.max() else { return false }
        let range = hi - lo
        guard range >= minSize else { return false }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        guard length >= 2.5 * range else { return false }
        // A pass must cover at least a third of the scratch's span to count, so a wobble doesn't.
        let hysteresis = max(range / 3, minSize / 4)
        return reversals(along: s, hysteresis: hysteresis) >= minReversals
    }

    /// Turns in `values` (positions along one axis), ignoring any that move back less than `hysteresis`.
    static func reversals(along values: [CGFloat], hysteresis: CGFloat) -> Int {
        guard let start = values.first else { return 0 }
        var count = 0
        var direction = 0 // 0 until the first pass has moved `hysteresis` from the start
        var extreme = start
        for value in values.dropFirst() {
            switch direction {
            case 1:
                if value > extreme {
                    extreme = value
                } else if extreme - value >= hysteresis {
                    count += 1
                    direction = -1
                    extreme = value
                }
            case -1:
                if value < extreme {
                    extreme = value
                } else if value - extreme >= hysteresis {
                    count += 1
                    direction = 1
                    extreme = value
                }
            default:
                if abs(value - start) >= hysteresis {
                    direction = value > start ? 1 : -1
                    extreme = value
                }
            }
        }
        return count
    }

    /// Strokes the scratch erases: those with at least half their points inside its bounds, grown by `pad`.
    static func scratchOutTargets(_ scratch: [CGPoint], candidates: [Candidate], pad: CGFloat) -> Set<UUID> {
        let area = LassoGeometry.bounds(of: scratch).insetBy(dx: -pad, dy: -pad)
        guard !area.isNull else { return [] }
        var hit = Set<UUID>()
        for c in candidates where c.bounds.intersects(area) && !c.points.isEmpty {
            let inside = c.points.reduce(0) { $0 + (area.contains($1) ? 1 : 0) }
            if inside * 2 >= c.points.count {
                hit.insert(c.id)
            }
        }
        return hit
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

    /// Unit vector along which `points` spread the most (their principal component).
    static func principalAxis(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n, my = points.reduce(0) { $0 + $1.y } / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            let dx = p.x - mx, dy = p.y - my
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        return CGPoint(x: cos(theta), y: sin(theta))
    }
}
