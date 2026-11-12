import SwiftData
import SwiftUI

@main
struct NotaApp: App {
    @State private var inkStore = InkStore()
    @State private var thumbnails = ThumbnailStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(inkStore)
                .environment(thumbnails)
        }
        .modelContainer(for: [Note.self, Folder.self])
    }
}
