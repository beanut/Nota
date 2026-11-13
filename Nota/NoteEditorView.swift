import InkKit
import NotaCore
import NotaDocuments
import NotaUI
import SwiftData
import SwiftUI

/// A note opened for writing: the InkKit canvas under a navigation bar. The title is shown and renamed
/// from the Pen Case's More menu rather than in the bar.
///
/// Page changes (adding, removing, reordering, resizing) are saved to the note's manifest shortly after
/// they happen; leaving the note or backgrounding the app saves too.
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
    @Environment(\.scenePhase) private var scenePhase
    /// Each page's revision when the note was opened or last saved with ink changes.
    @State private var savedRevisions: [UUID: Int] = [:]
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        let notebook = documents.notebook(for: note)
        InkCanvasEditor(notebook: notebook, title: $note.title)
            .inkTheme(.nota)
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
            .onAppear { savedRevisions = revisions(of: notebook) }
            .onReceive(notebook.objectWillChange) { _ in scheduleSave(notebook) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    save(notebook)
                }
            }
            .onDisappear {
                save(notebook)
                // The first page is the cover; skipped if it hasn't changed since its last render.
                let cover = notebook.pages[0]
                thumbnails.updateCover(of: note.id, page: cover.snapshot(),
                                       paper: documents.paper(ofPage: cover.id, in: note))
            }
    }

    /// `objectWillChange` fires before the notebook changes and often several times per edit, so the save
    /// waits a moment and runs once.
    private func scheduleSave(_ notebook: InkNotebook) {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            save(notebook)
        }
    }

    private func save(_ notebook: InkNotebook) {
        pendingSave?.cancel()
        pendingSave = nil
        let current = revisions(of: notebook)
        // Ink edits count only on pages that were already there; new and removed pages are layout changes.
        let inkChanged = current.contains { id, revision in savedRevisions[id].map { $0 != revision } ?? false }
        documents.save(note, inkChanged: inkChanged)
        savedRevisions = current
    }

    private func revisions(of notebook: InkNotebook) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: notebook.pages.map { ($0.id, $0.revision) })
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
