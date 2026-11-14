import InkKit
import NotaDocuments
import NotaUI
import SwiftUI

/// Nota's design tokens applied to InkKit's editor. InkKit doesn't depend on NotaUI; the app joins them
/// here.
extension InkTheme {
    static let nota = InkTheme(
        textPrimary: NotaUIColor.textPrimary,
        textSecondary: NotaUIColor.textSecondary,
        textTertiary: NotaUIColor.textTertiary,
        textSelected: NotaUIColor.textInk,
        accent: NotaUIColor.accentInk,
        surfaceRaised: NotaUIColor.bgRaised,
        surfaceFill: NotaUIColor.bgFill,
        surfaceSelected: NotaUIColor.bgInkTint,
        border: NotaUIColor.borderCard,
        separator: NotaUIColor.borderSeparator,
        shadow: NotaUIColor.shadow,
        swatchOutline: NotaUIColor.inkOutline,
        paper: NotaUIColor.paperSurface,
        desk: NotaUIColor.bgDesk,
        paperPalettes: PaperPalette.notaPalettes,
        headlineFont: NotaFont.headline,
        bodyFont: NotaFont.subheadline,
        bodyEmphasizedFont: NotaFont.subheadlineEmph,
        footnoteFont: NotaFont.footnote,
        footnoteEmphasizedFont: NotaFont.footnoteEmph,
        icon: { Image(nota: NotaIcon(inkIcon: $0)) },
        penInks: NotaInk.penPresets.map(InkColor.init),
        highlighterInks: NotaInk.highlighterPresets.map(InkColor.init)
    )
}

private extension NotaIcon {
    init(inkIcon: InkIcon) {
        self = switch inkIcon {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .eraser: .eraser
        case .lasso: .lasso
        case .shapes: .shapes
        case .undo: .undo
        case .redo: .redo
        case .more: .ellipsis
        case .previousPage: .chevronLeft
        case .nextPage: .chevronRight
        case .addPage: .plus
        case .disclosure: .chevronDown
        case .delete: .trash
        case .pages: .grid
        case .newLine: .newLine
        case .close: .xmark
        case .penTray: .pens
        case .eyedropper: .eyedropper
        }
    }
}

private extension InkColor {
    init(_ ink: NotaInk) {
        self.init(name: ink.displayName, hex: ink.hex)
    }
}
