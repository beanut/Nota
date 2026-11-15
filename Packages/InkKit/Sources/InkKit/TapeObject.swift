import CoreGraphics
import Foundation

/// A strip of tape over the page: a study aid that covers what's under it until it's tapped.
///
/// **Layer.** Unlike every other object, tape is drawn *over* the ink (`drawsOverInk`), so it hides the
/// writing under it as well as the paper and objects. Hidden, it's opaque; revealed, it's a faint tint with a
/// dashed outline, so what's under it shows through and the strip is still there to tap again.
///
/// **Geometry.** The strip is its `frame`, centred on its own origin (`length` × `width`), and its
/// `transform` turns and places it on the page, so a strip drawn at an angle is a rotated rectangle like a
/// rotated shape. Its short ends are cut in a zigzag, as torn tape is.
///
/// **Toggling.** With any tool but the lasso and the eraser, a tap on a tape reveals or hides it
/// (`toggled()`); the lasso selects it like any object, to move, rotate, resize, recolour or delete it.
/// Revealing and hiding are undoable edits, so they're saved with the note.
///
/// File kind `"tape"`; its own fields are `color` (`"#RRGGBB"`), `pattern` (absent for plain) and `revealed`
/// (absent for hidden). Reading is lenient: an unknown pattern is plain and a bad colour takes the default,
/// so a strip is never lost.
public struct TapeObject: PageObject, Equatable {
    public static let kind = "tape"
    public static let drawsOverInk = true

    /// What's printed on the tape, over its colour.
    public enum Pattern: String, Codable, CaseIterable, Identifiable, Sendable {
        case plain, striped, grid

        public var id: String {
            rawValue
        }
    }

    public let id: UUID
    public var frame: CGRect
    public var transform: CGAffineTransform
    public var zIndex: Int
    public var color: PenColor
    public var pattern: Pattern
    /// Whether the tape is see-through, showing what it covers. New tape is hidden: it covers.
    public var isRevealed: Bool

    /// The default strip width, in page points.
    public static let defaultWidth: CGFloat = 20
    /// The shortest strip the tape tool makes, in page points: a tap with it isn't a strip.
    public static let minimumLength: CGFloat = 12
    static let defaultColor = PenColor(rgb: 0xE8D7A9)

    public init(id: UUID = UUID(), frame: CGRect, transform: CGAffineTransform = .identity, zIndex: Int = 0,
                color: PenColor, pattern: Pattern = .plain, isRevealed: Bool = false) {
        self.id = id
        self.frame = frame
        self.transform = transform
        self.zIndex = zIndex
        self.color = color
        self.pattern = pattern
        self.isRevealed = isRevealed
    }

