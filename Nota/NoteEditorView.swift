import InkKit
import NotaUI
import SwiftUI

/// A note opened for writing: the InkKit canvas under a navigation bar. The title is shown and renamed
/// from the Pen Case's More menu rather than in the bar.
struct NoteEditorView: View {
    @Bindable var note: Note
    @Environment(InkStore.self) private var inkStore
    @Environment(ThumbnailStore.self) private var thumbnails
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
                // The first page is the cover; skipped if it hasn't changed since its last render.
                thumbnails.updateCover(of: note.id, page: notebook.pages[0].snapshot(), paper: note.paper)
            }
    }
}
