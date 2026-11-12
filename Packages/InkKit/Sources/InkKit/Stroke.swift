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

/// How a stored stroke composites onto the page.
enum InkKind: Equatable {
    case pen // normal source-over
    case pencil // textured graphite source-over
    case highlighter // multiply, so ink underneath stays readable
    case pixelEraser // destination-out, removes pixels of strokes drawn before it
}

struct RGBA: Equatable, Hashable {
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
struct StrokePoint {
    var location: CGPoint
    var force: CGFloat // normalised 0...1 (force / maximumPossibleForce)
    var altitude: CGFloat // radians; π/2 = perpendicular to the screen
    var azimuth: CGFloat // radians; canvas and view share orientation, so no conversion needed
    var timestamp: TimeInterval
}

/// Snapshot of the brush settings when the stroke began, so later slider changes don't restyle old ink.
struct BrushStyle: Equatable {
    var width: CGFloat // width at full pressure, canvas units
    var minWidthRatio: CGFloat // width at zero pressure = width * minWidthRatio
    var pressureGamma: CGFloat // response curve: pressure' = pressure ^ gamma
    var opacity: CGFloat
    var tiltEnabled: Bool
}

struct Stroke: Identifiable {
    let id: UUID
    var tool: InkKind
    var color: RGBA
    var style: BrushStyle
    var points: [StrokePoint]
}
