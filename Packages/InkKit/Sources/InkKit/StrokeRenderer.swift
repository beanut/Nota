import CoreGraphics
import UIKit

// MARK: - Geometry types (all in canvas space)

/// One piece of a stroke's outline. Either:
///  - a **stamp**: the nib itself, as a closed convex `polygon`; or
///  - a **strip**: the two sides (`left`, `right`) of a run of tangent quads between consecutive nib
///    positions. When `joinsPrevious` is set, the strip carries on from the strip before it, and
///    `StrokeRenderer.runs` welds them into one polygon. Welding matters: polygons that only abut, even
///    inside one path, antialias with a hairline seam between them.
struct Hull {
    let polygon: [CGPoint]
    let left: [CGPoint]
    let right: [CGPoint]
    let joinsPrevious: Bool
    let alpha: CGFloat
    let bounds: CGRect

    static func bounds(of points: [CGPoint]...) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for list in points {
            for p in list {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        return minX > maxX ? .null : CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    init(stamp polygon: [CGPoint], alpha: CGFloat) {
        self.polygon = polygon
        left = []
        right = []
        joinsPrevious = false
        self.alpha = alpha
        bounds = Self.bounds(of: polygon)
    }

    init(left: [CGPoint], right: [CGPoint], joinsPrevious: Bool, alpha: CGFloat) {
        polygon = []
        self.left = left
        self.right = right
        self.joinsPrevious = joinsPrevious
        self.alpha = alpha
        bounds = Self.bounds(of: left, right)
    }
}

/// Consecutive pieces sharing one (quantised) alpha, merged into a single non-zero-winding path.
/// Overlapping same-orientation polygons union under non-zero fill, so joints never double up.
struct StrokeRun {
    let path: CGPath
    let alpha: CGFloat
}

struct StrokeGeometry {
    let runs: [StrokeRun]
    let bounds: CGRect
}

/// Nib cross-section at one sample: an ellipse (a circle when tilt shading is off).
struct Tip {
    var center: CGPoint
    var major: CGFloat   // radius along azimuth
    var minor: CGFloat   // radius across azimuth
    var angle: CGFloat
    var alpha: CGFloat
}

extension InkKind {
    var blendMode: CGBlendMode {
        switch self {
        case .pen, .pencil: return .normal
        case .highlighter: return .multiply
        case .pixelEraser: return .destinationOut
        }
    }
}

// MARK: - Renderer

enum StrokeRenderer {
    /// Alpha is quantised so tilt-varying strokes still merge into a handful of runs.
    static let alphaSteps: CGFloat = 32
    /// How far, in canvas points, the straight steps of a segment may stray from its spline.
    /// Steps follow curvature, not distance: a fast, nearly straight segment is one or two quads however
    /// long it is, and a tight bend gets as many as it needs. See `stepCount`.
    static let flatnessTolerance: CGFloat = 0.02
    static let minStepLength: CGFloat = 1.5
    /// Largest sliver, in canvas points, that may go unfilled where two tangent quads meet at a stamp
    /// before the stamp itself is emitted to cover it. See `segmentHulls`.
    static let joinTolerance: CGFloat = 0.01
    /// |Δreach| / distance between two stamps beyond which one nearly contains the other and their
    /// common tangents are ill-conditioned; both stamps are emitted as well.
    static let steepTaper: CGFloat = 0.9

    // Tilt shading kicks in below `tiltStart` and saturates at `tiltFull`.
    static let tiltStart: CGFloat = 60 * .pi / 180
    static let tiltFull: CGFloat = 15 * .pi / 180

    private static let circles: [Int: [(CGFloat, CGFloat)]] = {
        var table: [Int: [(CGFloat, CGFloat)]] = [:]
        for n in [16, 32, 64] {
            table[n] = (0..<n).map { i in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                return (cos(t), sin(t))
            }
        }
        return table
    }()

    // MARK: Nib model

    static func tiltAmount(altitude: CGFloat) -> CGFloat {
        let x = min(max((tiltStart - altitude) / (tiltStart - tiltFull), 0), 1)
        return x * x * (3 - 2 * x)   // smoothstep
    }

    static func tip(for p: StrokePoint, style: BrushStyle) -> Tip {
        let pressure = pow(min(max(p.force, 0), 1), style.pressureGamma)
        let width = style.width * (style.minWidthRatio + (1 - style.minWidthRatio) * pressure)
        let radius = max(width * 0.5, 0.2)
        guard style.tiltEnabled else {
            return Tip(center: p.location, major: radius, minor: radius, angle: 0, alpha: style.opacity)
        }
        let t = tiltAmount(altitude: p.altitude)
        let minor = radius * (1 + 0.6 * t)
        let major = radius * (1 + 3.5 * t)
        // The lead's contact patch grows from the tip toward the barrel, i.e. along +azimuth.
        let shift = (major - minor) * 0.35
        let center = CGPoint(x: p.location.x + cos(p.azimuth) * shift,
                             y: p.location.y + sin(p.azimuth) * shift)
        return Tip(center: center, major: major, minor: minor, angle: p.azimuth,
                   alpha: style.opacity * (1 - 0.6 * t))
    }

    static func polygon(for tip: Tip) -> [CGPoint] {
        // Stamps are only emitted at stroke ends and sharp bends, so they can afford enough sides to stay
        // within ~0.05 pt of the true ellipse that the tangent quads are built from.
        let sides = tip.major < 2 ? 16 : (tip.major < 10 ? 32 : 64)
        let c = cos(tip.angle), s = sin(tip.angle)
        return circles[sides]!.map { ux, uy in
            let x = ux * tip.major, y = uy * tip.minor
            return CGPoint(x: tip.center.x + x * c - y * s, y: tip.center.y + x * s + y * c)
        }
    }

    // MARK: Hull construction

    static func makeHull(_ points: [CGPoint], alpha: CGFloat) -> Hull {
        hull(fromPolygon: convexHull(points), alpha: alpha)
    }

    fileprivate static func hull(fromPolygon poly: [CGPoint], alpha: CGFloat) -> Hull {
        Hull(stamp: poly, alpha: alpha)
    }

    /// Andrew's monotone chain. Output winding is always the same, which non-zero union relies on.
    static func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count > 2 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        lower.reserveCapacity(pts.count)
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        upper.reserveCapacity(pts.count)
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    static func dotHull(_ p: StrokePoint, style: BrushStyle) -> Hull {
        let t = tip(for: p, style: style)
        return makeHull(polygon(for: t), alpha: t.alpha)
    }

    /// A nib ellipse with its rotation cached, for support-point queries.
    private struct Nib {
        let tip: Tip
        private let c: CGFloat, s: CGFloat
        private let round: Bool

        init(_ tip: Tip) {
            self.tip = tip
            round = tip.major == tip.minor
            c = round ? 1 : cos(tip.angle)
            s = round ? 0 : sin(tip.angle)
        }

        /// Distance from the centre to the tangent line whose outward unit normal is `u`.
        func reach(_ u: CGPoint) -> CGFloat {
            if round { return tip.major }
            let x = (u.x * c + u.y * s) * tip.major, y = (u.y * c - u.x * s) * tip.minor
            return (x * x + y * y).squareRoot()
        }

        /// The boundary point furthest along unit direction `u`.
        func support(_ u: CGPoint) -> CGPoint {
            if round { return CGPoint(x: tip.center.x + u.x * tip.major, y: tip.center.y + u.y * tip.major) }
            let ux = u.x * c + u.y * s, uy = u.y * c - u.x * s
            let x = ux * tip.major * tip.major, y = uy * tip.minor * tip.minor
            let h = max((ux * x + uy * y).squareRoot(), 1e-9)
            return CGPoint(x: tip.center.x + (x * c - y * s) / h, y: tip.center.y + (x * s + y * c) / h)
        }

        var stamp: Hull { StrokeRenderer.hull(fromPolygon: StrokeRenderer.polygon(for: tip), alpha: tip.alpha) }
    }

    /// Unit normal of `v` (rotated +90°), or nil when `v` is too short to have a direction.
    private static func unitNormal(_ v: CGPoint) -> CGPoint? {
        let len = hypot(v.x, v.y)
        return len > 1e-6 ? CGPoint(x: -v.y / len, y: v.x / len) : nil
    }

    /// The tangent normals (left, right) a perfectly smooth stroke would have at the nib `nib` of a
    /// sample point: perpendicular to the spline `tangent` there, leaning by the taper between the
    /// neighbouring nibs `before` and `after`. The segments on both sides of the point get the same
    /// answer, because both know the same three samples.
    private static func referenceNormals(at nib: Nib, tangent: CGPoint, chord: CGPoint,
                                         before: Tip, after: Tip) -> (CGPoint, CGPoint)? {
        guard let n = unitNormal(tangent) ?? unitNormal(chord) else { return nil }
        let dir = CGPoint(x: n.y, y: -n.x)
        let span = before.center.distance(to: nib.tip.center) + nib.tip.center.distance(to: after.center)
        guard span > 1e-6 else { return nil }
        let sinPhi = (Nib(before).reach(n) - Nib(after).reach(n)) / span
        guard abs(sinPhi) < steepTaper else { return nil }
        let cosPhi = (1 - sinPhi * sinPhi).squareRoot()
        return (CGPoint(x: n.x * cosPhi + dir.x * sinPhi, y: n.y * cosPhi + dir.y * sinPhi),
                CGPoint(x: -n.x * cosPhi + dir.x * sinPhi, y: -n.y * cosPhi + dir.y * sinPhi))
    }

    /// Unsigned angle between two vectors; zero when either has no direction.
    private static func turn(_ u: CGPoint, _ v: CGPoint) -> CGFloat {
        let dot = u.x * v.x + u.y * v.y, cross = u.x * v.y - u.y * v.x
        return dot == 0 && cross == 0 ? 0 : abs(atan2(cross, dot))
    }

    /// Number of straight steps for the Bézier segment p1, c1, c2, p2 whose nib goes from `a` to `b`.
    /// The largest of what each of these needs:
    ///  - **Flatness**: chords within `flatnessTolerance` of the curve (Wang's bound on a cubic).
    ///  - **Turn**: each step turns little enough that neighbouring quads meet within `joinTolerance`
    ///    without a stamp, which costs far more vertices than another quad.
    ///  - **Nib change**: quads interpolate the nib linearly, so its size changes at most ~10% per step,
    ///    an elliptical nib rotates at most ~0.15 rad, and alpha moves at most one quantum.
    private static func stepCount(_ p1: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p2: CGPoint,
                                  from a: Tip, to b: Tip) -> Int {
        let d1 = p1 - c1 * 2 + c2, d2 = c1 - c2 * 2 + p2
        var n = (0.75 * max(hypot(d1.x, d1.y), hypot(d2.x, d2.y)) / flatnessTolerance).squareRoot()

        let maxTurn = 0.9 * (8 * joinTolerance / max(a.major, b.major)).squareRoot()
        n = max(n, (turn(c1 - p1, c2 - c1) + turn(c2 - c1, p2 - c2)) / maxTurn)

        n = max(n, abs(a.major - b.major) / (0.1 * min(a.major, b.major)))
        n = max(n, abs(a.alpha - b.alpha) * alphaSteps)
        if a.major != a.minor || b.major != b.minor {
            n = max(n, abs(atan2(sin(b.angle - a.angle), cos(b.angle - a.angle))) / 0.15)
        }

        // Never step shorter than half a nib width (or `minStepLength`). Past that density the pieces
        // pile up on top of each other, which is exactly what Core Graphics fills slowest: a wide
        // eraser reversing direction produced ~150 stacked polygons and one 27 ms fill. Any turn the
        // remaining steps can't absorb gets a stamp, which covers it exactly.
        let length = p1.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: p2)
        let densest = length / max(0.5 * min(a.minor, b.minor), minStepLength)
        return min(max(Int(min(n, densest).rounded(.up)), 1), 48)
    }

    /// Geometry for spline segment `i` (between pts[i] and pts[i+1]).
    /// Uses centripetal Catmull-Rom (no cusps/overshoot on uneven sample spacing);
    /// missing neighbours at the ends are reflected phantom points.
    ///
    /// The ink of a segment is the union of the convex hulls of consecutive nib stamps. The hull of two
    /// stamps is the two stamps plus the quad between their common tangents. Emitting every hull whole
    /// gave heavily overlapping polygons of 10–60 vertices each, and filling that soup is what costs:
    /// Core Graphics' fill time follows edge count and overlap depth, not pixel count. So this emits:
    ///  - the **tangent quads**, chained into strips: two vertices per side per step, no convex-hull
    ///    pass, and no shared edges between quads to leave antialiasing seams; and
    ///  - a **stamp** polygon only where the quads alone would leave a gap:
    ///    - at the two ends of the stroke (the caps);
    ///    - where two neighbouring quads' tangent points on a stamp are far enough apart (a sharp bend)
    ///      to open a sliver deeper than `joinTolerance`;
    ///    - where the nib shrinks too fast for common tangents to exist;
    ///    - where a strip has to break: when the quantised alpha changes (a new run), at the start of
    ///      the segment when `leadingStamp` is set (a new chunk or the live tail, each filled apart),
    ///      and where a step is too short to weld safely. The broken ends only abut, so the stamp
    ///      overlaps both.
    ///
    /// Welding two quads that meet at an angle adds the sliver between their ends on the outside of the
    /// bend and subtracts it on the inside, where the quads overlap. That is only safe while the quads
    /// are longer than the sliver is wide, hence the short-step rule.
    ///
    /// At a point shared by two segments, each side measures its turn and alpha against a reference both
    /// compute identically from the points they share (`referenceNormals`), so a segment never needs
    /// its neighbour's geometry.
    static func segmentHulls(_ pts: [StrokePoint], segment i: Int, style: BrushStyle,
                             leadingStamp: Bool = false) -> [Hull] {
        let a = pts[i], b = pts[i + 1]
        let p1 = a.location, p2 = b.location
        let p0 = i > 0 ? pts[i - 1].location : p1 * 2 - p2
        let p3 = i + 2 < pts.count ? pts[i + 2].location : p2 * 2 - p1
        let (c1, c2) = centripetalControls(p0, p1, p2, p3)
        let startTip = tip(for: a, style: style)
        var prev = Nib(startTip)
        let endTip = tip(for: b, style: style)
        let steps = stepCount(p1, c1, c2, p2, from: prev.tip, to: endTip)

        var hulls: [Hull] = []
        hulls.reserveCapacity(4)

        // The strip being built: both sides of the quads so far, and whether it carries on from the
        // strip that ended the previous segment.
        var left: [CGPoint] = [], right: [CGPoint] = []
        var stripJoins = false
        var stripAlpha: CGFloat = 0
        func endStrip() {
            guard !right.isEmpty else { return }
            hulls.append(Hull(left: left, right: right, joinsPrevious: stripJoins, alpha: stripAlpha))
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            stripJoins = false
        }

        // Tangent points of the previous quad (or of the spline tangent at the segment start) on `prev`.
        // nil: unknown, so `prev` must be stamped unless it already was.
        var lastL: CGPoint?, lastR: CGPoint?
        var lastNL = CGPoint.zero, lastNR = CGPoint.zero
        var prevStamped = false
        var lastQuantum = (prev.tip.alpha * alphaSteps).rounded()
        if i == 0 || leadingStamp {
            hulls.append(prev.stamp)   // start cap, or overlap with the previous fill
            prevStamped = true
        } else if let (nL, nR) = referenceNormals(at: prev, tangent: c1 - p1, chord: p2 - p1,
                                                  before: tip(for: pts[i - 1], style: style), after: endTip) {
            lastNL = nL
            lastNR = nR
            lastL = prev.support(nL)
            lastR = prev.support(nR)
        }
        // Segment boundaries split the allowed sliver between the two segments that meet there.
        var tolerance = joinTolerance / 2

        /// Whether a quad whose tangent points on a nib are `p` (normal `u`) can weld to one whose are
        /// `q` (normal `v`): the sliver between them is shallower than `tolerance` and much narrower
        /// than the quads are long.
        func welds(_ p: CGPoint, _ q: CGPoint, _ u: CGPoint, _ v: CGPoint, length: CGFloat) -> Bool {
            guard u.x * v.x + u.y * v.y > 0 else { return false }
            let width = p.distance(to: q)
            return width * abs(u.x * v.y - u.y * v.x) / 8 <= tolerance && width <= 0.5 * length
        }

        var lastDist: CGFloat = 0
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let loc = s == steps ? p2 : bezier(p1, c1, c2, p2, t)
            let next = Nib(tip(for: interpolate(a, b, t, at: loc), style: style))
            defer {
                prev = next
                tolerance = joinTolerance
            }

            let dx = next.tip.center.x - prev.tip.center.x, dy = next.tip.center.y - prev.tip.center.y
            let dist = hypot(dx, dy)
            let dir = dist > 1e-6 ? CGPoint(x: dx / dist, y: dy / dist) : .zero
            let n = CGPoint(x: -dir.y, y: dir.x)
            // The common tangents lean toward the smaller nib by φ, sin φ = Δreach / distance.
            let sinPhi = dist > 1e-6 ? (prev.reach(n) - next.reach(n)) / dist : .infinity
            guard abs(sinPhi) < steepTaper else {
                // One stamp (nearly) swallows the other: the two stamps are the hull.
                endStrip()
                if !prevStamped { hulls.append(prev.stamp) }
                hulls.append(next.stamp)
                prevStamped = true
                lastL = nil
                lastR = nil
                continue
            }
            let cosPhi = (1 - sinPhi * sinPhi).squareRoot()
            let nL = CGPoint(x: n.x * cosPhi + dir.x * sinPhi, y: n.y * cosPhi + dir.y * sinPhi)
            let nR = CGPoint(x: -n.x * cosPhi + dir.x * sinPhi, y: -n.y * cosPhi + dir.y * sinPhi)
            let aL = prev.support(nL), aR = prev.support(nR)
            let bL = next.support(nL), bR = next.support(nR)
            let alpha = (prev.tip.alpha + next.tip.alpha) * 0.5
            let quantum = (alpha * alphaSteps).rounded()

            if quantum == lastQuantum, let lastL, let lastR,
               welds(lastL, aL, lastNL, nL, length: dist), welds(lastR, aR, lastNR, nR, length: dist) {
                // Smooth join: carry the strip on, from the previous segment's if this is the first quad.
                if right.isEmpty { stripJoins = true }
            } else {
                endStrip()
                if !prevStamped { hulls.append(prev.stamp) }
            }
            if right.isEmpty { stripAlpha = alpha }
            left.append(aL)
            left.append(bL)
            right.append(aR)
            right.append(bR)

            lastL = bL
            lastR = bR
            lastNL = nL
            lastNR = nR
            lastQuantum = quantum
            lastDist = dist
            prevStamped = false
        }
        endStrip()

        // `prev` is now the nib at pts[i + 1].
        if !prevStamped {
            let isLast = i + 2 >= pts.count
            tolerance = joinTolerance / 2
            if !isLast, lastQuantum == (prev.tip.alpha * alphaSteps).rounded(),
               let lastL, let lastR,
               let (n, nR) = referenceNormals(at: prev, tangent: p2 - c2, chord: p2 - p1,
                                              before: startTip, after: tip(for: pts[i + 2], style: style)) {
                if !welds(lastL, prev.support(n), lastNL, n, length: lastDist)
                    || !welds(lastR, prev.support(nR), lastNR, nR, length: lastDist) {
                    hulls.append(prev.stamp)
                }
            } else {
                hulls.append(prev.stamp)   // end cap
            }
        }
        return hulls
    }

