import CoreGraphics
import Foundation

/// Tools the user can pick in the toolbar.
enum Tool: String, CaseIterable, Identifiable {
    case pen, pencil, highlighter, shape, text, tape, eraser, lasso, laser
    var id: String {
        rawValue
    }
}

extension Tool {
    /// The pen kind this tool is, if it's an ink tool (pen, pencil or highlighter).
    var penKind: PenKind? {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .shape, .text, .tape, .eraser, .lasso, .laser: nil
        }
    }
}

extension PenKind {
    var tool: Tool {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        }
    }
}

/// How the eraser removes ink.
enum EraserMode: String, CaseIterable, Identifiable {
    /// Pixel eraser: an invisible `pixelEraser` stroke punches out exactly the pixels under it, from
    /// every kind of ink.
    case precision
    /// Cuts away the parts of strokes the eraser passes over, leaving the rest as separate strokes.
    case standard
    /// Removes every stroke the eraser touches, whole.
    case stroke
    var id: String {
        rawValue
    }

    /// Whether the mode can be limited to one kind of ink (`EraserTarget`). A precision erase is a
    /// stroke of its own that composites over everything drawn before it, so it can't pick.
    var canTarget: Bool {
        self != .precision
    }
}

/// Which ink the eraser removes, so highlighting can be erased without touching the writing under it.
enum EraserTarget: String, CaseIterable, Identifiable {
    case all, highlighter, pencil
    var id: String {
        rawValue
    }

    /// Whether ink drawn with `brush` is erased. Pixel-eraser strokes are never erased: they're invisible, and
    /// removing one would bring back the ink it erased.
    func erases(_ brush: BrushDescriptor) -> Bool {
        if brush.erases {
            return false
        }
        switch self {
        case .all:
            return true
        case .highlighter:
            return brush.blend == .multiply
        case .pencil:
            return brush.usesPattern
        }
    }

    /// Whether `stroke` is erased.
    func erases(_ stroke: Stroke) -> Bool {
        erases(stroke.brush)
    }
}

struct RGBA: Hashable, Sendable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a * alpha)
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// The ink's sRGB value. Inks are fixed colours: they don't change with dark mode.
    init(_ ink: InkColor) {
        self.init(r: CGFloat(ink.red), g: CGFloat(ink.green), b: CGFloat(ink.blue))
    }

    /// Pen and pencil inks, in Pen Case order.
    static let swatches: [RGBA] = InkTheme.standardPenInks.map(RGBA.init)
}

/// One raw Pencil sample. `location` is in canvas space (independent of pan/zoom).
struct StrokePoint: Equatable, Sendable {
    var location: CGPoint
    var force: CGFloat // normalised 0...1 (force / maximumPossibleForce)
    var altitude: CGFloat // radians; π/2 = perpendicular to the screen
    var azimuth: CGFloat // radians; canvas and view share orientation, so no conversion needed
    var timestamp: TimeInterval
}

struct Stroke: Identifiable, Equatable, Sendable {
    let id: UUID
    var color: RGBA
    /// Snapshot of the brush when the stroke began (with the width and pressure settings of the time), so
    /// later changes to the brush or the sliders don't restyle old ink.
    var brush: BrushDescriptor
    var points: [StrokePoint]
    /// Wall-clock time the stroke was begun, so ink can later be replayed against an audio recording.
    /// (`StrokePoint.timestamp` is touch uptime, which doesn't survive a relaunch.) Pieces a pixel eraser
    /// cuts a stroke into keep the original's.
    var createdAt = Date()
}
