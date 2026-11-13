import CoreGraphics
import Foundation

/// Splits ink strokes where pixel-eraser strokes have cut clean through them, so each visible piece
/// becomes its own `Stroke` (and the stroke eraser removes only the piece it touches).
///
/// A stroke is "cut" at a spline sample when the ink's whole cross-section there — the nib polygon's
/// extent across the direction of travel — lies inside the eraser coverage. Each maximal run of cut
/// samples strictly inside the stroke separates two pieces: the left piece ends at the run's first
/// sample and the right piece starts at its last, so the pieces never overlap in ink that is still
/// visible (unless the cut is narrower than the nib radius, where the two end caps can meet).
/// Runs that reach the stroke's first or last sample just shorten the stroke visually; the points
/// are kept, so the committed appearance is unchanged.
enum StrokeSplitter {
    /// Union of fully opaque eraser hulls, bucketed in a uniform grid for fast point queries.
    private struct Cell: Hashable { let x: Int, y: Int }

    private struct PolygonItem {
        let polygon: [CGPoint]
        let bounds: CGRect
    }

    struct Coverage {
        private let cellSize: CGFloat = 16
        private var items: [PolygonItem] = []
        private var cells: [Cell: [Int]] = [:]
        private(set) var bounds = CGRect.null

        var isEmpty: Bool {
            items.isEmpty
        }

        /// Adds the hulls of an eraser stroke that intersect `region`.
        mutating func add(_ eraserHulls: [Hull], within region: CGRect) {
            for hull in eraserHulls where hull.alpha >= 0.999 && hull.bounds.intersects(region) {
                if hull.polygon.count > 2 {
                    addPolygon(hull.polygon, bounds: hull.bounds, within: region)
                } else if hull.right.count >= 2 {
                    let count = hull.right.count / 2
                    for q in 0 ..< count {
                        let i = q * 2
                        guard i + 1 < hull.left.count else { break }
                        let quad = [hull.right[i], hull.right[i + 1], hull.left[i + 1], hull.left[i]]
                        let b = Hull.bounds(of: quad)
                        if b.intersects(region) {
                            addPolygon(quad, bounds: b, within: region)
                        }
                    }
                }
            }
        }

        private mutating func addPolygon(_ poly: [CGPoint], bounds b: CGRect, within _: CGRect) {
            let index = items.count
            items.append(PolygonItem(polygon: poly, bounds: b))
            bounds = bounds.union(b)
            let x0 = cellIndex(b.minX), x1 = cellIndex(b.maxX)
            let y0 = cellIndex(b.minY), y1 = cellIndex(b.maxY)
            for x in x0 ... x1 {
                for y in y0 ... y1 {
                    cells[Cell(x: x, y: y), default: []].append(index)
                }
            }
        }

        func contains(_ p: CGPoint) -> Bool {
            guard bounds.contains(p), let bucket = cells[Cell(x: cellIndex(p.x), y: cellIndex(p.y))] else {
                return false
            }
            for i in bucket where items[i].bounds.contains(p) && Self.convexPolygon(items[i].polygon, contains: p) {
                return true
            }
            return false
        }

        private func cellIndex(_ v: CGFloat) -> Int {
            Int((v / cellSize).rounded(.down))
        }

        /// Hull polygons are convex with consistent winding, so a point is inside when it's on the
        /// same side of every edge.
        private static func convexPolygon(_ poly: [CGPoint], contains p: CGPoint) -> Bool {
            var sign: CGFloat = 0
            var j = poly.count - 1
            for i in poly.indices {
                let a = poly[j], b = poly[i]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if abs(cross) > 1e-9 {
                    if sign == 0 {
                        sign = cross
                    } else if (cross > 0) != (sign > 0) {
                        return false
                    }
                }
                j = i
            }
            return true
        }
    }

    /// A position on the stroke's spline: segment `segment` at parameter `t` in [0, 1).
    private struct Sample {
        let segment: Int
        let t: CGFloat
        let point: StrokePoint
        var cut = false
    }

    /// Tolerance (canvas units) so ink whose edge sits exactly on the eraser's edge still counts as cut.
    private static let edgeTolerance: CGFloat = 0.25
    /// Max distance between interpolated nib stamps along the spline, canvas units.
    private static let sampleSpacing: CGFloat = 1.5
    /// Max spacing of the probe points across the ink's width.
    private static let probeSpacing: CGFloat = 1.5

