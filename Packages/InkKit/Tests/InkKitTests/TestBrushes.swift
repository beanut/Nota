import CoreGraphics
@testable import InkKit

/// The built-in tools, for tests that draw with each.
enum TestBrush: CaseIterable {
    case pen, pencil, highlighter, pixelEraser

    var bundled: BrushDescriptor {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .pixelEraser: .pixelEraser
        }
    }

    /// The bundled brush with the settings the canvas applies: width, minimum width ratio, pressure
    /// exponent, opacity and tilt (the pixel eraser ignores all but the width).
    func brush(width: CGFloat, minWidthRatio: CGFloat = 0.25, pressureExponent: CGFloat = 0.6,
               opacity: CGFloat? = nil, tilt: Bool = false) -> BrushDescriptor {
        if self == .pixelEraser {
            return bundled.sized(width, minimumRatio: 1)
        }
        var b = bundled.sized(width, minimumRatio: minWidthRatio)
        b.pressure.exponent = pressureExponent
        b.tilt.enabled = tilt
        if let opacity {
            b.opacity = opacity
        }
        return b
    }
}
