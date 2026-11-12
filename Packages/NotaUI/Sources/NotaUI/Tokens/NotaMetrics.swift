import SwiftUI

/// Type tokens. The Figma styles (`Nota/*`) use Inter at exactly the iOS Dynamic Type sizes, so the app
/// uses SF Pro text styles at the same size and weight: they scale with the reader's text size.
public enum NotaFont {
    /// 34 bold. Library title.
    public static let largeTitle = Font.largeTitle.weight(.bold)
    /// 20 semibold. Empty states, panel titles.
    public static let title3 = Font.title3.weight(.semibold)
    /// 17 semibold. Popover and section headers.
    public static let headline = Font.headline
    /// 16 regular. Sidebar rows.
    public static let callout = Font.callout
    /// 16 semibold. Selected sidebar row, large buttons.
    public static let calloutEmph = Font.callout.weight(.semibold)
    /// 15 regular. Body copy in controls, chips, slider labels.
    public static let subheadline = Font.subheadline
    /// 15 semibold. Card titles, selected chips, compact buttons, page bar.
    public static let subheadlineEmph = Font.subheadline.weight(.semibold)
    /// 13 regular. Card detail line.
    public static let footnote = Font.footnote
    /// 13 semibold. Paper-size pill, zoom level.
    public static let footnoteEmph = Font.footnote.weight(.semibold)
    /// 12 medium. Tags.
    public static let captionEmph = Font.caption.weight(.medium)
}

/// Spacing scale, in points.
public enum NotaSpacing {
    public static let xxxs: CGFloat = 2
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 6
    public static let s: CGFloat = 8
    public static let sm: CGFloat = 10
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32
}

/// Corner radii, in points. Use continuous corners.
public enum NotaRadius {
    /// Paper and page thumbnails.
    public static let paper: CGFloat = 4
    /// Icon buttons, sidebar rows, search field.
    public static let control: CGFloat = 10
    /// A group of controls sitting in a bar (the docked Pen Case).
    public static let group: CGFloat = 12
    /// Popovers, filter chips.
    public static let panel: CGFloat = 16
    /// Floating bars (Pen Case, Page Bar). Half their 44 pt height, so they read as capsules.
    public static let bar: CGFloat = 22
}

/// Hit-target and glyph sizes.
public enum NotaSize {
    /// Icon glyph, on a 20 pt grid with a 1.75 pt stroke.
    public static let icon: CGFloat = 20
    /// Icon button: 40 × 36.
    public static let iconButton = CGSize(width: 40, height: 36)
    /// Ink swatch target.
    public static let swatch: CGFloat = 28
    /// Floating bar thickness (36 pt buttons + 4 pt padding each side).
    public static let bar: CGFloat = 44
}

/// Elevation levels. Shadows use `NotaColor.shadow`, never pure black.
public enum NotaElevation {
    /// The selected tool tile lifted out of the Pen Case.
    case tile
    /// Floating bars over the canvas.
    case floating
    /// Popovers and menus.
    case popover
    /// Paper on the desk and note thumbnails.
    case paper
}

public extension View {
    /// Applies one of Nota's shadow stacks.
    func notaElevation(_ level: NotaElevation) -> some View {
        modifier(ElevationModifier(level: level))
    }
}

private struct ElevationModifier: ViewModifier {
    let level: NotaElevation

    func body(content: Content) -> some View {
        // Figma blur values are CSS blur (≈ 2σ); SwiftUI's radius is σ.
        switch level {
        case .tile:
            content.shadow(color: .black.opacity(0.08), radius: 0.75, y: 1)
        case .floating:
            content
                .shadow(color: NotaColor.shadow.opacity(0.10), radius: 6, y: 8)
                .shadow(color: NotaColor.shadow.opacity(0.08), radius: 0.5, y: 1)
        case .popover:
            content
                .shadow(color: NotaColor.shadow.opacity(0.10), radius: 12, y: 8)
                .shadow(color: NotaColor.shadow.opacity(0.08), radius: 1, y: 1)
        case .paper:
            content
                .shadow(color: NotaColor.shadow.opacity(0.07), radius: 8, y: 6)
                .shadow(color: NotaColor.shadow.opacity(0.06), radius: 1, y: 1)
        }
    }
}
