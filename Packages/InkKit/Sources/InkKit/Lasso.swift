import CoreGraphics
import Foundation

enum LassoMode: String, CaseIterable, Identifiable {
    case freeform, square
    var id: String { rawValue }
}

/// Pure geometry for lasso selection. A stroke is selected as a whole if any part of its
/// centerline touches the lasso region: a sample point inside it, or a segment crossing its edge.
enum LassoGeometry {
    /// Closed polygon for a lasso gesture, or nil if the gesture is too small to select anything.
    static func region(mode: LassoMode, points: [CGPoint]) -> [CGPoint]? {
        guard let first = points.first, let last = points.last else { return nil }
        switch mode {
        case .freeform:
            return points.count >= 3 ? points : nil
        case .square:
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(first.x - last.x), height: abs(first.y - last.y))
            guard r.width > 0, r.height > 0 else { return nil }
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }
    }

    static func bounds(of polygon: [CGPoint]) -> CGRect {
        guard let f = polygon.first else { return .null }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in polygon {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even-odd point-in-polygon test (the polygon is implicitly closed).
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    /// True if any part of the stroke path lies in the region.
    static func stroke(_ path: [CGPoint], touches polygon: [CGPoint], polygonBounds: CGRect) -> Bool {
        guard !path.isEmpty, polygon.count >= 3 else { return false }
        for p in path where polygonBounds.contains(p) && contains(polygon, p) { return true }
        guard path.count >= 2 else { return false }
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let segBounds = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                   width: abs(a.x - b.x), height: abs(a.y - b.y))
            guard segBounds.intersects(polygonBounds) else { continue }
            var j = polygon.count - 1
            for k in polygon.indices {
                if segmentsIntersect(a, b, polygon[j], polygon[k]) { return true }
                j = k
            }
        }
        return false
    }
}
