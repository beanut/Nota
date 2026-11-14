import NotaCore
import NotaDocuments
import NotaUI
import SwiftData
import SwiftUI

/// The sidebar icon for each section. Which notes a section holds is decided in NotaCore (`LibrarySection`).
extension LibrarySection {
    var icon: NotaIcon {
        switch self {
        case .all: .grid
        case .recents: .clock
        case .favorites: .star
        case .shared: .share
        case .deleted: .trash
        case .folder: .folder
        }
    }
}

/// Root of a library window: a sidebar of smart collections and folders beside a grid of notes. Opening a
/// note pushes the InkKit canvas and hides the sidebar; opening a second one beside it splits the window.
///
/// Each window keeps its own section and open notes, and restores them with its scene.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DocumentStore.self) private var documents
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("library.section") private var storedSection = LibrarySection.all.sceneValue
    @SceneStorage("library.workspace") private var workspace = NoteWorkspace()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selection: Binding<LibrarySection?> {
        Binding {
            LibrarySection(sceneValue: storedSection) ?? .all
        } set: {
            storedSection = ($0 ?? .all).sceneValue
        }
    }

    /// The open notes, as the navigation path of the single-note stack.
    private var path: Binding<[Note]> {
        Binding {
            openNotes
        } set: {
            workspace = NoteWorkspace(noteIDs: $0.map(\.id))
        }
    }

    /// The workspace's notes that still exist; one deleted permanently (here or in another window) drops out.
    private var openNotes: [Note] {
        workspace.noteIDs.compactMap { modelContext.note(withID: $0) }
    }

    var body: some View {
        let notes = openNotes
        Group {
            if notes.count == NoteWorkspace.capacity {
                // At the root, not in the split view's detail column: there the two sides' toolbars would be
                // merged into the column's one navigation bar.
                NoteSplitView(notes: notes, workspace: $workspace)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(selection: selection)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
                        // No sidebar button while a note is open: the editor's bar is for drawing.
                        .toolbar(removing: notes.isEmpty ? nil : .sidebarToggle)
                } detail: {
                    NavigationStack(path: path) {
                        NotesBrowser(section: selection.wrappedValue ?? .all, path: path)
                            .navigationDestination(for: Note.self) { note in
                                NoteEditorView(note: note, workspace: $workspace)
                            }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .focusedSceneValue(\.noteSceneActions, sceneActions(for: notes))
        .onChange(of: storedSection) { workspace.closeAll() }
        .onChange(of: notes.isEmpty, initial: true) { _, isEmpty in
            withAnimation { columnVisibility = isEmpty ? .all : .detailOnly }
        }
        .onChange(of: notes.map(\.id)) { _, ids in
            // Keep the stored workspace in step when an open note was deleted permanently.
            if ids != workspace.noteIDs {
                workspace = NoteWorkspace(noteIDs: ids)
            }
        }
        .task {
            // Notes whose packages outlived the library index (its store was lost or reset) come back
            // first, so the sample library isn't seeded over them.
            await documents.rebuildIndex(in: modelContext)
            SampleData.seedIfNeeded(in: modelContext)
            // Page counts and dates come from each note's manifest, not from what was seeded or last cached.
            let notes = (try? modelContext.fetch(FetchDescriptor<Note>())) ?? []
            await documents.reconcile(notes)
        }
    }

    /// The note the shortcuts act on is the one opened last: the one beside, in a split.
    private func sceneActions(for notes: [Note]) -> NoteSceneActions {
        guard let focused = notes.last else { return NoteSceneActions() }
        return NoteSceneActions(
            openInNewWindow: { openWindow(id: NoteWindow.sceneID, value: focused.id) },
            closeNote: { withAnimation { workspace.close(focused.id) } },
            swapSides: notes.count > 1 ? { withAnimation { workspace.swapSides() } } : nil
        )
    }
}

#Preview {
    LibraryView()
        .environment(DocumentStore())
        .environment(ThumbnailStore())
        .modelContainer(for: [Note.self, Folder.self], inMemory: true)
}
