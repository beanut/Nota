import SwiftData
import SwiftUI

@main
struct NotaApp: App {
    @State private var inkStore = InkStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(inkStore)
        }
        .modelContainer(for: [Note.self, Folder.self])
    }
}