    static func hulls(for points: [StrokePoint], style: BrushStyle) -> [Hull] {
        switch points.count {
        case 0: return []
        case 1: return [dotHull(points[0], style: style)]
        default:
            return (0..<(points.count - 1)).flatMap {
                segmentHulls(points, segment: $0, style: style,
                             leadingStamp: $0 % LiveStroke.chunkSize == 0)
            }
        }
    }

    static func runs<S: Sequence>(from hulls: S) -> [StrokeRun] where S.Element == Hull {
        var runs: [StrokeRun] = []
        var path = CGMutablePath()
        var alpha: CGFloat = -1
        var empty = true
        // The strip being welded together from consecutive pieces.
        var left: [CGPoint] = [], right: [CGPoint] = []
        func endStrip() {
            guard !right.isEmpty else { return }
            // Right side forward, left side back: the same winding as the stamp polygons.
            path.addLines(between: right + left.reversed())
            path.closeSubpath()
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
        }
        for h in hulls {
            let isStamp = h.polygon.count > 2
            guard isStamp || !h.right.isEmpty else { continue }
            let q = (h.alpha * alphaSteps).rounded() / alphaSteps
            if q != alpha && !empty {
                endStrip()
                runs.append(StrokeRun(path: path, alpha: alpha))
                path = CGMutablePath()
            }
            alpha = q
            empty = false
            if isStamp {
                path.addLines(between: h.polygon)
                path.closeSubpath()
            } else {
                if !h.joinsPrevious { endStrip() }
                left.append(contentsOf: h.left)
                right.append(contentsOf: h.right)
            }
        }
        endStrip()
        if !empty { runs.append(StrokeRun(path: path, alpha: alpha)) }
        return runs
    }

