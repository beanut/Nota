import NotaCore
import NotaUI
import SwiftData
import SwiftUI

/// A note in a window of its own, beside the library or another note in Split View or Stage Manager.
/// The window remembers its note (SwiftUI restores the `WindowGroup` value with the scene).
struct NoteWindow: View {
    static let sceneID = "note"

    @Binding var noteID: UUID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NavigationStack {
            if let noteID, let note = modelContext.note(withID: noteID) {
                NoteEditorView(note: note)
                    .navigationTitle(note.title)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { dismissWindow() } label: { NotaIconView(.xmark) }
                                .buttonStyle(.notaIcon(selected: false))
                                .accessibilityLabel("Close Window")
                        }
                    }
                    .focusedSceneValue(\.noteSceneActions, NoteSceneActions(closeNote: { dismissWindow() }))
            } else {
                // Until a dragged-in note arrives, or after the note was deleted permanently elsewhere.
                NotaEmptyState(.grid, title: "Note Unavailable", message: "This note was deleted or can’t be opened.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NotaColor.bgApp)
            }
        }
        // A note dragged out of the library to the edge of the screen arrives as a user activity.
        .onContinueUserActivity(NoteActivity.activityType) { activity in
            if let id = NoteActivity.noteID(in: activity) {
                noteID = id
            }
        }
    }
}
