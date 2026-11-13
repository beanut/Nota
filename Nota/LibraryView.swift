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

/// Root of the app: a sidebar of smart collections and folders beside a grid of notes. Opening a note
/// pushes the InkKit canvas and hides the sidebar.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DocumentStore.self) private var documents
    @State private var selection: LibrarySection? = .all
    @State private var path: [Note] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
                // No sidebar button while a note is open: the editor's bar is for drawing.
                .toolbar(removing: path.isEmpty ? nil : .sidebarToggle)
        } detail: {
            NavigationStack(path: $path) {
                NotesBrowser(section: selection ?? .all, path: $path)
                    .navigationDestination(for: Note.self) { note in
                        NoteEditorView(note: note)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { path.removeAll() }
        .onChange(of: path.isEmpty) { _, isEmpty in
            withAnimation { columnVisibility = isEmpty ? .all : .detailOnly }
        }
        .task {
            SampleData.seedIfNeeded(in: modelContext)
            // Page counts and dates come from each note's manifest, not from what was seeded or last cached.
            let notes = (try? modelContext.fetch(FetchDescriptor<Note>())) ?? []
            await documents.reconcile(notes)
        }
    }
}

#Preview {
    LibraryView()
        .environment(DocumentStore())
        .environment(ThumbnailStore())
        .modelContainer(for: [Note.self, Folder.self], inMemory: true)
}
