import NotaCore
import NotaDocuments
import SwiftData
import SwiftUI

@main
struct NotaApp: App {
    /// One store, document cache and thumbnail cache for every window, so a note open in two windows is
    /// the same notebook in both and an edit in one shows in the other.
    private let container: ModelContainer
    @State private var documents = DocumentStore()
    @State private var thumbnails = ThumbnailStore()

    init() {
        do {
            container = try ModelContainer(for: Note.self, Folder.self)
        } catch {
            fatalError("Couldn't open the library store: \(error)")
        }
    }

    var body: some Scene {
        // Library windows: the sidebar and grid, with up to two notes open side by side.
        WindowGroup {
            LibraryView()
                .environment(documents)
                .environment(thumbnails)
        }
        .modelContainer(container)
        .commands { NoteCommands() }
        // Note activities go to note windows, never here.
        .handlesExternalEvents(matching: ["nota-library"])

        // A note in a window of its own: "Open in New Window", or a note dragged out of the library.
        WindowGroup(id: NoteWindow.sceneID, for: UUID.self) { $noteID in
            NoteWindow(noteID: $noteID)
                .environment(documents)
                .environment(thumbnails)
        }
        .modelContainer(container)
        .handlesExternalEvents(matching: [NoteActivity.targetContentIdentifier])
    }
}
