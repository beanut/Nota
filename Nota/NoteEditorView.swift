import InkKit
import SwiftUI

/// A note opened for writing: the InkKit canvas under a navigation bar with an editable title.
struct NoteEditorView: View {
    @Bindable var note: Note
    @Environment(InkStore.self) private var inkStore
    @State private var strokeCountOnOpen = 0

    var body: some View {
        let document = inkStore.document(for: note.id)
        InkCanvasEditor(document: document)
            .navigationTitle($note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { strokeCountOnOpen = document.strokeCount }
            .onDisappear {
                if document.strokeCount != strokeCountOnOpen { note.modifiedAt = .now }
            }
    }
}
