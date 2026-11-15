import CoreGraphics
import Foundation

/// The on-screen ruler (or protractor) that strokes snap to. It isn't on the page: it sits over the canvas
/// in screen space, like a real ruler laid on paper, and isn't saved with the note. One finger moves it, two
/// fingers turn it, and a pen, pencil or highlighter stroke that starts near one of its edges is drawn along
/// that edge (`guide(at:)`), however the hand wobbles.
///
/// Positions are in the coordinate space of the view showing it (`RulerView`), in view points.
///
/// - **Ruler:** a long straight edge `width` points deep. Both long edges guide strokes.
/// - **Protractor:** a half disc of `protractorRadius` over its baseline. Strokes that start near the arc
///   follow the arc, and strokes that start near the baseline follow it.
struct Ruler: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case ruler, protractor

        var id: String {
            rawValue
        }
    }

    /// The middle of the ruler (or the protractor's centre, on its baseline).
    var center: CGPoint
    /// Which way the ruler's long edges run, in radians clockwise from the x axis (y is down).
    var angle: CGFloat
    var mode: Mode = .ruler

    /// Longer than any iPad screen is wide, so the ruler reaches across the page at any angle.
    static let length: CGFloat = 1600
    static let width: CGFloat = 88
    static let protractorRadius: CGFloat = 200
    /// How far outside an edge (view points) a stroke can start and still snap to it.
    static let snapDistance: CGFloat = 28
    /// Turning the ruler snaps to multiples of 15° within this many radians.
    static let angleSnap: CGFloat = 1.5 * .pi / 180

    /// Along the long edges.
    var direction: CGPoint {
        CGPoint(x: cos(angle), y: sin(angle))
    }

    /// Across the ruler, a quarter turn clockwise from `direction` (towards the bottom edge when level).
    var normal: CGPoint {
        CGPoint(x: -sin(angle), y: cos(angle))
    }

    /// The ruler's position relative to its own axes: `x` along `direction`, `y` along `normal`.
    func local(_ p: CGPoint) -> CGPoint {
        let d = p - center
        return CGPoint(x: d.x * direction.x + d.y * direction.y, y: d.x * normal.x + d.y * normal.y)
    }

    /// A point given in the ruler's own axes, in view space.
    func point(along x: CGFloat, across y: CGFloat) -> CGPoint {
        center + direction * x + normal * y
    }

    /// Whether `p` is on the ruler's body, where a finger moves or turns it.
    func contains(_ p: CGPoint) -> Bool {
        let l = local(p)
        switch mode {
        case .ruler:
            return abs(l.x) <= Self.length / 2 && abs(l.y) <= Self.width / 2
        case .protractor:
            // The half disc above the baseline, and a little below it to grab the baseline itself.
            return hypot(l.x, l.y) <= Self.protractorRadius && l.y <= 12
        }
    }

    /// The edge a stroke starting at `p` is drawn along, if it starts within `snapDistance` outside an edge
    /// or anywhere on the body (then the nearer edge). Nil if it starts away from the ruler.
    func guide(at p: CGPoint, snapDistance: CGFloat = Ruler.snapDistance) -> RulerGuide? {
        let l = local(p)
        switch mode {
        case .ruler:
            guard abs(l.x) <= Self.length / 2 + snapDistance else { return nil }
            let half = Self.width / 2
            // How far outside each edge: negative inside the body.
            let outsideTop = -l.y - half, outsideBottom = l.y - half
            guard max(outsideTop, outsideBottom) <= snapDistance else { return nil }
            // The nearer edge is the one the point is least far inside of (or furthest outside).
            let edge: CGFloat = outsideTop > outsideBottom ? -half : half
            return .line(origin: point(along: 0, across: edge), direction: direction)
        case .protractor:
            let r = hypot(l.x, l.y), radius = Self.protractorRadius
            let nearArc = l.y <= snapDistance && r >= radius * 0.6 && r <= radius + snapDistance
            let nearBase = abs(l.y) <= snapDistance && abs(l.x) <= radius + snapDistance
            // The arc wins near the ends of the baseline, where both are close.
            if nearArc, abs(r - radius) <= abs(l.y) || !nearBase {
                return .arc(center: center, radius: radius)
            }
            return nearBase ? .line(origin: center, direction: direction) : nil
        }
    }

    /// The ruler's angle in whole degrees as it's shown: 0–179 for the ruler (a straight edge turned half a
    /// turn is the same edge), 0–359 for the protractor.
    var displayedDegrees: Int {
        let degrees = Double(angle) * 180 / .pi
        let period = mode == .ruler ? 180.0 : 360.0
        let wrapped = degrees.truncatingRemainder(dividingBy: period)
        let positive = (wrapped < 0 ? wrapped + period : wrapped).rounded()
        return Int(positive) % Int(period)
    }

    /// `angle` snapped to the nearest 15° if it's within `angleSnap` of it.
    static func snappedAngle(_ angle: CGFloat) -> CGFloat {
        let step = CGFloat.pi / 12
        let nearest = (angle / step).rounded() * step
        return abs(angle - nearest) <= angleSnap ? nearest : angle
    }
}

