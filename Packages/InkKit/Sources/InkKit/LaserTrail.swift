import CoreGraphics
import Foundation

/// The laser pointer's marks, for presenting: a glowing line that fades away about a second after it's drawn
/// (`trail`), or a dot that follows the touch and fades as soon as it lifts (`dot`). Nothing is ever put on
/// the page; points are in page space so the canvas and an external display (`InkPresentation`) can each
/// draw them at their own zoom.
///
/// The trail is a value: the canvas updates it as the touch moves and prunes it as time passes, and hands
/// copies to whatever mirrors it.
public struct LaserTrail: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case trail, dot

        public var id: String {
            rawValue
        }
    }

    public struct Point: Equatable, Sendable {
        public var location: CGPoint
        public var time: TimeInterval
        /// The first point of a new line: it isn't joined to the point before it.
        public var startsLine: Bool
    }

    public var mode: Mode
    /// Newest last. In dot mode, only the latest point.
    public private(set) var points: [Point] = []
    /// Whether a touch is drawing now.
    public private(set) var isDrawing = false
    /// When the touch lifted, while it's up.
    public private(set) var liftedAt: TimeInterval?

    /// How long a trail point stays before it's gone, fading all the way.
    public static let fadeDuration: TimeInterval = 1.0
    /// How long the dot takes to fade once the touch lifts.
    public static let dotFadeDuration: TimeInterval = 0.3

    public init(mode: Mode = .trail) {
        self.mode = mode
    }

    public mutating func begin(at p: CGPoint, time: TimeInterval) {
        isDrawing = true
        liftedAt = nil
        let point = Point(location: p, time: time, startsLine: true)
        if mode == .dot {
            points = [point]
        } else {
            points.append(point)
        }
    }

    public mutating func move(to p: CGPoint, time: TimeInterval) {
        guard isDrawing else { return begin(at: p, time: time) }
        let point = Point(location: p, time: time, startsLine: false)
        if mode == .dot {
            points = [point]
        } else if points.last?.location != p {
            points.append(point)
        }
    }

    public mutating func end(time: TimeInterval) {
        guard isDrawing else { return }
        isDrawing = false
        liftedAt = time
    }

    /// Drops what has faded away by `now`. A trail's points go a second after they were drawn (the point the
    /// touch is on stays while it's down); the dot goes once it has faded after the lift.
    public mutating func prune(now: TimeInterval) {
        switch mode {
        case .trail:
            let cutoff = now - Self.fadeDuration
            guard let firstKept = points.firstIndex(where: { $0.time > cutoff }) else {
                points = isDrawing ? Array(points.suffix(1)) : []
                return
            }
            if firstKept > 0 {
                // The first point kept starts a line if the line it was in has gone.
                let continues = !points[firstKept].startsLine
                points.removeFirst(firstKept)
                if continues, !points.isEmpty {
                    points[0].startsLine = true
                }
            }
        case .dot:
            if let liftedAt, now - liftedAt >= Self.dotFadeDuration {
                points = []
            }
        }
    }

    /// How strongly `point` shows at `now`, from 1 (just drawn) to 0 (gone).
    public func opacity(of point: Point, now: TimeInterval) -> CGFloat {
        switch mode {
        case .trail:
            return CGFloat(min(max(1 - (now - point.time) / Self.fadeDuration, 0), 1))
        case .dot:
            guard let liftedAt else { return 1 }
            return CGFloat(min(max(1 - (now - liftedAt) / Self.dotFadeDuration, 0), 1))
        }
    }

    /// The point the touch is on (or was last on), drawn as a bright dot at the head of the trail.
    public var head: Point? {
        points.last
    }

    /// How strongly the head's dot shows at `now`: fully while drawing, fading after the lift.
    public func headOpacity(now: TimeInterval) -> CGFloat {
        guard !isDrawing, let liftedAt else { return points.isEmpty ? 0 : 1 }
        let fade = mode == .dot ? Self.dotFadeDuration : Self.fadeDuration
        return CGFloat(min(max(1 - (now - liftedAt) / fade, 0), 1))
    }

    /// Whether nothing is left to draw: no points, and no touch down.
    public var isEmpty: Bool {
        points.isEmpty && !isDrawing
    }

    /// The smallest rectangle (page space) holding every point.
    public var bounds: CGRect {
        guard let first = points.first?.location else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.location.x)
            maxX = max(maxX, p.location.x)
            minY = min(minY, p.location.y)
            maxY = max(maxY, p.location.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
