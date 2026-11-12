import Foundation
import InkKit
@testable import NotaCore
import Testing

@Suite("NoteManifest")
struct NoteManifestTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "manifest.json")
    }

    @Test func roundTripsThroughDisk() throws {
        var manifest = NoteManifest(pageCount: 3, size: .a4, paper: .grid)
        manifest.pages[1].size = .letter.landscape
        manifest.pages[2].paper = .dotted
        let url = temporaryURL()
        try manifest.write(to: url)
        let read = try #require(NoteManifest.read(from: url))
        #expect(read.hasSameLayout(as: manifest))
        #expect(read.pageCount == 3)
        #expect(read.coverPaper == .grid)
    }

    @Test func keepsAtLeastOnePage() {
        #expect(NoteManifest(pageCount: 0, size: .letter, paper: .lined).pageCount == 1)
    }

    @Test func refusesNewerFormatVersion() throws {
        var manifest = NoteManifest(size: .letter, paper: .lined)
        manifest.formatVersion = NoteManifest.currentFormatVersion + 1
        let url = temporaryURL()
        try manifest.write(to: url)
        #expect(NoteManifest.read(from: url) == nil)
    }

    @Test func duplicateGetsFreshPageIDs() {
        let original = NoteManifest(pageCount: 2, size: .a5, paper: .plain)
        let copy = original.duplicated()
        #expect(copy.pages.map(\.size) == original.pages.map(\.size))
        #expect(Set(copy.pages.map(\.id)).isDisjoint(with: original.pages.map(\.id)))
    }
}

@Suite("DocumentStore")
@MainActor
struct DocumentStoreTests {
    private let library = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    @Test func newNoteMirrorsItsManifest() {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test", pageCount: 5, paper: .lined)
        store.create(note, size: .a4, paper: .grid)
        #expect(note.pageCount == 1)
        #expect(note.paper == .grid)
        #expect(store.notebook(for: note).pages.first?.pageSize == .a4)
    }

    @Test func savingAddedPagesUpdatesThePageCount() {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, paper: .dotted)
        let notebook = store.notebook(for: note)
        notebook.addPage()
        store.save(note)
        #expect(note.pageCount == 2)

        // A fresh store reads the same layout back from disk.
        let reopened = DocumentStore(library: library).notebook(for: note)
        #expect(reopened.pageCount == 2)
        #expect(reopened.pages.map(\.id) == notebook.pages.map(\.id))
    }
}
