import SwiftUI
import UIKit

/// A colour that ends up on the page: one of the Pen Case's ink presets.
///
/// Inks are stored with strokes, so they are fixed sRGB values that do not change with dark mode.
public struct InkColor: Hashable, Sendable {
    /// Shown as the swatch's accessibility label, e.g. "Blue".
    public var name: String
    /// sRGB components, 0...1.
    public var red: Double, green: Double, blue: Double

    public init(name: String, red: Double, green: Double, blue: Double) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// An ink from a 24-bit `0xRRGGBB` value.
    public init(name: String, hex: UInt32) {
        self.init(name: name,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// The ink as a fixed sRGB `UIColor`, for drawing.
    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}

/// The glyphs InkKit's chrome uses. A theme maps each one to an image; the default is SF Symbols.
public enum InkIcon: String, CaseIterable, Sendable {
    case pen, pencil, highlighter, eraser, lasso, shapes, text
    case undo, redo, more
    case previousPage, nextPage, addPage, disclosure, delete
    /// The page bar's button for the page sidebar.
    case pages
    /// The zoom window's "start a new line" and "close" buttons.
    case newLine, close
    /// The Pen Case's pen tray (saved pens) and the colour picker's eyedropper.
    case penTray, eyedropper
    /// The Pen Case's Insert menu: photos, the camera, files, pasted pictures and stickers.
    case photo
    /// The tape and laser pointer tools, and the Pen Case's ruler toggle.
    case tape, laser, ruler
}

/// How InkKit's editor looks: the colours, fonts and icons of its chrome, the paper and desk the page sits
/// on, and the ink presets in the Pen Case.
///
/// InkKit depends on no design system. A host app supplies its own by setting a theme on the editor;
/// without one the editor uses `InkTheme.standard`, built from system colours and SF Symbols.
///
/// ```swift
/// InkCanvasEditor(notebook: notebook)
///     .inkTheme(myTheme)
/// ```
public struct InkTheme {
    // MARK: Chrome colours

    /// Labels and glyphs.
    public var textPrimary: UIColor
    /// Secondary labels, units, footnotes.
    public var textSecondary: UIColor
    /// Disabled glyphs and the dividers between groups in a bar.
    public var textTertiary: UIColor
    /// The glyph of the selected tool.
    public var textSelected: UIColor
    /// Sliders, the lasso selection and other things the user is acting on.
    public var accent: UIColor
    /// Popovers, the page bar and the selected tool's tile.
    public var surfaceRaised: UIColor
    /// Neutral control fill: the quick palette, the paper-size pill, unselected width presets.
    public var surfaceFill: UIColor
    /// The selected width preset.
    public var surfaceSelected: UIColor
    /// Hairline around floating bars.
    public var border: UIColor
    /// Rules inside controls, such as the pressure curve's frame.
    public var separator: UIColor
    /// Every shadow.
    public var shadow: UIColor
    /// Hairline around ink swatches, so dark inks stay visible on dark chrome.
    public var swatchOutline: UIColor

    // MARK: Page

    /// White paper. Ink is drawn on it, so it should stay the same in light and dark mode.
    public var paper: UIColor
    /// The surface around the page.
    public var desk: UIColor
    /// The colours of each paper a template can be on. A missing entry falls back to
    /// `PaperPalette.standard`, with `paper` as white paper's surface.
    public var paperPalettes: [PaperColor: PaperPalette]

    // MARK: Type

    /// Popover titles.
    public var headlineFont: Font
    /// Control labels.
    public var bodyFont: Font
    /// The page number.
    public var bodyEmphasizedFont: Font
    /// Hints under controls.
    public var footnoteFont: Font
    /// The paper-size pill.
    public var footnoteEmphasizedFont: Font

    // MARK: Icons and inks

    /// The image for each glyph. It's drawn resizable and template-rendered at 20 pt (12 pt for
    /// `.disclosure`), so it takes the chrome's foreground colour.
    public var icon: (InkIcon) -> Image
    /// Pen and pencil inks, in Pen Case order. Must not be empty.
    public var penInks: [InkColor]
    /// Highlighter inks, drawn at partial opacity with multiply blending, so they should be light and
    /// saturated. Must not be empty.
    public var highlighterInks: [InkColor]
    /// Tape colours, in Pen Case order. Tape is drawn opaque over the page, so they should be soft enough
    /// for ink to stay legible on them. Must not be empty.
    public var tapeInks: [InkColor]
    /// The laser pointer's glow, on the page and on an external display. Fixed, like the inks.
    public var laser: InkColor

    public init(textPrimary: UIColor, textSecondary: UIColor, textTertiary: UIColor, textSelected: UIColor,
                accent: UIColor, surfaceRaised: UIColor, surfaceFill: UIColor, surfaceSelected: UIColor,
                border: UIColor, separator: UIColor, shadow: UIColor, swatchOutline: UIColor,
                paper: UIColor, desk: UIColor, paperPalettes: [PaperColor: PaperPalette] = [:],
                headlineFont: Font = .headline, bodyFont: Font = .subheadline,
                bodyEmphasizedFont: Font = .subheadline.weight(.semibold),
                footnoteFont: Font = .footnote, footnoteEmphasizedFont: Font = .footnote.weight(.semibold),
                icon: @escaping (InkIcon) -> Image = InkTheme.systemIcon,
                penInks: [InkColor] = InkTheme.standardPenInks,
                highlighterInks: [InkColor] = InkTheme.standardHighlighterInks,
                tapeInks: [InkColor] = InkTheme.standardTapeInks,
                laser: InkColor = InkTheme.standardLaser) {
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.textSelected = textSelected
        self.accent = accent
        self.surfaceRaised = surfaceRaised
        self.surfaceFill = surfaceFill
        self.surfaceSelected = surfaceSelected
        self.border = border
        self.separator = separator
        self.shadow = shadow
        self.swatchOutline = swatchOutline
        self.paper = paper
        self.desk = desk
        self.paperPalettes = paperPalettes
        self.headlineFont = headlineFont
        self.bodyFont = bodyFont
        self.bodyEmphasizedFont = bodyEmphasizedFont
        self.footnoteFont = footnoteFont
        self.footnoteEmphasizedFont = footnoteEmphasizedFont
        self.icon = icon
        self.penInks = penInks
        self.highlighterInks = highlighterInks
        self.tapeInks = tapeInks
        self.laser = laser
    }

    /// The colours `paper` is drawn in.
    public func palette(for paper: PaperColor) -> PaperPalette {
        paperPalettes[paper] ?? .standard(paper, white: self.paper.resolvedColor(with: Self.onPaper).cgColor)
    }

    /// Paper is the same in both appearances; resolve dynamic colours as light.
    static let onPaper = UITraitCollection(userInterfaceStyle: .light)

    /// The inks for `tool`: highlighters and tape get their own sets, everything else the pen inks.
    func inks(for tool: Tool) -> [InkColor] {
        switch tool {
        case .highlighter: highlighterInks.isEmpty ? Self.standardHighlighterInks : highlighterInks
        case .tape: tapeInks.isEmpty ? Self.standardTapeInks : tapeInks
        default: penInks.isEmpty ? Self.standardPenInks : penInks
        }
    }
}

// MARK: - Standard theme

public extension InkTheme {
    /// System colours and SF Symbols, on white paper.
    static let standard = InkTheme(
        textPrimary: .label,
        textSecondary: .secondaryLabel,
        textTertiary: .tertiaryLabel,
        textSelected: .tintColor,
        accent: .tintColor,
        surfaceRaised: .secondarySystemGroupedBackground,
        surfaceFill: .tertiarySystemFill,
        surfaceSelected: .tintColor.withAlphaComponent(0.15),
        border: .separator,
        separator: .separator,
        shadow: .black,
        swatchOutline: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.32) : UIColor(white: 0, alpha: 0.06) },
        paper: .white,
        desk: .systemGray5
    )