/// A line or circle a stroke is drawn along: the ruler's edge (`Ruler.guide(at:)`), in whichever space its
/// points are in. Projecting a point onto it is a few multiplications, so it's cheap enough to do to every
/// sample in the live-ink path.
enum RulerGuide: Equatable {
    /// The line through `origin` along `direction` (a unit vector).
    case line(origin: CGPoint, direction: CGPoint)
    case arc(center: CGPoint, radius: CGFloat)

    /// The nearest point on the guide to `p`.
    func project(_ p: CGPoint) -> CGPoint {
        switch self {
        case let .line(o, d):
            let t = (p.x - o.x) * d.x + (p.y - o.y) * d.y
            return CGPoint(x: o.x + d.x * t, y: o.y + d.y * t)
        case let .arc(c, r):
            let dx = p.x - c.x, dy = p.y - c.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 1e-9 else { return CGPoint(x: c.x + r, y: c.y) }
            return CGPoint(x: c.x + dx / len * r, y: c.y + dy / len * r)
        }
    }

    /// The guide carried through `map` (say, from the view to the page): `map` must be a similarity
    /// (a uniform scale, a turn and a move), as the canvas's view transforms are.
    func mapped(_ map: (CGPoint) -> CGPoint) -> RulerGuide {
        switch self {
        case let .line(o, d):
            let a = map(o), b = map(o + d)
            let len = a.distance(to: b)
            return .line(origin: a, direction: len > 1e-9 ? (b - a) / len : d)
        case let .arc(c, r):
            let mc = map(c)
            return .arc(center: mc, radius: mc.distance(to: map(CGPoint(x: c.x + r, y: c.y))))
        }
    }
}

/// What a stroke along the ruler has measured so far, in page space: its length along an edge, or the angle
/// it has swept around the protractor's arc. Advanced once per touch event with the stroke's latest point,
/// never with predicted points.
struct RulerMeasurement: Equatable {
    let guide: RulerGuide
    private(set) var start: CGPoint?
    private(set) var last: CGPoint?
    /// Radians swept around an arc, signed (clockwise positive, y down).
    private(set) var sweep: CGFloat = 0

    init(guide: RulerGuide) {
        self.guide = guide
    }

    mutating func advance(to p: CGPoint) {
        let q = guide.project(p)
        guard let previous = last else {
            start = q
            last = q
            return
        }
        if case let .arc(c, _) = guide {
            var delta = atan2(q.y - c.y, q.x - c.x) - atan2(previous.y - c.y, previous.x - c.x)
            if delta > .pi {
                delta -= 2 * .pi
            } else if delta < -.pi {
                delta += 2 * .pi
            }
            sweep += delta
        }
        last = q
    }

    /// How far the stroke runs along a straight edge, in page points (0 on an arc).
    var length: CGFloat {
        guard case .line = guide, let start, let last else { return 0 }
        return start.distance(to: last)
    }

    /// How far round the arc the stroke has gone, in degrees (0 on a straight edge).
    var sweptDegrees: CGFloat {
        abs(sweep) * 180 / .pi
    }

    /// The readout shown by the stroke: its length in centimetres, or the angle it sweeps.
    var readout: String {
        switch guide {
        case .line: Self.centimetresText(length)
        case .arc: "\(Int(sweptDegrees.rounded()))°"
        }
    }

    /// Page points are 1/72 inch, so a centimetre is 72 / 2.54 ≈ 28.35 points.
    static let pointsPerCentimetre: CGFloat = 72 / 2.54

    static func centimetres(fromPoints points: CGFloat) -> CGFloat {
        points / pointsPerCentimetre
    }

    /// `points` of page as centimetres to one decimal place, e.g. "12.5 cm".
    static func centimetresText(_ points: CGFloat) -> String {
        let cm = (centimetres(fromPoints: points) * 10).rounded() / 10
        return String(format: "%.1f cm", Double(cm))
    }
}
