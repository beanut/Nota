import CoreGraphics
import Foundation

// MARK: - Bundled brushes

/// The built-in brush set (NOT-17): the pens, pencils and highlighters a handwritten-notes app is expected
/// to have, each a plain `BrushDescriptor`. Each brush's `size.upperBound` is its default width, and its
/// own minimum-width ratio, pressure curve, tip, taper and texture are its character; the Pressure & Tilt
/// settings adjust that character rather than replace it (see `personalized`).
///
/// Ids are fixed (`6E6F7461` is "nota"), so a stroke's brush can be recognised as built in. Don't change a
/// shipped brush's id; strokes already on the page keep the snapshot they were drawn with either way.
public extension BrushDescriptor {
    // MARK: Pens

    /// Ballpoint: a round nib, pressure to width, tilt shading. The original pen, and every fallback.
    static let pen = BrushDescriptor(id: builtInID(1), name: "Ballpoint", size: 1 ... 4)

    /// Fineliner: an even line that barely responds to pressure, no tilt shading.
    static let fineliner = BrushDescriptor(id: builtInID(5), name: "Fineliner", size: 2.4 ... 3,
                                           pressure: ResponseCurve(amount: 1, exponent: 1), tilt: .off)

    /// Fountain pen: a stub nib held at a fixed angle, so downstrokes are broad and up-right hairlines
    /// thin. Pressure opens the tines a little, the ends taper softly and ink pools where it lingers.
    static let fountainPen = BrushDescriptor(id: builtInID(6), name: "Fountain Pen",
                                             tip: .ellipse(aspect: 0.32, angle: -0.6), size: 2 ... 5,
                                             pressure: ResponseCurve(amount: 1, exponent: 0.8), tilt: .off,
                                             taper: Taper(startLength: 5, endLength: 9, minimumScale: 0.45),
                                             wetness: 0.3)

    /// Brush pen: a soft round tip with a wide pressure range, tapered strokes, and thinner when fast.
    static let brushPen = BrushDescriptor(id: builtInID(7), name: "Brush Pen", size: 0.6 ... 8,
                                          pressure: ResponseCurve(amount: 1, exponent: 1.3), tilt: .off,
                                          velocity: ResponseCurve(amount: 0.35),
                                          taper: Taper(startLength: 10, endLength: 22, minimumScale: 0.15),
                                          smoothing: 0.2)

    /// Chisel marker: a broad flat tip at a fixed angle, an even, nearly opaque line.
    static let marker = BrushDescriptor(id: builtInID(8), name: "Marker",
                                        tip: .ellipse(aspect: 0.35, angle: -0.9), size: 5.2 ... 6.5,
                                        pressure: ResponseCurve(amount: 1, exponent: 1), tilt: .off,
                                        opacity: 0.92)

    /// Dashed: a fineliner broken into dashes.
    static let dashedPen = BrushDescriptor(id: builtInID(9), name: "Dashed", size: 2.6 ... 3,
                                           pressure: ResponseCurve(amount: 1, exponent: 1), tilt: .off,
                                           dash: Dash(on: 3, off: 2.5))

    /// Dotted: round dots a little over two widths apart.
    static let dottedPen = BrushDescriptor(id: builtInID(10), name: "Dotted", size: 2.6 ... 3,
                                           pressure: ResponseCurve(amount: 1, exponent: 1), tilt: .off,
                                           spacing: 2.2)

    // MARK: Pencils

    /// HB pencil: the pen's nib with paper-tooth grain, slightly translucent, shading when tilted.
    static let pencil = BrushDescriptor(id: builtInID(2), name: "HB Pencil", size: 0.75 ... 3,
                                        texture: .grain(scale: 1, contrast: 1, seed: 42), opacity: 0.85)

    /// Soft (6B) pencil: broader and darker under pressure, a coarser grain, and a wide, light shading
    /// edge when laid on its side.
    static let softPencil = BrushDescriptor(id: builtInID(11), name: "Soft Pencil", size: 1.5 ... 5,
                                            pressure: ResponseCurve(amount: 1, exponent: 0.8),
                                            pressureOpacity: ResponseCurve(amount: 0.45, exponent: 0.7),
                                            tilt: TiltResponse(startAltitude: 65, fullAltitude: 15, length: 5,
                                                               breadth: 1.2, opacityLoss: 0.65, contactShift: 0.4),
                                            texture: .grain(scale: 1.5, contrast: 0.8, seed: 7), opacity: 0.95)

    /// Crayon: a waxy, chunky stick. A coarse, high-contrast grain lets the paper show through, it lays down
    /// more wax under pressure, and a tilted stick broadens into a wide, light stroke. The grain is a
    /// pattern fixed to the page, so it doesn't shimmer while drawing and renders the same on reopen, in
    /// thumbnails and in exports. Drawn with the same continuous path as the pencils, so it costs no more.
    static let crayon = BrushDescriptor(id: builtInID(13), name: "Crayon", size: 2.5 ... 9,
                                        pressure: ResponseCurve(amount: 1, exponent: 0.7),
                                        pressureOpacity: ResponseCurve(amount: 0.3, exponent: 0.8),
                                        tilt: TiltResponse(startAltitude: 60, fullAltitude: 20, length: 4,
                                                           breadth: 1.1, opacityLoss: 0.4, contactShift: 0.3),
                                        texture: .grain(scale: 0.9, contrast: 0.95, seed: 1013), opacity: 0.96)