    /// SF Symbols for each glyph.
    static func systemIcon(_ icon: InkIcon) -> Image {
        let name = switch icon {
        case .pen, .pencil, .highlighter, .eraser, .lasso, .shapes, .text, .photo, .tape, .laser, .ruler: toolSymbol(icon)
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .more: "ellipsis"
        case .previousPage: "chevron.left"
        case .nextPage: "chevron.right"
        case .addPage: "plus"
        case .disclosure: "chevron.down"
        case .delete: "trash"
        case .pages: "rectangle.grid.1x2"
        case .newLine: "return.left"
        case .close: "xmark"
        case .penTray: "tray.full"
        case .eyedropper: "eyedropper"
        }
        return Image(systemName: name)
    }

    /// The Pen Case's tools and its Insert menu.
    private static func toolSymbol(_ icon: InkIcon) -> String {
        switch icon {
        case .pen: "pencil.tip"
        case .shapes: "square.on.circle"
        case .text: "character.textbox"
        case .tape: "bandage"
        case .laser: "laser.burst"
        default: icon.rawValue // pencil, highlighter, eraser, lasso, photo, ruler: named as the symbols are
        }
    }

    static let standardPenInks: [InkColor] = [
        InkColor(name: "Black", hex: 0x1C1C1E),
        InkColor(name: "Blue", hex: 0x0A5BD6),
        InkColor(name: "Red", hex: 0xD12B2B),
        InkColor(name: "Green", hex: 0x1E8A4C),
        InkColor(name: "Purple", hex: 0x7B3FD0)
    ]

    static let standardTapeInks: [InkColor] = [
        InkColor(name: "Sand", hex: 0xE8D7A9),
        InkColor(name: "Sage", hex: 0xB9D3B2),
        InkColor(name: "Sky", hex: 0xA9C8EA),
        InkColor(name: "Blush", hex: 0xF0BCC8),
        InkColor(name: "Slate", hex: 0x9EA3B2)
    ]

    static let standardLaser = InkColor(name: "Laser", hex: 0xF0308A)

    static let standardHighlighterInks: [InkColor] = [
        InkColor(name: "Yellow", hex: 0xFFD60A),
        InkColor(name: "Green", hex: 0x5ED17A),
        InkColor(name: "Blue", hex: 0x64B5FF),
        InkColor(name: "Pink", hex: 0xFF6FAE),
        InkColor(name: "Orange", hex: 0xFF9F40)
    ]
}

// MARK: - Environment

private struct InkThemeKey: EnvironmentKey {
    static let defaultValue = InkTheme.standard
}

public extension EnvironmentValues {
    /// The theme InkKit's editor draws its chrome, page and Pen Case with.
    var inkTheme: InkTheme {
        get { self[InkThemeKey.self] }
        set { self[InkThemeKey.self] = newValue }
    }
}

public extension View {
    /// Sets the theme of the InkKit editors inside this view.
    func inkTheme(_ theme: InkTheme) -> some View {
        environment(\.inkTheme, theme)
    }
}