    static func geometry(for stroke: Stroke) -> StrokeGeometry {
        let hulls = hulls(for: stroke.points, style: stroke.style)
        let bounds = hulls.reduce(CGRect.null) { $0.union($1.bounds) }
        return StrokeGeometry(runs: runs(from: hulls), bounds: bounds)
    }

    // MARK: Drawing

    /// Draws a stroke's runs. `ctx` must already be in canvas space.
    /// Multi-run strokes (alpha varying with tilt) go through a transparency layer where each run
    /// *replaces* (`.copy`) what's under it, so overlapping joints never accumulate alpha; the layer
    /// then composites once with the stroke's blend mode.
    /// `liveEraserColor`: preview pixel-erasing by painting paper colour (the live layer can't punch holes).
    static func draw(runs: [StrokeRun], clip: CGRect, kind: InkKind, color: RGBA,
                     in ctx: CGContext, liveEraserColor: CGColor? = nil) {
        guard !runs.isEmpty else { return }
        let fill: (CGFloat) -> CGColor = { alpha in
            if let liveEraserColor { return liveEraserColor }
            if kind == .pencil {
                return PencilTexture.fillColor(for: color, alpha: alpha)
            }
            return color.cgColor(alpha: alpha)
        }
        ctx.saveGState()
        ctx.setBlendMode(liveEraserColor == nil ? kind.blendMode : .normal)
        if runs.count == 1 {
            ctx.setFillColor(fill(runs[0].alpha))
            ctx.addPath(runs[0].path)
            ctx.fillPath(using: .winding)
        } else if runs.allSatisfy({ $0.alpha >= 0.999 }) {
            for run in runs {
                ctx.setFillColor(fill(run.alpha))
                ctx.addPath(run.path)
                ctx.fillPath(using: .winding)
            }
        } else {
            ctx.clip(to: clip)   // keeps the transparency layer's offscreen buffer small
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setBlendMode(.copy)
            for run in runs {
                ctx.setFillColor(fill(run.alpha))
                ctx.addPath(run.path)
                ctx.fillPath(using: .winding)
            }
            ctx.endTransparencyLayer()
        }
        ctx.restoreGState()
    }