    // MARK: Highlighters

    /// Round highlighter: a wide translucent nib that multiplies, so ink underneath stays readable.
    static let highlighter = BrushDescriptor(id: builtInID(3), name: "Highlighter", size: 5.5 ... 22,
                                             blend: .multiply, opacity: 0.38)

    /// Chisel highlighter: a flat, nearly upright tip, so lines of text get a crisp full-height band and
    /// vertical strokes stay thin. Constant width.
    static let chiselHighlighter = BrushDescriptor(id: builtInID(12), name: "Chisel Highlighter",
                                                   tip: .ellipse(aspect: 0.22, angle: 1.35), size: 20 ... 22,
                                                   pressure: ResponseCurve(amount: 1, exponent: 1), tilt: .off,
                                                   blend: .multiply, opacity: 0.38)

    // MARK: Eraser

    /// Erases pixels of the strokes under it. A constant-width round nib, no pressure or tilt.
    static let pixelEraser = BrushDescriptor(id: builtInID(4), name: "Pixel Eraser", size: 30 ... 30,
                                             pressure: ResponseCurve(amount: 1, exponent: 1), tilt: .off,
                                             blend: .destinationOut)

    // MARK: Sets

    /// The pens, in picker order. The first is the default.
    static let pens: [BrushDescriptor] = [.pen, .fineliner, .fountainPen, .brushPen, .marker, .dashedPen,
                                          .dottedPen]
    /// The pencils, in picker order. The first is the default.
    static let pencils: [BrushDescriptor] = [.pencil, .softPencil, .crayon]
    /// The highlighters, in picker order. The first is the default.
    static let highlighters: [BrushDescriptor] = [.highlighter, .chiselHighlighter]

    /// Every bundled brush.
    static let bundled: [BrushDescriptor] = pens + pencils + highlighters + [.pixelEraser]

    /// The bundled brush with `id`, if there is one.
    static func bundled(id: UUID) -> BrushDescriptor? {
        bundled.first { $0.id == id }
    }

    private static func builtInID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "6E6F7461-0000-4000-8000-%012X", n))!
    }
}

// MARK: - Sizing and settings

public extension BrushDescriptor {
    /// This brush with a full-pressure width of `width` and `minimumRatio` of it at no pressure.
    func sized(_ width: CGFloat, minimumRatio: CGFloat) -> BrushDescriptor {
        var b = self
        let ratio = min(max(minimumRatio.isFinite ? minimumRatio : 0, 0), 1)
        let width = width.isFinite ? min(max(width, 0.05), 1000) : BrushDescriptor.pen.maxWidth
        b.size = width * ratio ... width
        return b
    }

    /// The width at full pressure.
    var maxWidth: CGFloat {
        size.upperBound
    }

    /// The ratio of minimum to full-pressure width the Pressure & Tilt settings treat as neutral (the
    /// ballpoint's, and the setting's default).
    static let neutralMinimumWidthRatio: CGFloat = 0.25
    /// The pressure exponent the Pressure & Tilt settings treat as neutral (the ballpoint's, and the
    /// setting's default).
    static let neutralPressureExponent: CGFloat = 0.6

    /// This brush at `width`, with the Pressure & Tilt settings applied on top of its own character:
    ///
    /// - **Minimum width** moves the brush's own minimum-width ratio the way the setting moves from
    ///   `neutralMinimumWidthRatio`: at the neutral value the brush is unchanged, at 1 every brush is
    ///   constant width, and lower values widen its range proportionally.
    /// - **Response curve** scales the brush's pressure exponent by `pressureExponent / neutral`.
    /// - **Tilt** off turns tilt shading off; on leaves it as the brush has it (some brushes have none).
    ///
    /// So a ballpoint gets exactly the settings' values, and the other brushes keep their distinct feel.
    func personalized(width: CGFloat, minimumWidthRatio: CGFloat, pressureExponent: CGFloat,
                      tilt: Bool) -> BrushDescriptor {
        let upper = size.upperBound
        let ownRatio = upper > 0 ? size.lowerBound / upper : 1
        let setting = min(max(minimumWidthRatio.isFinite ? minimumWidthRatio : Self.neutralMinimumWidthRatio,
                              0), 1)
        let neutral = Self.neutralMinimumWidthRatio
        // Written so the neutral brush maps exactly to the setting (no rounding).
        let ratio = setting + (ownRatio - neutral) * (1 - setting) / (1 - neutral)
        var b = sized(width, minimumRatio: ratio)
        if pressure.isActive, pressureExponent.isFinite, pressureExponent > 0 {
            b.pressure.exponent = min(max(pressureExponent * (pressure.exponent / Self.neutralPressureExponent),
                                          0.1), 5)
        }
        if !tilt {
            b.tilt.enabled = false
        }
        return b
    }
}
