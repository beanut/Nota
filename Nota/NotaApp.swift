import NotaCore
import NotaDocuments
import SwiftData
import SwiftUI

@main
struct NotaApp: App {
    @State private var documents = DocumentStore()
    @State private var thumbnails = ThumbnailStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(documents)
                .environment(thumbnails)
        }
        .modelContainer(for: [Note.self, Folder.self])
    }
}