    /// A hidden strip `width` page points wide from `start` to `end` (page space), at least `minimumLength`
    /// long. Its frame is centred on its own origin, and its transform turns it to the drag and puts its
    /// middle halfway between the two points.
    public init(id: UUID = UUID(), from start: CGPoint, to end: CGPoint, width: CGFloat = TapeObject.defaultWidth,
                color: PenColor, pattern: Pattern = .plain) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), Self.minimumLength)
        let angle = hypot(dx, dy) > 1e-6 ? atan2(dy, dx) : 0
        let w = max(width, 1)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        self.init(id: id, frame: CGRect(x: -length / 2, y: -w / 2, width: length, height: w),
                  transform: CGAffineTransform(rotationAngle: angle).concatenating(
                      CGAffineTransform(translationX: mid.x, y: mid.y)
                  ),
                  color: color, pattern: pattern)
    }

    /// The tape revealed if it was hidden, hidden if it was revealed.
    public func toggled() -> TapeObject {
        revealed(!isRevealed)
    }

    /// The tape revealed (see-through) or hidden (covering).
    public func revealed(_ revealed: Bool) -> TapeObject {
        var copy = self
        copy.isRevealed = revealed
        return copy
    }

    public func recolored(_ color: PenColor) -> TapeObject {
        var copy = self
        copy.color = color
        return copy
    }

    // MARK: Drawing

    /// The strip's outline in its own space: a rectangle whose short ends are cut in a zigzag.
    var outline: CGPath {
        let r = frame
        let path = CGMutablePath()
        guard r.width > 0, r.height > 0 else { return path }
        let teeth = max(2, Int((r.height / 6).rounded()))
        let depth = min(r.height / CGFloat(teeth) * 0.5, r.width / 8)
        let step = r.height / CGFloat(teeth)
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        for i in 0 ..< teeth {
            let y = r.minY + CGFloat(i) * step
            path.addLine(to: CGPoint(x: r.maxX - depth, y: y + step / 2))
            path.addLine(to: CGPoint(x: r.maxX, y: y + step))
        }
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        for i in 0 ..< teeth {
            let y = r.maxY - CGFloat(i) * step
            path.addLine(to: CGPoint(x: r.minX + depth, y: y - step / 2))
            path.addLine(to: CGPoint(x: r.minX, y: y - step))
        }
        path.closeSubpath()
        return path
    }

    public func draw(in ctx: CGContext) {
        let base = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        // A darker edge in the tape's own colour, so pale tape still reads on white paper.
        let edge = CGColor(srgbRed: color.red * 0.72, green: color.green * 0.72, blue: color.blue * 0.72, alpha: 1)
        let path = outline
        let line = max(0.5, min(frame.height / 24, 1.25))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if isRevealed {
            ctx.addPath(path)
            ctx.setFillColor(base.copy(alpha: 0.16) ?? base)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(edge.copy(alpha: 0.8) ?? edge)
            ctx.setLineWidth(line)
            ctx.setLineDash(phase: 0, lengths: [4 * line, 3 * line])
            ctx.strokePath()
            return
        }
        ctx.addPath(path)
        ctx.setFillColor(base)
        ctx.fillPath()
        if pattern != .plain {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            drawPattern(in: ctx)
            ctx.restoreGState()
        }
        ctx.addPath(path)
        ctx.setStrokeColor(edge.copy(alpha: 0.55) ?? edge)
        ctx.setLineWidth(line)
        ctx.strokePath()
    }

    /// White lines over the colour: diagonal stripes, or a grid like washi tape's.
    private func drawPattern(in ctx: CGContext) {
        let r = frame
        let spacing = max(r.height / 3, 4)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45))
        ctx.setLineWidth(spacing / 3)
        switch pattern {
        case .plain:
            return
        case .striped:
            var x = r.minX - r.height
            while x < r.maxX {
                ctx.move(to: CGPoint(x: x, y: r.maxY))
                ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                x += spacing
            }
        case .grid:
            ctx.setLineWidth(max(spacing / 8, 0.5))
            var x = r.minX + spacing / 2
            while x < r.maxX {
                ctx.move(to: CGPoint(x: x, y: r.minY))
                ctx.addLine(to: CGPoint(x: x, y: r.maxY))
                x += spacing
            }
            var y = r.minY + spacing / 2
            while y < r.maxY {
                ctx.move(to: CGPoint(x: r.minX, y: y))
                ctx.addLine(to: CGPoint(x: r.maxX, y: y))
                y += spacing
            }
        }
        ctx.strokePath()
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case color, pattern, revealed
    }

    public init(from decoder: Decoder) throws {
        let placement = try PageObjectPlacement(from: decoder)
        id = placement.id
        frame = placement.frame
        transform = placement.transform
        zIndex = placement.zIndex
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = (try? c.decodeIfPresent(PenColor.self, forKey: .color)) ?? Self.defaultColor
        pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)).flatMap(Pattern.init(rawValue:)) ?? .plain
        isRevealed = (try? c.decodeIfPresent(Bool.self, forKey: .revealed)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        try PageObjectPlacement(of: self).encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        if pattern != .plain {
            try c.encode(pattern.rawValue, forKey: .pattern)
        }
        if isRevealed {
            try c.encode(true, forKey: .revealed)
        }
    }
}

// MARK: - Revealing and hiding

public extension CanvasDocument {
    /// The page's tape, lowest first.
    var tapes: [TapeObject] {
        objects.compactMap { $0 as? TapeObject }
    }

    /// Reveals the tape with this id if it's hidden, or hides it if it's revealed, as one undoable edit.
    /// Returns the tape as it is now, or nil if there's no tape with that id.
    @discardableResult
    func toggleTape(id: UUID) -> TapeObject? {
        guard let tape = object(id: id) as? TapeObject else { return nil }
        let toggled = tape.toggled()
        replaceObjects(before: [tape], after: [toggled])
        return toggled
    }

    /// Reveals (or hides) every tape on the page that isn't already, as one undoable edit. Returns how many
    /// changed.
    @discardableResult
    func setAllTape(revealed: Bool) -> Int {
        let before = tapes.filter { $0.isRevealed != revealed }
        guard !before.isEmpty else { return 0 }
        replaceObjects(before: before, after: before.map { $0.revealed(revealed) })
        return before.count
    }
}

extension Sequence<any PageObject> {
    /// The objects drawn under the ink (everything but tape), and those drawn over it (tape), in order.
    var splitByInkLayer: (under: [any PageObject], over: [any PageObject]) {
        var under: [any PageObject] = [], over: [any PageObject] = []
        for object in self {
            if object.drawsOverInk {
                over.append(object)
            } else {
                under.append(object)
            }
        }
        return (under, over)
    }
}
