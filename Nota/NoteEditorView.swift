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
///
/// A link to another note opens it in this note's place (`openNote`), and the window's `trail` remembers where
/// it came from, so the editor's Back button returns there.
struct NoteEditorView: View {
    @Bindable var note: Note
    /// The notes open in the library window around the editor, for its window menu. Nil in a note's own
    /// window, which shows just the one note.
    var workspace: Binding<NoteWorkspace>?
    /// Where links between notes have led in this window, for Back.
    @Binding var trail: LinkTrail
    /// Shows another note in this one's place, when a link to it is followed or Back returns to it.
    var openNote: (UUID) -> Void
    @Environment(DocumentStore.self) private var documents
    @Environment(ThumbnailStore.self) private var thumbnails
    @State private var notebook: InkNotebook?
    /// For the page sidebar's Copy to Note and Move to Note.
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]

    var body: some View {
        Group {
            if let notebook {
                InkCanvasEditor(notebook: notebook, title: $note.title,
                                pageDestinations: pageDestinations, sendPages: sendPages, links: links)
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

extension NoteEditorView {
    private var pageDestinations: [PageDestination] {
        Library.notesToSendPagesTo(allNotes, from: note.id).map { PageDestination(id: $0.id, title: $0.title) }
    }

    /// Other notes to link to, their pages, and going to them and back.
    private var links: NoteLinks {
        let back = trail.back(from: note.id).flatMap { step in
            noteToOpen(step.fromNote).map { from in
                LinkBack(title: from.title.isEmpty ? String(localized: "Untitled") : from.title) { goBack() }
            }
        }
        return NoteLinks(
            notes: Library.notesToLinkTo(allNotes, from: note.id).map { PageDestination(id: $0.id, title: $0.title) },
            pages: { id in noteToOpen(id).map { documents.pageIDs(of: $0) } ?? [] },
            open: { id, page in follow(to: id, page: page) },
            back: back
        )
    }

    /// The note with `id`, unless it's gone or in Recently Deleted.
    private func noteToOpen(_ id: UUID) -> Note? {
        allNotes.first { $0.id == id && !$0.isDeleted }
    }

    /// A link to another note (or one of its pages) was followed. A note that's in Recently Deleted or gone
    /// isn't opened. One already open beside this one just turns to the page.
    private func follow(to id: UUID, page: UUID?) {
        if id != note.id, noteToOpen(id) == nil {
            return
        }
        if let page {
            documents.showPage(page, ofNote: id)
        }
        guard id != note.id, workspace?.wrappedValue.contains(id) != true else { return }
        trail.follow(from: note.id, page: notebook?.currentPage.id, to: id)
        openNote(id)
    }

    /// Back to the note the link that opened this one was on, at the page it was on.
    private func goBack() {
        guard let step = trail.goBack(from: note.id), noteToOpen(step.fromNote) != nil else { return }
        if let page = step.fromPage {
            documents.showPage(page, ofNote: step.fromNote)
        }
        openNote(step.fromNote)
    }

    /// Adds pages copied in the sidebar to another note; false if that note is gone.
    private func sendPages(_ pages: [CanvasDocument], to destination: PageDestination) async -> Bool {
        guard let target = allNotes.first(where: { $0.id == destination.id && !$0.isDeleted }) else { return false }
        await documents.addPages(pages, to: target)
        return true
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
