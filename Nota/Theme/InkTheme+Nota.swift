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
        // NotaUI has no checkmark line icon; the title menu's check uses the system one.
        icon: { $0 == .check ? InkTheme.systemIcon($0) : Image(nota: NotaIcon(inkIcon: $0)) },
        penInks: NotaInk.pickerPresets.map(InkColor.init),
        highlighterInks: NotaInk.highlighterPresets.map(InkColor.init),
        tapeInks: NotaInk.tapePresets.map(InkColor.init),
        laser: InkColor(NotaInk.laser),
        link: InkColor(NotaInk.blue),
        glassTint: NotaUIColor.materialGlassTint,
        blurTint: NotaUIColor.materialBlurTint,
        blurBorder: NotaUIColor.materialBlurBorder,
        selectionPill: NotaUIColor.materialSelectionPill,
        addTint: NotaUIColor.signalAdd,
        toolArt: { tool in NotaToolIllustration(tool).map { AnyView(NotaToolIllustrationView($0)) } }
    )
}

private extension NotaIcon {
    init(inkIcon: InkIcon) {
        self = switch inkIcon {
        case .pen, .pencil, .highlighter, .eraser, .lasso, .shapes, .text, .photo, .tape, .laser, .ruler:
            NotaIcon(tool: inkIcon)
        case .undo: .undo
        case .redo: .redo
        case .more: .ellipsis
        case .previousPage: .chevronLeft
        case .nextPage: .chevronRight
        case .addPage: .plus
        case .disclosure: .chevronDown
        case .delete: .trash
        case .pages: .pages
        case .newLine: .newLine
        case .close: .xmark
        case .penTray: .pens
        case .eyedropper: .eyedropper
        case .link: .link
        case .bookmark: .bookmark
        case .outline: .list
        case .back: .chevronLeft
        case .search, .ai, .share, .check: NotaIcon(navigation: inkIcon)
        }
    }

    /// The editor's trailing actions.
    init(navigation icon: InkIcon) {
        self = switch icon {
        case .search: .search
        case .ai: .wand
        case .share: .share
        default: .plus // `.check` is drawn from SF Symbols instead (see `nota`)
        }
    }

    /// The Pen Case's tools and its Insert menu.
    init(tool: InkIcon) {
        self = switch tool {
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .eraser: .eraser
        case .lasso: .lasso
        case .shapes: .shapes
        case .text: .text
        case .photo: .photo
        case .tape: .tape
        case .laser: .laser
        case .ruler: .ruler
        default: .pen
        }
    }
}

private extension NotaToolIllustration {
    /// The illustration for a tool in the picker; nil for tape, the laser and Insert, which use their glyphs.
    init?(_ tool: PickerTool) {
        switch tool {
        case .pen: self = .pen
        case .marker: self = .marker
        case .fountainPen: self = .fountainPen
        case .pencil: self = .pencil
        case .crayon: self = .crayon
        case .highlighter: self = .highlighter
        case .eraser: self = .eraser
        case .lasso: self = .lasso
        case .ruler: self = .ruler
        case .shapes: self = .shapes
        case .textBox: self = .textBox
        case .tape, .laser, .insert: return nil
        }
    }
}

private extension InkColor {
    init(_ ink: NotaInk) {
        self.init(name: ink.displayName, hex: ink.hex)
    }
}
