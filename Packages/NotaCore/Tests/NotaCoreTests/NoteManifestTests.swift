import CoreGraphics
import Foundation
import ImageIO
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
        var manifest = NoteManifest(pageCount: 3, size: .a4, template: .preset(.smallGrid))
        manifest.pages[1].size = .letter.landscape
        manifest.pages[2].template = PageTemplate.preset(.cornell).on(.dark)
        let url = temporaryURL()
        try manifest.write(to: url)
        let read = try #require(NoteManifest.read(from: url))
        #expect(read.hasSameLayout(as: manifest))
        #expect(read.pageCount == 3)
        #expect(read.coverTemplate == .preset(.smallGrid))
        #expect(read.pages[2].template == PageTemplate.preset(.cornell).on(.dark))
    }

    /// Format 1 stored a paper name per page.
    @Test func readsFormatOneManifests() throws {
        let id = UUID()
        let json = """
        {"formatVersion": 1, "createdAt": "2026-11-01T10:00:00Z", "modifiedAt": "2026-11-02T10:00:00Z",
         "defaultPageSize": {"width": 612, "height": 792, "name": "Letter"},
         "pages": [{"id": "\(id.uuidString)", "size": {"width": 612, "height": 792, "name": "Letter"}, "paper": "grid"},
                   {"id": "\(UUID().uuidString)", "size": {"width": 612, "height": 792}, "paper": "lined"}]}
        """
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let read = try #require(NoteManifest.read(from: url))
        #expect(read.pages.map(\.id).first == id)
        #expect(read.pages.map(\.template) == [.preset(.smallGrid), .preset(.collegeRuled)])
    }

    @Test func keepsAtLeastOnePage() {
        #expect(NoteManifest(pageCount: 0, size: .letter, template: .noteDefault).pageCount == 1)
    }

    @Test func refusesNewerFormatVersion() throws {
        var manifest = NoteManifest(size: .letter, template: .noteDefault)
        manifest.formatVersion = NoteManifest.currentFormatVersion + 1
        let url = temporaryURL()
        try manifest.write(to: url)
        #expect(NoteManifest.read(from: url) == nil)
    }

    @Test func duplicateGetsFreshPageIDs() {
        let original = NoteManifest(pageCount: 2, size: .a5, template: .blank)
        let copy = original.duplicated()
        #expect(copy.pages.map(\.size) == original.pages.map(\.size))
        #expect(copy.pages.map(\.template) == original.pages.map(\.template))
        #expect(Set(copy.pages.map(\.id)).isDisjoint(with: original.pages.map(\.id)))
    }

    @Test func listsEachBackgroundOnce() {
        let background = TemplateBackground(kind: .image)
        var manifest = NoteManifest(pageCount: 3, size: .letter, template: .blank)
        manifest.pages[0].template.background = background
        manifest.pages[2].template.background = background
        #expect(manifest.backgrounds == [background])
    }
}