    // MARK: Hit testing (stroke eraser)

    static func hitTest(_ stroke: Stroke, bounds: CGRect, point: CGPoint, radius: CGFloat) -> Bool {
        guard bounds.insetBy(dx: -radius, dy: -radius).contains(point) else { return false }
        let pts = stroke.points
        func reach(_ p: StrokePoint) -> CGFloat { tip(for: p, style: stroke.style).major + radius }
        guard pts.count > 1 else {
            return pts.first.map { point.distance(to: $0.location) <= reach($0) } ?? false
        }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if point.distance(toSegment: a.location, b.location) <= max(reach(a), reach(b)) { return true }
        }
        return false
    }

    // MARK: Math helpers

    static func centripetalControls(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> (CGPoint, CGPoint) {
        let eps: CGFloat = 1e-4
        let d1 = p0.distance(to: p1), d2 = p1.distance(to: p2), d3 = p2.distance(to: p3)
        guard d2 > eps else { return (p1, p2) }
        let d1a = d1.squareRoot(), d2a = d2.squareRoot(), d3a = d3.squareRoot()
        let c1 = d1 > eps
            ? (p2 * d1 - p0 * d2 + p1 * (2 * d1 + 3 * d1a * d2a + d2)) / (3 * d1a * (d1a + d2a))
            : p1 + (p2 - p1) / 3
        let c2 = d3 > eps
            ? (p1 * d3 - p3 * d2 + p2 * (2 * d3 + 3 * d3a * d2a + d2)) / (3 * d3a * (d3a + d2a))
            : p2 + (p1 - p2) / 3
        return (c1, c2)
    }

    static func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
    }

    static func interpolate(_ a: StrokePoint, _ b: StrokePoint, _ t: CGFloat, at location: CGPoint) -> StrokePoint {
        let dAz = atan2(sin(b.azimuth - a.azimuth), cos(b.azimuth - a.azimuth))   // shortest way round
        return StrokePoint(location: location,
                           force: a.force + (b.force - a.force) * t,
                           altitude: a.altitude + (b.altitude - a.altitude) * t,
                           azimuth: a.azimuth + dAz * t,
                           timestamp: a.timestamp + (b.timestamp - a.timestamp) * Double(t))
    }
}

