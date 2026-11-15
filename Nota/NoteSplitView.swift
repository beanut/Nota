import NotaCore
import NotaUI
import SwiftData
import SwiftUI

/// Two notes side by side in one window, each with its own Pen Case. Closing one leaves the other open.
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
                // Each side gets its own navigation bar for its Pen Case.
                NavigationStack {
                    NoteEditorView(note: note, workspace: $workspace, trail: $trail) { other in
                        withAnimation { workspace.replace(note.id, with: other) }
                    }
                    .id(note.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation { workspace.close(note.id) }
                            } label: {
                                NotaIconView(.xmark)
                            }
                            .buttonStyle(.notaIcon(selected: false))
                            .accessibilityLabel("Close \(note.title)")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(NotaColor.bgApp)
    }
}
