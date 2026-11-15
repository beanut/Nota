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
    /// Where links between notes have led in this window, for Back.
    @State private var linkTrail = LinkTrail()

    var body: some View {
        NavigationStack {
            if let noteID, let note = modelContext.note(withID: noteID) {
                // A fresh editor for each note, so following a link closes the one it left.
                NoteEditorView(note: note, trail: $linkTrail) { other in
                    self.noteID = other
                }
                .id(note.id)
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
