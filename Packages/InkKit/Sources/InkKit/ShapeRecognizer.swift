import CoreGraphics
import Foundation

/// Turns a rough stroke into the shape it was meant to be: a line, an arrow, a rectangle, an ellipse, a
/// triangle, a polygon or a curve. Pure geometry on page-space points, on the device; nothing is sent
/// anywhere.
///
/// **How it decides.** The stroke is resampled evenly along its length. An open stroke is a **line** if
/// it hardly leaves its chord, an **arrow** if it's a long straight shaft followed by short barbs folding
/// back from its end, and otherwise a smooth **curve** (one without sharp corners; a stroke with them is
/// left as ink unless `fallbackToCurve`). A stroke whose end comes back near its start is closed (an
/// overshoot past the start is trimmed). Its corners are found by simplifying it (Ramer–Douglas–Peucker)
/// and dropping near-straight vertices; it's also fitted with an ellipse along its principal axes. Three
/// corners make a **triangle**, four with near-right angles a **rectangle** (other quadrilaterals are
/// **polygons**), five to eight a **polygon**, as long as the corners fit the stroke better than the
/// ellipse does; otherwise a good ellipse fit is an **ellipse**.
///
/// **Snapping.** Lines and arrows within `angleSnap` of a multiple of 45° are straightened onto it;
/// rectangles and ellipses within `axisSnap` of upright are stood upright; nearly equal sides make a
/// square or a circle. Ends and corners within `snapDistance` of another shape's anchor (`anchors`,
/// see `ShapeObject.snapAnchors`) land exactly on it, so shapes join up.
enum ShapeRecognizer {
    struct Options {
        /// Strokes smaller than this (bounds diagonal, page points) aren't shapes.
        var minimumSize: CGFloat = 12
        /// Points of other shapes that ends and corners snap to, and how close they have to be (page points).
        var anchors: [CGPoint] = []
        var snapDistance: CGFloat = 10
        /// How far (radians) a line may be from a multiple of 45° and still be snapped onto it.
        var angleSnap: CGFloat = 6 * .pi / 180
        /// How far (radians) a rectangle or ellipse may be from upright and still be stood upright.
        var axisSnap: CGFloat = 8 * .pi / 180
        /// Whether a stroke that's nothing else becomes a curve through it (the shape tool) rather than
        /// being left as ink (hold-to-snap).
        var fallbackToCurve = false
    }

    /// What a stroke was recognised as, in page space.
    enum Shape: Equatable {
        /// A line, arrow, triangle, polygon or curve through these points.
        case points(ShapeObject.Kind, [CGPoint])
        /// A rectangle or ellipse of `size` centred on `center`, turned by `rotation` radians.
        case framed(ShapeObject.Kind, center: CGPoint, size: CGSize, rotation: CGFloat)

        var kind: ShapeObject.Kind {
            switch self {
            case let .points(kind, _), let .framed(kind, _, _, _): kind
            }
        }