// MARK: - In-progress stroke

/// Incrementally built geometry for the stroke under the Pencil.
/// Spline segment i depends on points i-1...i+2, so it's "final" once point i+2 is a real sample;
/// the last segment(s) plus predicted points form a provisional tail rebuilt on every event.
final class LiveStroke {
    /// Segments per chunk. Each chunk is one cached path, filled separately; its first segment carries a
    /// leading stamp so neighbouring chunks overlap (see `StrokeRenderer.segmentHulls`).
    static let chunkSize = 8
    /// Segments that may stay un-baked waiting for estimated-property updates before the live layer
    /// stops waiting. A lost update must not make the per-frame redraw grow without bound.
    static let maxUnsettledSegments = 64

    var stroke: Stroke
    var lastPredicted: [StrokePoint] = []
    /// Indices of points whose force/tilt are still estimates and will be refined by
    /// `touchesEstimatedPropertiesUpdated`.
    var unsettledPoints = Set<Int>()

    private(set) var finalized: [[Hull]] = []
    private(set) var tail: [Hull] = []
    private var tailBounds = CGRect.null

    private struct Chunk {
        var bounds: CGRect = .null
        var runs: [StrokeRun]?
    }
    private var chunks: [Chunk] = []

    init(stroke: Stroke) {
        self.stroke = stroke
    }

