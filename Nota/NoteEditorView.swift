import InkKit
import SwiftUI

/// A note opened for writing: the InkKit canvas under a navigation bar with an editable title.
struct NoteEditorView: View {
    @Bindable var note: Note
    @Environment(InkStore.self) private var inkStore
    @State private var inkOnOpen: [Int] = []

    var body: some View {
        let notebook = inkStore.notebook(for: note.id, pageCount: note.pageCount)
        InkCanvasEditor(notebook: notebook)
            .navigationTitle($note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { inkOnOpen = notebook.pages.map(\.strokeCount) }
            .onReceive(notebook.$pages) { pages in
                if note.pageCount != pages.count {
                    note.pageCount = pages.count
                    note.modifiedAt = .now
                }
            }
            .onDisappear {
                if notebook.pages.map(\.strokeCount) != inkOnOpen {
                    note.modifiedAt = .now
                }
            }
    }
}
