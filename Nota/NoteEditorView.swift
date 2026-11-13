import InkKit
import NotaCore
import NotaDocuments
import NotaUI
import SwiftData
import SwiftUI

/// A note opened for writing: the InkKit canvas under a navigation bar. The title is shown and renamed
/// from the Pen Case's More menu rather than in the bar.
///
/// The note's pages are read from its package while the paper shows. From then on `DocumentStore` saves
/// them by itself shortly after each change, and again when the editor closes; the app saves every open
/// note when it leaves the screen.
///
/// The same note can be open in more than one place (two windows, or a window and a split): every editor
/// shows the one notebook `DocumentStore` keeps for it, so ink drawn in one appears in the others.
struct NoteEditorView: View {
    @Bindable var note: Note
    /// The notes open in the library window around the editor, for its window menu. Nil in a note's own
    /// window, which shows just the one note.
    var workspace: Binding<NoteWorkspace>?
    @Environment(DocumentStore.self) private var documents
    @Environment(ThumbnailStore.self) private var thumbnails
    @State private var notebook: InkNotebook?

    var body: some View {
        Group {
            if let notebook {
                InkCanvasEditor(notebook: notebook, title: $note.title)
                    .inkTheme(.nota)
            } else {
                // Reading the note's pages; usually too quick to notice.
                NotaColor.bgApp
                    .ignoresSafeArea()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(NotaColor.bgApp, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if let workspace {
                ToolbarItem(placement: .topBarTrailing) {
                    NoteWindowMenu(note: note, workspace: workspace)
                }
            }
        }
        .task(id: note.id) {
            let opened = await documents.beginEditing(note)
            if Task.isCancelled {
                // Closed before the pages arrived.
                documents.endEditing(note)
            } else {
                notebook = opened
            }
        }
        .onDisappear {
            guard let notebook else { return }
            self.notebook = nil
            documents.endEditing(note)
            // The first page is the cover; skipped if it hasn't changed since its last render.
            thumbnails.updateCover(of: note.id, page: notebook.pages[0].snapshot())
        }
    }
}

/// Opening the note in a new window, another note beside it, or swapping the sides of a split.
private struct NoteWindowMenu: View {
    let note: Note
    @Binding var workspace: NoteWorkspace
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]

    var body: some View {
        Menu {
            Button {
                openWindow(id: NoteWindow.sceneID, value: note.id)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Menu {
                ForEach(Library.notesToOpenBeside(allNotes, excluding: workspace.noteIDs)) { other in
                    Button(other.title) {
                        withAnimation { workspace.openBeside(other.id) }
                    }
                }
            } label: {
                Label(workspace.isSplit ? "Replace Note Beside" : "Open Beside", systemImage: "rectangle.split.2x1")
            }
            if workspace.isSplit {
                Button {
                    withAnimation { workspace.swapSides() }
                } label: {
                    Label("Swap Notes", systemImage: "arrow.left.arrow.right")
                }
            }
        } label: {
            NotaIconView(.split)
        }
        .buttonStyle(.notaIcon(selected: workspace.isSplit))
        .accessibilityLabel("Windows")
    }
}