    /// Number of finalized spline segments.
    var finalizedCount: Int {
        finalized.count
    }

    var allHulls: [Hull] {
        Array(finalized.joined()) + tail
    }

    /// Unchanged contract: finalize every segment whose 4 control points are real samples
    /// (while finalizedCount + 2 < stroke.points.count). Returns canvas-space dirty rect.
    @discardableResult
    func finalizeAvailable() -> CGRect {
        var dirty = CGRect.null
        while finalized.count + 2 < stroke.points.count {
            let segIndex = finalized.count
            let hulls = StrokeRenderer.segmentHulls(stroke.points, segment: segIndex, style: stroke.style,
                                                    leadingStamp: segIndex % Self.chunkSize == 0)
            var segBounds = CGRect.null
            for h in hulls {
                segBounds = segBounds.union(h.bounds)
            }
            dirty = dirty.union(segBounds)
            finalized.append(hulls)

            let chunkIndex = segIndex / Self.chunkSize
            if chunkIndex == chunks.count {
                chunks.append(Chunk(bounds: segBounds, runs: nil))
            } else {
                chunks[chunkIndex].bounds = chunks[chunkIndex].bounds.union(segBounds)
                chunks[chunkIndex].runs = nil
            }
        }
        return dirty
    }

    /// Unchanged contract: rebuild the provisional tail (segments finalizedCount..<end, or a dot for a
    /// single point) from the real points plus `predicted`. Returns old-tail ∪ new-tail bounds.
    /// MUST NOT copy all of stroke.points: build a small local array from
    /// stroke.points[max(0, finalizedCount - 1)...] + predicted and offset segment indices accordingly
    /// (segment i needs points i-1...i+2; the local array must reproduce the same p0 neighbour, i.e. the
    /// reflected phantom only when the real segment index is 0).
    @discardableResult
    func rebuildTail(predicted: [StrokePoint]) -> CGRect {
        lastPredicted = predicted
        var dirty = tailBounds
        let totalCount = stroke.points.count + predicted.count
        var hulls: [Hull] = []

        if totalCount == 1 {
            if let pt = stroke.points.first ?? predicted.first {
                hulls = [StrokeRenderer.dotHull(pt, style: stroke.style)]
            }
        } else if totalCount > 1 {
            let start = max(0, finalized.count - 1)
            let slice = start < stroke.points.count ? stroke.points[start...] : stroke.points[...]
            let localPts = Array(slice) + predicted
            for i in finalized.count..<(totalCount - 1) {
                let localIndex = i - start
                guard localIndex >= 0 && localIndex + 1 < localPts.count else { continue }
                // The tail is filled apart from the last chunk, so its first segment overlaps it.
                hulls.append(contentsOf: StrokeRenderer.segmentHulls(
                    localPts, segment: localIndex, style: stroke.style,
                    leadingStamp: i == finalized.count || i % Self.chunkSize == 0))
            }
        }

        tail = hulls
        tailBounds = hulls.reduce(CGRect.null) { $0.union($1.bounds) }
        dirty = dirty.union(tailBounds)
        return dirty
    }

