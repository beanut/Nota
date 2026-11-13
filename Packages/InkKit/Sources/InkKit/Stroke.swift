import CoreGraphics
import Foundation

/// Tools the user can pick in the toolbar.
enum Tool: String, CaseIterable, Identifiable {
    case pen, pencil, highlighter, eraser, lasso
    var id: String {
        rawValue
    }
}

enum EraserMode: String, CaseIterable, Identifiable {
    case stroke, pixel
    var id: String {
        rawValue
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