        /// The shape as a page object drawn in `style`.
        func object(style: ShapeStyle) -> ShapeObject {
            switch self {
            case let .points(kind, points):
                return ShapeObject(kind, points: points, style: style)
            case let .framed(kind, center, size, rotation):
                let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                   width: size.width, height: size.height)
                let t = rotation == 0 ? .identity : CGAffineTransform(translationX: -center.x, y: -center.y)
                    .concatenating(CGAffineTransform(rotationAngle: rotation))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
                return ShapeObject(kind, frame: frame, transform: t, style: style)
            }
        }
    }

    static let sampleCount = 96

    static func recognize(_ stroke: [CGPoint], options: Options = Options()) -> Shape? {
        let raw = deduplicated(stroke)
        guard raw.count >= 2 else { return nil }
        let extent = bounds(raw)
        let diagonal = hypot(extent.width, extent.height)
        guard diagonal >= options.minimumSize, diagonal > 0 else { return nil }
        let length = pathLength(raw)
        let samples = resample(raw, count: sampleCount)

        if let loop = closedLoop(samples, diagonal: diagonal, length: length) {
            return recognizeClosed(loop, diagonal: diagonal, options: options)
        }
        return recognizeOpen(samples, diagonal: diagonal, length: length, options: options)
    }

    // MARK: Open strokes

    private static func recognizeOpen(_ pts: [CGPoint], diagonal: CGFloat, length: CGFloat, options: Options) -> Shape? {
        let start = pts[0], end = pts[pts.count - 1]
        let chord = start.distance(to: end)
        if chord > 0, chord / length > 0.9 {
            let deviation = pts.map { distance(from: $0, toSegment: start, end) }.max() ?? 0
            if deviation / chord < 0.08 {
                let (a, b) = snappedSegment(start, end, options: options)
                return .points(.line, [a, b])
            }
        }
        if let (tail, tip) = arrow(pts, diagonal: diagonal, length: length) {
            let (a, b) = snappedSegment(tail, tip, options: options)
            return .points(.arrow, [a, b])
        }
        let isSmooth = smooth(pts)
        guard isSmooth || options.fallbackToCurve else { return nil }
        var through = simplify(pts, epsilon: diagonal * 0.012)
        if through.count < 2 {
            through = [start, end]
        }
        through[0] = snapped(through[0], to: options)
        through[through.count - 1] = snapped(through[through.count - 1], to: options)
        return .points(.curve, through)
    }

    /// A straight shaft followed by short barbs that fold back from its end: the shaft's tail and tip.
    private static func arrow(_ pts: [CGPoint], diagonal: CGFloat, length: CGFloat) -> (CGPoint, CGPoint)? {
        let vertices = simplify(pts, epsilon: diagonal * 0.05)
        guard vertices.count >= 3, vertices.count <= 6 else { return nil }
        let tail = vertices[0], tip = vertices[1]
        let shaft = tail.distance(to: tip)
        guard shaft > 0, shaft >= length * 0.45 else { return nil }
        let direction = CGPoint(x: (tip.x - tail.x) / shaft, y: (tip.y - tail.y) / shaft)
        var foldsBack = false
        for i in 2 ..< vertices.count {
            let v = vertices[i]
            let segment = vertices[i - 1].distance(to: v)
            guard segment <= shaft * 0.6, v.distance(to: tip) <= shaft * 0.6 else { return nil }
            let offset = v - tip
            let along = offset.x * direction.x + offset.y * direction.y
            let reach = hypot(offset.x, offset.y)
            if reach > shaft * 0.08, along < -0.25 * reach {
                foldsBack = true
            }
        }
        return foldsBack ? (tail, tip) : nil
    }

    /// No sharp corners and not too much turning: a curve someone meant, not handwriting.
    private static func smooth(_ pts: [CGPoint]) -> Bool {
        let coarse = resample(pts, count: 32)
        var total: CGFloat = 0
        for i in 1 ..< coarse.count - 1 {
            let turn = abs(turnAngle(coarse[i - 1], coarse[i], coarse[i + 1]))
            if turn > 50 * .pi / 180 {
                return false
            }
            total += turn
        }
        return total < 1.6 * .pi
    }

    // MARK: Closed strokes

    /// The stroke as a closed loop if its end comes back to its start, with any overshoot trimmed.
    private static func closedLoop(_ pts: [CGPoint], diagonal: CGFloat, length: CGFloat) -> [CGPoint]? {
        guard length >= diagonal * 1.6 else { return nil }
        let start = pts[0]
        let tailStart = Int(Double(pts.count) * 0.65)
        var best = pts.count - 1, bestDistance = CGFloat.infinity
        for i in tailStart ..< pts.count {
            let d = pts[i].distance(to: start)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        guard bestDistance <= diagonal * 0.22 else { return nil }
        let loop = Array(pts[0 ... best])
        return loop.count >= 8 ? resample(loop + [start], count: sampleCount) : nil
    }

    private static func recognizeClosed(_ loop: [CGPoint], diagonal: CGFloat, options: Options) -> Shape? {
        let corners = closedCorners(loop, diagonal: diagonal)
        let polygonError = corners.count >= 3 ? meanDistance(loop, toPolygon: corners) / diagonal : .infinity
        let ellipse = fitEllipse(loop)
        let ellipseError = ellipse.map { $0.error / diagonal } ?? .infinity

        switch corners.count {
        case 3 where polygonError < 0.035 && polygonError < ellipseError * 1.2:
            return .points(.triangle, corners.map { snapped($0, to: options) })
        case 4 where polygonError < 0.035 && polygonError < ellipseError:
            if isRectangular(corners) {
                return rectangle(from: corners, options: options)
            }
            return .points(.polygon, corners.map { snapped($0, to: options) })
        case 5 ... 8 where polygonError < 0.03 && polygonError < ellipseError * 0.6:
            return .points(.polygon, corners.map { snapped($0, to: options) })
        default:
            break
        }
        if let ellipse, ellipseError < 0.045 {
            return ellipseShape(ellipse, options: options)
        }
        if options.fallbackToCurve, corners.count >= 3 {
            return .points(.polygon, corners.map { snapped($0, to: options) })
        }
        return nil
    }

    /// The loop's corners: its simplified outline without vertices where it hardly turns.
    private static func closedCorners(_ loop: [CGPoint], diagonal: CGFloat) -> [CGPoint] {
        // Split the loop at the point farthest from its start and simplify each half.
        let start = loop[0]
        let far = loop.indices.max { loop[$0].distance(to: start) < loop[$1].distance(to: start) } ?? loop.count / 2
        let epsilon = diagonal * 0.045
        let first = simplify(Array(loop[0 ... far]), epsilon: epsilon)
        let second = simplify(Array(loop[far...]), epsilon: epsilon)
        var vertices = Array(first.dropLast()) + Array(second.dropLast()) // the loop ends where it starts
        // Drop vertices that are close together or where the outline barely turns, until none are left.
        var changed = true
        while changed, vertices.count > 3 {
            changed = false
            for i in vertices.indices {
                let prev = vertices[(i + vertices.count - 1) % vertices.count], v = vertices[i]
                let next = vertices[(i + 1) % vertices.count]
                if abs(turnAngle(prev, v, next)) < 28 * .pi / 180 || v.distance(to: next) < diagonal * 0.08 {
                    vertices.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return vertices
    }

    private static func isRectangular(_ corners: [CGPoint]) -> Bool {
        (0 ..< 4).allSatisfy { i in
            let turn = abs(turnAngle(corners[(i + 3) % 4], corners[i], corners[(i + 1) % 4]))
            return abs(turn - .pi / 2) < 22 * .pi / 180
        }
    }

    private static func rectangle(from corners: [CGPoint], options: Options) -> Shape {
        // The rectangle's angle: each side's direction folded into a quarter turn, averaged by length.
        var sx: CGFloat = 0, sy: CGFloat = 0
        for i in 0 ..< 4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let angle = atan2(b.y - a.y, b.x - a.x) * 4
            let length = a.distance(to: b)
            sx += cos(angle) * length
            sy += sin(angle) * length
        }
        var rotation = atan2(sy, sx) / 4
        if abs(rotation) < options.axisSnap {
            rotation = 0
        }
        let u = CGPoint(x: cos(rotation), y: sin(rotation)), v = CGPoint(x: -sin(rotation), y: cos(rotation))
        func span(_ axis: CGPoint) -> (CGFloat, CGFloat) {
            let projected = corners.map { $0.x * axis.x + $0.y * axis.y }.sorted()
            return ((projected[0] + projected[1]) / 2, (projected[2] + projected[3]) / 2)
        }
        let (u0, u1) = span(u), (v0, v1) = span(v)
        var size = CGSize(width: u1 - u0, height: v1 - v0)
        if abs(size.width - size.height) / max(size.width, size.height) < 0.1 {
            let side = (size.width + size.height) / 2
            size = CGSize(width: side, height: side)
        }
        let cu = (u0 + u1) / 2, cv = (v0 + v1) / 2
        let center = CGPoint(x: cu * u.x + cv * v.x, y: cu * u.y + cv * v.y)
        return .framed(.rectangle, center: center, size: size, rotation: rotation)
    }

    struct Ellipse {
        var center: CGPoint
        /// Half-axes along `rotation` and across it.
        var radii: CGSize
        var rotation: CGFloat
        /// Mean distance (page points, roughly) from the points to the ellipse.
        var error: CGFloat
    }

    /// An ellipse along the points' principal axes, spanning their extent on each axis.
    static func fitEllipse(_ pts: [CGPoint]) -> Ellipse? {
        let n = CGFloat(pts.count)
        guard n >= 5 else { return nil }
        let mean = CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in pts {
            let dx = p.x - mean.x, dy = p.y - mean.y
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let rotation = 0.5 * atan2(2 * sxy, sxx - syy)
        let u = CGPoint(x: cos(rotation), y: sin(rotation)), v = CGPoint(x: -sin(rotation), y: cos(rotation))
        let pu = pts.map { $0.x * u.x + $0.y * u.y }, pv = pts.map { $0.x * v.x + $0.y * v.y }
        guard let u0 = pu.min(), let u1 = pu.max(), let v0 = pv.min(), let v1 = pv.max() else { return nil }
        let a = (u1 - u0) / 2, b = (v1 - v0) / 2
        guard a > 1e-6, b > 1e-6 else { return nil }
        let cu = (u0 + u1) / 2, cv = (v0 + v1) / 2
        var error: CGFloat = 0
        for i in pts.indices {
            let x = pu[i] - cu, y = pv[i] - cv
            let r = sqrt((x / a) * (x / a) + (y / b) * (y / b))
            error += abs(r - 1) * sqrt(a * b)
        }
        return Ellipse(center: CGPoint(x: cu * u.x + cv * v.x, y: cu * u.y + cv * v.y),
                       radii: CGSize(width: a, height: b), rotation: rotation, error: error / n)
    }

    private static func ellipseShape(_ e: Ellipse, options: Options) -> Shape {
        var size = CGSize(width: e.radii.width * 2, height: e.radii.height * 2)
        var rotation = e.rotation
        if min(size.width, size.height) / max(size.width, size.height) > 0.88 {
            let d = (size.width + size.height) / 2
            return .framed(.ellipse, center: snapped(e.center, to: options), size: CGSize(width: d, height: d), rotation: 0)
        }
        // Fold into (-45°, 45°] so the snap to upright sees the nearest axis.
        while rotation > .pi / 4 {
            rotation -= .pi / 2
            size = CGSize(width: size.height, height: size.width)
        }
        while rotation <= -.pi / 4 {
            rotation += .pi / 2
            size = CGSize(width: size.height, height: size.width)
        }
        if abs(rotation) < options.axisSnap {
            rotation = 0
        }
        return .framed(.ellipse, center: snapped(e.center, to: options), size: size, rotation: rotation)
    }

    // MARK: Snapping

    /// `a`–`b` with each end snapped to an anchor, and otherwise straightened onto the nearest 45° if close.
    static func snappedSegment(_ a: CGPoint, _ b: CGPoint, options: Options) -> (CGPoint, CGPoint) {
        let start = snapped(a, to: options)
        let end = snapped(b, to: options)
        if end != b {
            return (start, end) // an end on an anchor stays there
        }
        return (start, snappedAngle(from: start, to: end, within: options.angleSnap))
    }

    /// `end` turned about `start` onto the nearest multiple of 45° if it's within `tolerance` of it.
    static func snappedAngle(from start: CGPoint, to end: CGPoint, within tolerance: CGFloat) -> CGPoint {
        let length = start.distance(to: end)
        guard length > 0 else { return end }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let step = CGFloat.pi / 4
        let nearest = (angle / step).rounded() * step
        guard abs(angle - nearest) <= tolerance else { return end }
        return CGPoint(x: start.x + length * cos(nearest), y: start.y + length * sin(nearest))
    }

    /// The nearest anchor within `options.snapDistance` of `p`, or `p`.
    static func snapped(_ p: CGPoint, to options: Options) -> CGPoint {
        snapped(p, anchors: options.anchors, within: options.snapDistance)
    }

    static func snapped(_ p: CGPoint, anchors: [CGPoint], within distance: CGFloat) -> CGPoint {
        var best = p, bestDistance = distance
        for anchor in anchors {
            let d = anchor.distance(to: p)
            if d <= bestDistance {
                best = anchor
                bestDistance = d
            }
        }
        return best
    }

    // MARK: Geometry

    static func deduplicated(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(pts.count)
        for p in pts where p.x.isFinite && p.y.isFinite {
            if let last = out.last, last.distance(to: p) < 1e-6 {
                continue
            }
            out.append(p)
        }
        return out
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        ShapeObject.bounds(of: pts)
    }

    static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// `count` points evenly spaced along the path, first and last included.
    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        let total = pathLength(pts)
        guard pts.count >= 2, total > 0, count >= 2 else { return pts }
        let step = total / CGFloat(count - 1)
        var out = [pts[0]]
        var carried: CGFloat = 0
        var i = 1
        var previous = pts[0]
        while i < pts.count, out.count < count - 1 {
            let next = pts[i]
            let segment = previous.distance(to: next)
            if carried + segment >= step, segment > 0 {
                let t = (step - carried) / segment
                let p = CGPoint(x: previous.x + (next.x - previous.x) * t, y: previous.y + (next.y - previous.y) * t)
                out.append(p)
                previous = p
                carried = 0
            } else {
                carried += segment
                previous = next
                i += 1
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    /// Ramer–Douglas–Peucker: the fewest of `pts` within `epsilon` of the path, ends kept.
    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            var worst = lo, worstDistance: CGFloat = 0
            for i in lo + 1 ..< hi {
                let d = distance(from: pts[i], toSegment: pts[lo], pts[hi])
                if d > worstDistance {
                    worstDistance = d
                    worst = i
                }
            }
            if worstDistance > epsilon {
                keep[worst] = true
                stack.append((lo, worst))
                stack.append((worst, hi))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 0 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2, 0), 1)
        return p.distance(to: CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t))
    }

    private static func meanDistance(_ pts: [CGPoint], toPolygon polygon: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for p in pts {
            var best = CGFloat.infinity
            for i in polygon.indices {
                best = min(best, distance(from: p, toSegment: polygon[i], polygon[(i + 1) % polygon.count]))
            }
            total += best
        }
        return total / CGFloat(max(pts.count, 1))
    }

    /// The signed angle the path turns through at `b`, going from `a` to `c`.
    static func turnAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = b - a, v2 = c - b
        guard hypot(v1.x, v1.y) > 1e-9, hypot(v2.x, v2.y) > 1e-9 else { return 0 }
        return atan2(v1.x * v2.y - v1.y * v2.x, v1.x * v2.x + v1.y * v2.y)
    }
}