    /// Call after changing force/altitude/azimuth (NOT location) of stroke.points[index].
    /// Recomputes IN PLACE only the finalized segments index-1 and index (whichever exist and are finalized),
    /// marks their chunk(s) dirty, and returns the old ∪ new bounds of the replaced segments as `dirty`.
    /// `touchesTail` is true when segment `index` (or the dot of a 1-point stroke) is not finalized, meaning
    /// the caller must call rebuildTail. Out-of-range index → (.null, false).
    func refreshPoint(_ index: Int) -> (dirty: CGRect, touchesTail: Bool) {
        guard stroke.points.indices.contains(index) else {
            return (.null, false)
        }

        let touchesTail = index >= finalized.count
        var dirty = CGRect.null
        var modifiedChunks = Set<Int>()

        for seg in [index - 1, index] {
            guard seg >= 0 && seg < finalized.count else { continue }
            for h in finalized[seg] {
                dirty = dirty.union(h.bounds)
            }
            let newHulls = StrokeRenderer.segmentHulls(stroke.points, segment: seg, style: stroke.style,
                                                       leadingStamp: seg % Self.chunkSize == 0)
            for h in newHulls {
                dirty = dirty.union(h.bounds)
            }
            finalized[seg] = newHulls
            modifiedChunks.insert(seg / Self.chunkSize)
        }

        for c in modifiedChunks {
            guard c < chunks.count else { continue }
            chunks[c].runs = nil
            let startSeg = c * Self.chunkSize
            let endSeg = min((c + 1) * Self.chunkSize, finalized.count)
            var b = CGRect.null
            for s in startSeg..<endSeg {
                for h in finalized[s] {
                    b = b.union(h.bounds)
                }
            }
            chunks[c].bounds = b
        }

        return (dirty, touchesTail)
    }

