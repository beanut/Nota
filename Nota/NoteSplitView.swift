import NotaCore
import NotaUI
import SwiftData
import SwiftUI

/// Two notes side by side in one window, each with its own tool picker. Closing one leaves the other open.
struct NoteSplitView: View {
    let notes: [Note]
    @Binding var workspace: NoteWorkspace
    @Binding var trail: LinkTrail

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 {
                    NotaColor.borderSeparator
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                // Each side has its own editor chrome; its Close button closes just that side.
                NavigationStack {
                    NoteEditorView(note: note, workspace: $workspace, trail: $trail, leading: .close,
                                   leadingAction: { withAnimation { workspace.close(note.id) } },
                                   openNote: { other in withAnimation { workspace.replace(note.id, with: other) } })
                        .id(note.id)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(NotaColor.bgApp)
    }
}
