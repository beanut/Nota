import SwiftData
import SwiftUI

/// What the sidebar has selected.
enum LibrarySection: Hashable {
    case all, recents, favorites, shared, deleted
    case folder(PersistentIdentifier)

    static let smart: [LibrarySection] = [.all, .recents, .favorites, .shared, .deleted]

    var title: String {
        switch self {
        case .all: "All Notes"
        case .recents: "Recents"
        case .favorites: "Favorites"
        case .shared: "Shared"
        case .deleted: "Recently Deleted"
        case .folder: "Folder"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "doc.text"
        case .recents: "clock"
        case .favorites: "star"
        case .shared: "person.2"
        case .deleted: "trash"
        case .folder: "folder"
        }
    }

    /// Whether a note belongs in this section. Recently Deleted shows only deleted notes; every other
    /// section hides them.
    func contains(_ note: Note) -> Bool {
        switch self {
        case .deleted: return note.isDeleted
        case _ where note.isDeleted: return false
        case .all: return true
        case .recents:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
            return note.modifiedAt >= cutoff
        case .favorites: return note.isFavorite
        case .shared: return note.isShared
        case .folder(let id): return note.folder?.persistentModelID == id
        }
    }
}

/// Root of the app: a sidebar of smart collections and folders beside a grid of notes. Opening a note
/// pushes the InkKit canvas and hides the sidebar.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selection: LibrarySection? = .all
    @State private var path: [Note] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
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
        .task { SampleData.seedIfNeeded(in: modelContext) }
    }
}

#Preview {
    LibraryView()
        .environment(InkStore())
        .modelContainer(for: [Note.self, Folder.self], inMemory: true)
}
