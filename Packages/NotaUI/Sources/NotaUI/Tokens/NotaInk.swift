import SwiftUI

/// A colour that ends up on the page: pen and pencil inks, highlighters and cover/folder labels.
///
/// Inks are stored with strokes, so they are fixed sRGB values that do not change with dark mode.
public struct NotaInk: Hashable, Identifiable, Sendable {
    /// The token name, e.g. `ink/blue`.
    public let name: String
    /// 24-bit `0xRRGGBB`.
    public let hex: UInt32

    public var id: String {
        name
    }

    public init(name: String, hex: UInt32) {
        self.name = name
        self.hex = hex
    }

    /// sRGB red, 0...1.
    public var red: Double {
        Double((hex >> 16) & 0xFF) / 255
    }

    /// sRGB green, 0...1.
    public var green: Double {
        Double((hex >> 8) & 0xFF) / 255
    }

    /// sRGB blue, 0...1.
    public var blue: Double {
        Double(hex & 0xFF) / 255
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// The part of the name after the slash, capitalised, for accessibility labels ("Blue").
    public var displayName: String {
        (name.split(separator: "/").last.map(String.init) ?? name).capitalized
    }
}

public extension NotaInk {
    // MARK: Pen inks (Figma `ink/*`)

    static let black = NotaInk(name: "ink/black", hex: 0x1A1A1F)
    static let blue = NotaInk(name: "ink/blue", hex: 0x3345D9)
    static let teal = NotaInk(name: "ink/teal", hex: 0x12786B)
    static let orange = NotaInk(name: "ink/orange", hex: 0xC04C1A)
    static let violet = NotaInk(name: "ink/violet", hex: 0x7C3AED)

    /// The colour presets in the Pen Case for the pen and pencil.
    static let penPresets: [NotaInk] = [.black, .blue, .teal, .orange, .violet]

    // MARK: Highlighters (`highlight/*`, Nota addition)

    // Drawn at 38% opacity with multiply blending, so they need to be light and saturated: the pen inks
    // turn muddy as highlighters.
    static let highlightYellow = NotaInk(name: "highlight/yellow", hex: 0xF7C600)
    static let highlightGreen = NotaInk(name: "highlight/green", hex: 0x5ED17A)
    static let highlightBlue = NotaInk(name: "highlight/blue", hex: 0x5CA8FF)
    static let highlightPink = NotaInk(name: "highlight/pink", hex: 0xFF6FAE)
    static let highlightOrange = NotaInk(name: "highlight/orange", hex: 0xFF9A3D)

    /// The colour presets in the Pen Case for the highlighter.
    static let highlighterPresets: [NotaInk] = [
        .highlightYellow, .highlightGreen, .highlightBlue, .highlightPink, .highlightOrange
    ]

    // MARK: Tape (`tape/*`, Nota addition)

    // Tape covers what's under it, so these are drawn opaque: soft, papery colours that read as tape over
    // ink and paper alike, with ink still legible on them.
    static let tapeSand = NotaInk(name: "tape/sand", hex: 0xE8D7A9)
    static let tapeSage = NotaInk(name: "tape/sage", hex: 0xB9D3B2)
    static let tapeSky = NotaInk(name: "tape/sky", hex: 0xA9C8EA)
    static let tapeBlush = NotaInk(name: "tape/blush", hex: 0xF0BCC8)
    static let tapeSlate = NotaInk(name: "tape/slate", hex: 0x9EA3B2)

    /// The colour presets in the Pen Case for the tape tool.
    static let tapePresets: [NotaInk] = [.tapeSand, .tapeSage, .tapeSky, .tapeBlush, .tapeSlate]

    // MARK: Laser (`laser/*`, Nota addition)

    /// The laser pointer's glow, on the canvas and an external display. Magenta, so it's never mistaken for
    /// the red that only means recording (`signalRecord`), and fixed like the inks, since it's drawn on paper.
    static let laser = NotaInk(name: "laser/magenta", hex: 0xF0308A)

    // MARK: Labels (`label/*`, Nota addition for folders)

    static let labelRose = NotaInk(name: "label/rose", hex: 0xC2255C)
    static let labelGreen = NotaInk(name: "label/green", hex: 0x2B8A3E)
}
