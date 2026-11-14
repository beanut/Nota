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
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                saveOpenNotes()
            }
        }
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

    /// Saves every open note when the app leaves the screen, where it can be killed without warning, and
    /// asks for the time to finish writing.
    private func saveOpenNotes() {
        documents.saveAll()
        let task = BackgroundTask()
        task.begin()
        Task {
            await documents.flush()
            task.end()
        }
    }
}

/// Extra time to finish work after the app leaves the screen, ended when the work is done or the time
/// runs out, whichever comes first.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Save notes") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
