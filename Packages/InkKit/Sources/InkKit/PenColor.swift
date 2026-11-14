import Foundation
import SwiftUI

/// A colour a pen writes in: 24-bit sRGB, stored as `"#RRGGBB"`.
///
/// Pen colours are saved with pens, palettes and recent colours (`PenTray`), so they're exact 8-bit values:
/// equal colours compare equal however they were made (a swatch, the spectrum, a hex code, the
/// eyedropper). Opacity belongs to the brush, not the colour. Like inks, pen colours are fixed and don't
/// change with dark mode.
public struct PenColor: Hashable, Sendable, Codable, CustomStringConvertible {
    /// `0xRRGGBB`.
    public let rgb: UInt32

    /// A colour from a 24-bit `0xRRGGBB` value (higher bits are ignored).
    public init(rgb: UInt32) {
        self.rgb = rgb & 0xFFFFFF
    }

    /// A colour from sRGB components in 0…1, rounded to 8 bits each. Out-of-range or NaN components are
    /// clamped (NaN to 0).
    public init(red: Double, green: Double, blue: Double) {
        func byte(_ v: Double) -> UInt32 {
            UInt32((min(max(v.isNaN ? 0 : v, 0), 1) * 255).rounded())
        }
        self.init(rgb: byte(red) << 16 | byte(green) << 8 | byte(blue))
    }

    /// Parses `#RGB`, `#RRGGBB` (the `#` is optional, case doesn't matter, surrounding spaces are
    /// ignored). Nil for anything else.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        guard s.count == 3 || s.count == 6, s.allSatisfy(\.isHexDigit), let value = UInt32(s, radix: 16) else {
            return nil
        }
        if s.count == 3 {
            let r = (value >> 8) & 0xF, g = (value >> 4) & 0xF, b = value & 0xF
            self.init(rgb: (r * 17) << 16 | (g * 17) << 8 | b * 17)
        } else {
            self.init(rgb: value)
        }
    }

    /// The ink's colour.
    public init(_ ink: InkColor) {
        self.init(red: ink.red, green: ink.green, blue: ink.blue)
    }

    /// `"#RRGGBB"`, upper case.
    public var hex: String {
        String(format: "#%06X", rgb)
    }

    public var description: String {
        hex
    }

    public var red: Double {
        Double((rgb >> 16) & 0xFF) / 255
    }

    public var green: Double {
        Double((rgb >> 8) & 0xFF) / 255
    }

    public var blue: Double {
        Double(rgb & 0xFF) / 255
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    var rgba: RGBA {
        RGBA(r: CGFloat(red), g: CGFloat(green), b: CGFloat(blue))
    }

    // MARK: HSB

    /// A colour from hue, saturation and brightness, each 0…1 (hue wraps).
    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = hue.isFinite ? (hue - hue.rounded(.down)) * 6 : 0
        let s = min(max(saturation.isNaN ? 0 : saturation, 0), 1)
        let v = min(max(brightness.isNaN ? 0 : brightness, 0), 1)
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let rgb: [Double] = switch sector {
        case 0: [v, t, p]
        case 1: [q, v, p]
        case 2: [p, v, t]
        case 3: [p, q, v]
        case 4: [t, p, v]
        default: [v, p, q]
        }
        self.init(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    /// Hue, saturation and brightness, each 0…1.
    public struct HSB: Hashable, Sendable {
        public var hue: Double
        public var saturation: Double
        public var brightness: Double
    }

    /// Hue, saturation and brightness. A grey has hue 0.
    public var hsb: HSB {
        let r = red, g = green, b = blue
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r {
                hue = (g - b) / delta
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }
        return HSB(hue: hue, saturation: maxC > 0 ? delta / maxC : 0, brightness: maxC)
    }

    /// Relative luminance (WCAG), 0 for black … 1 for white: for choosing a legible mark over the colour.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let string = try c.decode(String.self)
        guard let color = PenColor(hex: string) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a #RRGGBB colour: \(string)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}
