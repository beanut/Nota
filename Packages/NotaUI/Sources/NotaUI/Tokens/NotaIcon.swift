import SwiftUI

/// Nota's line icons (Figma `icon/*`): 20 pt grid, 1.75 pt round stroke, template-rendered so they take
/// the foreground style. Prefer these over SF Symbols in Nota's own chrome; system menus and alerts keep
/// SF Symbols.
public enum NotaIcon: String, CaseIterable, Identifiable, Sendable {
    // MARK: Library

    case grid, star, clock, trash, folder, plus, minus, search, filter, list
    case chevronLeft = "chevron.left"
    case chevronRight = "chevron.right"
    case chevronDown = "chevron.down"
    case xmark, ellipsis, share
    case arrowUp = "arrow.up"

    // MARK: Tools

    case pen, pencil, highlighter, eraser, lasso, text, shapes, photo

    // MARK: Editor

    case undo, redo, fit, grip, pressure, gauge, split

    // MARK: Audio and AI

    case sparkles, mic, waveform, play, pause, stop, flashcards, quiz, calc

    public var id: String {
        rawValue
    }

    /// The icon at its natural 20 pt size.
    public var image: Image {
        Image("icon.\(rawValue)", bundle: .module)
    }
}

public extension Image {
    /// A Nota line icon.
    init(nota icon: NotaIcon) {
        self.init("icon.\(icon.rawValue)", bundle: .module)
    }
}

/// A Nota icon drawn at `size` (20 pt by default). Strokes scale with the size.
public struct NotaIconView: View {
    let icon: NotaIcon
    let size: CGFloat

    public init(_ icon: NotaIcon, size: CGFloat = NotaSize.icon) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        icon.image
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
