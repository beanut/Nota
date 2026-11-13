import SwiftUI
import UIKit

/// Colour tokens. Names follow the Figma variables (`text/primary` → `textPrimary`). Every token has a
/// light and a dark value; the Figma file defines light only, dark values are Nota's own (see DESIGN.md).
///
/// Paper and ink stay the same in dark mode: the page is a physical sheet, and ink written on it must look
/// the same whichever mode it was written in.
public enum NotaColor {
    // MARK: Backgrounds

    /// The library and editor window behind everything else.
    public static let bgApp = Color(uiColor: NotaUIColor.bgApp)
    /// Cards, popovers, the selected tool tile and floating bars that sit above `bgApp`.
    public static let bgRaised = Color(uiColor: NotaUIColor.bgRaised)
    /// Neutral control fill: the Pen Case, filter chips, secondary buttons, search.
    public static let bgFill = Color(uiColor: NotaUIColor.bgFill)
    /// The surface around the page in the editor.
    public static let bgDesk = Color(uiColor: NotaUIColor.bgDesk)
    /// Selected rows and chips. Ink means "you chose this".
    public static let bgInkTint = Color(uiColor: NotaUIColor.bgInkTint)
    /// Behind AI suggestions. Only where Nota acts for you.
    public static let bgAITint = Color(uiColor: NotaUIColor.bgAITint)

    // MARK: Borders

    public static let borderSeparator = Color(uiColor: NotaUIColor.borderSeparator)
    public static let borderCard = Color(uiColor: NotaUIColor.borderCard)

    // MARK: Text and glyphs

    public static let textPrimary = Color(uiColor: NotaUIColor.textPrimary)
    public static let textSecondary = Color(uiColor: NotaUIColor.textSecondary)
    /// Placeholders, disabled glyphs and toolbar dividers.
    public static let textTertiary = Color(uiColor: NotaUIColor.textTertiary)
    /// Selected labels and glyphs.
    public static let textInk = Color(uiColor: NotaUIColor.textInk)
    public static let textAI = Color(uiColor: NotaUIColor.textAI)
    public static let textOnAccent = Color(uiColor: NotaUIColor.textOnAccent)

    // MARK: Accents

    /// Your actions and selections: primary buttons, sliders, playback.
    public static let accentInk = Color(uiColor: NotaUIColor.accentInk)
    /// Only when Nota acts for you: Ask Nota, Generate, dictation.
    public static let accentAI = Color(uiColor: NotaUIColor.accentAI)
    /// Only while the mic records raw audio. Always paired with a label.
    public static let signalRecord = Color(uiColor: NotaUIColor.signalRecord)

    // MARK: Paper

    public static let paperSurface = Color(uiColor: NotaUIColor.paperSurface)
    public static let paperRule = Color(uiColor: NotaUIColor.paperRule)
    public static let paperMargin = Color(uiColor: NotaUIColor.paperMargin)
    public static let paperLabel = Color(uiColor: NotaUIColor.paperLabel)
    public static let paperCreamSurface = Color(uiColor: NotaUIColor.paperCreamSurface)
    public static let paperCreamRule = Color(uiColor: NotaUIColor.paperCreamRule)
    public static let paperDarkSurface = Color(uiColor: NotaUIColor.paperDarkSurface)
    public static let paperDarkRule = Color(uiColor: NotaUIColor.paperDarkRule)
    public static let paperDarkMargin = Color(uiColor: NotaUIColor.paperDarkMargin)
    public static let paperDarkLabel = Color(uiColor: NotaUIColor.paperDarkLabel)

    /// Shadow colour for every elevation (a cool near-black, never pure black).
    public static let shadow = Color(uiColor: NotaUIColor.shadow)
    /// Hairline around ink swatches, so dark inks stay visible on dark chrome.
    public static let inkOutline = Color(uiColor: NotaUIColor.inkOutline)
}

/// The same tokens as `UIColor`, for UIKit and Core Graphics drawing (the canvas, its desk and selection).
public enum NotaUIColor {
    public static let bgApp = UIColor(light: 0xF7F7F9, dark: 0x111114)
    public static let bgRaised = UIColor(light: 0xFFFFFF, dark: 0x1F1F24)
    public static let bgFill = UIColor(light: 0xEBEBF0, dark: 0x2A2A31)
    public static let bgDesk = UIColor(light: 0xE3E3E9, dark: 0x18181C)
    public static let bgInkTint = UIColor(light: 0xE8EBFC, dark: 0x252B57)
    public static let bgAITint = UIColor(light: 0xF0EAFE, dark: 0x2F2352)

    public static let borderSeparator = UIColor(light: 0xE1E1E7, dark: 0x34343C)
    public static let borderCard = UIColor(light: 0xE4E4EA, dark: 0x2E2E35)

    public static let textPrimary = UIColor(light: 0x1A1A1F, dark: 0xF2F2F5)
    public static let textSecondary = UIColor(light: 0x5E5E6A, dark: 0xA3A3AE)
    public static let textTertiary = UIColor(light: 0x8A8A95, dark: 0x72727D)
    public static let textInk = UIColor(light: 0x3345D9, dark: 0x8F9BFF)
    public static let textAI = UIColor(light: 0x7D3BED, dark: 0xB58CFF)
    public static let textOnAccent = UIColor(light: 0xFFFFFF, dark: 0xFFFFFF)

    public static let accentInk = UIColor(light: 0x3345D9, dark: 0x5B6CF0)
    public static let accentAI = UIColor(light: 0x7D3BED, dark: 0x9A63F5)
    public static let signalRecord = UIColor(light: 0xD92D30, dark: 0xFF5A5C)

    /// Paper is the same in light and dark mode; these are page content, not chrome. White and cream
    /// paper share the margin and label colours.
    public static let paperSurface = UIColor(hex: 0xFCFBF7)
    public static let paperRule = UIColor(hex: 0xE2E5EE)
    public static let paperMargin = UIColor(hex: 0xEDB4B4)
    public static let paperLabel = UIColor(hex: 0x9599A6)
    public static let paperCreamSurface = UIColor(hex: 0xF8F2E2)
    public static let paperCreamRule = UIColor(hex: 0xE3D9C1)
    public static let paperDarkSurface = UIColor(hex: 0x24262A)
    public static let paperDarkRule = UIColor(hex: 0x3C4048)
    public static let paperDarkMargin = UIColor(hex: 0x6E4C55)
    public static let paperDarkLabel = UIColor(hex: 0x7D838E)

    public static let shadow = UIColor(light: 0x1A1A33, dark: 0x000000)
    public static let inkOutline = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.32) : UIColor(white: 0, alpha: 0.06)
    }
}

public extension UIColor {
    /// An sRGB colour from a 24-bit `0xRRGGBB` value.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// A colour that follows the trait collection's light or dark appearance.
    convenience init(light: UInt32, dark: UInt32) {
        let lightColor = UIColor(hex: light), darkColor = UIColor(hex: dark)
        self.init { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
    }
}