    /// Chunks below this index are complete and settled: no point they depend on is still waiting for
    /// an estimated-property update. The live layer rasterizes each of them once ("bakes" it) and never
    /// fills its path again; everything from this index on is redrawn per frame.
    var bakeableChunkCount: Int {
        var settled = finalized.count
        if let firstOpen = unsettledPoints.min() {
            // Segment k is shaped by the nibs at points k and k+1.
            settled = min(settled, max(firstOpen - 1, 0))
        }
        return max(settled, finalized.count - Self.maxUnsettledSegments) / Self.chunkSize
    }

    func chunkBounds(_ c: Int) -> CGRect { chunks[c].bounds }

    func chunkRuns(_ c: Int) -> [StrokeRun] { ensureChunkRuns(c) }

    /// Bounds of each chunk plus the tail: where the stroke has ink, without the empty space a single
    /// bounding box of a long stroke would cover.
    var pieceBounds: [CGRect] {
        var result = chunks.map(\.bounds)
        if !tailBounds.isNull { result.append(tailBounds) }
        return result
    }

    /// For drawing the live layer: cached runs of every chunk from `first` on whose bounds intersect
    /// `rect`, in chunk order, followed by runs built from the tail hulls that intersect `rect`.
    /// Must not rebuild clean chunks.
    func runs(intersecting rect: CGRect, fromChunk first: Int = 0) -> [StrokeRun] {
        var result: [StrokeRun] = []

        for c in first..<max(first, chunks.count) {
            guard chunks[c].bounds.intersects(rect) else { continue }
            result.append(contentsOf: ensureChunkRuns(c))
        }

        // All of the tail or none: its strips weld to each other, so pieces can't be dropped singly.
        if tailBounds.intersects(rect) {
            result.append(contentsOf: StrokeRenderer.runs(from: tail))
        }

        return result
    }

    /// Full geometry: calls finalizeAvailable() and rebuildTail(predicted: []), then returns all chunk runs
    /// (cached, rebuilding only dirty chunks) + tail runs, with bounds = union of chunk bounds and tail bounds.
    /// Must be O(chunks), not O(hulls), when chunks are clean.
    func geometry() -> StrokeGeometry {
        finalizeAvailable()
        rebuildTail(predicted: [])

        var allRuns: [StrokeRun] = []
        var totalBounds = CGRect.null

        for c in 0..<chunks.count {
            totalBounds = totalBounds.union(chunks[c].bounds)
            allRuns.append(contentsOf: ensureChunkRuns(c))
        }

        let tailRuns = StrokeRenderer.runs(from: tail)
        allRuns.append(contentsOf: tailRuns)
        totalBounds = totalBounds.union(tailBounds)

        return StrokeGeometry(runs: allRuns, bounds: totalBounds)
    }

    private func ensureChunkRuns(_ c: Int) -> [StrokeRun] {
        if let runs = chunks[c].runs {
            return runs
        }
        let startSeg = c * Self.chunkSize
        let endSeg = min((c + 1) * Self.chunkSize, finalized.count)
        guard startSeg < endSeg else {
            chunks[c].runs = []
            return []
        }
        let runs = StrokeRenderer.runs(from: finalized[startSeg..<endSeg].joined())
        chunks[c].runs = runs
        return runs
    }
}

// MARK: - CGPoint arithmetic

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }
    static func / (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x / r, y: l.y / r) }

    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }

    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 1e-9 else { return distance(to: a) }
        let t = min(max(((x - a.x) * ab.x + (y - a.y) * ab.y) / len2, 0), 1)
        return distance(to: a + ab * t)
    }
}
