import SwiftUI

/// What the focused window can do with its open notes, for the keyboard shortcuts in `NoteCommands`.
struct NoteSceneActions {
    var openInNewWindow: (() -> Void)?
    var closeNote: (() -> Void)?
    var swapSides: (() -> Void)?
}

private struct NoteSceneActionsKey: FocusedValueKey {
    typealias Value = NoteSceneActions
}

extension FocusedValues {
    var noteSceneActions: NoteSceneActions? {
        get { self[NoteSceneActionsKey.self] }
        set { self[NoteSceneActionsKey.self] = newValue }
    }
}

/// Keyboard shortcuts for windows and split notes, listed when ⌘ is held.
struct NoteCommands: Commands {
    @FocusedValue(\.noteSceneActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Note in New Window") { actions?.openInNewWindow?() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(actions?.openInNewWindow == nil)
            Button("Swap Notes") { actions?.swapSides?() }
                .keyboardShortcut("\\", modifiers: [.command, .option])
                .disabled(actions?.swapSides == nil)
            Button("Close Note") { actions?.closeNote?() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(actions?.closeNote == nil)
        }
    }
}
