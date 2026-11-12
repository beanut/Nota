import NotaCore
import NotaUI
import SwiftUI

// NotaCore's colour names mapped to design-system inks. NotaCore knows nothing about NotaUI.

extension NoteTint {
    /// The ink the note's colour is drawn in.
    var ink: NotaInk {
        switch self {
        case .indigo: .blue
        case .teal: .teal
        case .rust: .orange
        case .violet: .violet
        case .graphite: .black
        }
    }

    var color: Color {
        ink.color
    }
}

extension FolderColor {
    var color: Color {
        switch self {
        case .blue: NotaInk.blue.color
        case .teal: NotaInk.teal.color
        case .orange: NotaInk.orange.color
        case .purple: NotaInk.violet.color
        case .pink: NotaInk.labelRose.color
        case .green: NotaInk.labelGreen.color
        }
    }
}
