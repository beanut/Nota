import InkKit
import NotaUI
import SwiftUI

/// A note opened for writing: the InkKit canvas under a navigation bar. The title is shown and renamed
/// from the Pen Case's More menu rather than in the bar.
struct NoteEditorView: View {
    @Bindable var note: Note
    @Environment(InkStore.self) private var inkStore
    @State private var inkOnOpen: [Int] = []

    var body: some View {
        let notebook = inkStore.notebook(for: note.id, pageCount: note.pageCount)
        InkCanvasEditor(notebook: notebook, title: $note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(NotaColor.bgApp, for: .navigationBar)
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