    /// Pieces `stroke` falls into under `coverage`, or nil if it isn't cut through anywhere.
    /// Pieces get fresh IDs and keep the original's tool, colour and style snapshot.
    static func pieces(of stroke: Stroke, coverage: Coverage) -> [Stroke]? {
        let pts = stroke.points
        guard pts.count > 1, !coverage.isEmpty else { return nil }

        var samples = splineSamples(pts)
        guard samples.count > 2 else { return nil }
        for k in samples.indices {
            let prev = samples[max(k - 1, 0)].point.location
            let next = samples[min(k + 1, samples.count - 1)].point.location
            samples[k].cut = isCut(samples[k].point, direction: next - prev, style: stroke.style, coverage: coverage)
        }

        // Interior runs of cut samples → (first, last) sample indices of each run.
        var gaps: [(Int, Int)] = []
        var k = 1
        while k < samples.count - 1 {
            guard samples[k].cut else { k += 1; continue }
            let start = k
            while k < samples.count, samples[k].cut {
                k += 1
            }
            if k < samples.count {
                gaps.append((start, k - 1))
            } // a run reaching the end isn't a gap
        }
        if samples[0].cut, let first = gaps.first, first.0 == 1 {
            gaps.removeFirst()
        } // run touching the start
        guard !gaps.isEmpty else { return nil }

        var pieces: [Stroke] = []
        var from = 0
        for (gapStart, gapEnd) in gaps {
            pieces.append(piece(of: stroke, from: samples[from], to: samples[gapStart]))
            from = gapEnd
        }
        pieces.append(piece(of: stroke, from: samples[from], to: samples[samples.count - 1]))
        return pieces
    }

    /// Samples along the centripetal Catmull-Rom spline, matching `StrokeRenderer.segmentHulls`.
    /// Real points appear with t = 0; the stroke's last point is (count - 1, 0).
    private static func splineSamples(_ pts: [StrokePoint]) -> [Sample] {
        var samples = [Sample(segment: 0, t: 0, point: pts[0])]
        for i in 0 ..< (pts.count - 1) {
            let p1 = pts[i].location, p2 = pts[i + 1].location
            let p0 = i > 0 ? pts[i - 1].location : p1 * 2 - p2
            let p3 = i + 2 < pts.count ? pts[i + 2].location : p2 * 2 - p1
            let (c1, c2) = StrokeRenderer.centripetalControls(p0, p1, p2, p3)
            let length = p1.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: p2)
            let steps = min(max(Int((length / sampleSpacing).rounded(.up)), 1), 48)
            for s in 1 ..< steps {
                let t = CGFloat(s) / CGFloat(steps)
                let loc = StrokeRenderer.bezier(p1, c1, c2, p2, t)
                samples.append(Sample(segment: i, t: t,
                                      point: StrokeRenderer.interpolate(pts[i], pts[i + 1], t, at: loc)))
            }
            samples.append(Sample(segment: i + 1, t: 0, point: pts[i + 1]))
        }
        return samples
    }

    /// True when the nib's full extent across `direction` is inside the eraser coverage.
    private static func isCut(_ p: StrokePoint, direction: CGPoint, style: BrushStyle, coverage: Coverage) -> Bool {
        let tip = StrokeRenderer.tip(for: p, style: style)
        guard coverage.contains(tip.center) else { return false }
        let len = hypot(direction.x, direction.y)
        guard len > 1e-6 else { return false }
        let n = CGPoint(x: -direction.y / len, y: direction.x / len)

        var lo = CGFloat.infinity, hi = -CGFloat.infinity
        for v in StrokeRenderer.polygon(for: tip) {
            let d = (v.x - tip.center.x) * n.x + (v.y - tip.center.y) * n.y
            lo = min(lo, d); hi = max(hi, d)
        }
        lo += edgeTolerance; hi -= edgeTolerance
        guard hi > lo else { return true }

        let probes = min(max(Int(((hi - lo) / probeSpacing).rounded(.up)), 2), 64)
        // Ends first: they're the likeliest to be uncovered.
        if !coverage.contains(tip.center + n * lo) || !coverage.contains(tip.center + n * hi) {
            return false
        }
        for s in 1 ..< probes {
            let d = lo + (hi - lo) * CGFloat(s) / CGFloat(probes)
            if !coverage.contains(tip.center + n * d) {
                return false
            }
        }
        return true
    }

    private static func piece(of stroke: Stroke, from a: Sample, to b: Sample) -> Stroke {
        var pts = [a.point]
        if a.segment + 1 <= b.segment {
            pts += stroke.points[(a.segment + 1) ... b.segment]
        }
        if b.t > 0 {
            pts.append(b.point)
        }
        return Stroke(id: UUID(), tool: stroke.tool, color: stroke.color, style: stroke.style, points: pts,
                      createdAt: stroke.createdAt)
    }
}
