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

@Suite("DocumentStore")
@MainActor
struct DocumentStoreTests {
    private let library = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    @Test func newNoteMirrorsItsManifest() {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test", pageCount: 5)
        store.create(note, size: .a4, template: .preset(.dots))
        #expect(note.pageCount == 1)
        #expect(note.template == .preset(.dots))
        let page = store.notebook(for: note).pages.first
        #expect(page?.pageSize == .a4)
        #expect(page?.template == .preset(.dots))
    }

    @Test func savingAddedPagesUpdatesThePageCount() {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .preset(.dots))
        let notebook = store.notebook(for: note)
        notebook.addPage()
        store.save(note)
        #expect(note.pageCount == 2)

        // A fresh store reads the same layout back from disk.
        let reopened = DocumentStore(library: library).notebook(for: note)
        #expect(reopened.pageCount == 2)
        #expect(reopened.pages.map(\.id) == notebook.pages.map(\.id))
        #expect(reopened.pages.map(\.template) == [.preset(.dots), .preset(.dots)])
    }

    @Test func templateChangedInTheEditorIsSavedPerPage() {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .preset(.collegeRuled))
        let notebook = store.notebook(for: note)
        notebook.addPage()
        notebook.setTemplate(PageTemplate.preset(.monthlyPlanner).on(.cream), forPageAt: 1)
        store.save(note)

        let reopened = DocumentStore(library: library).notebook(for: note)
        #expect(reopened.pages.map(\.template) == [.preset(.collegeRuled), PageTemplate.preset(.monthlyPlanner).on(.cream)])
    }

    @Test func settingTheTemplateFromTheLibraryUpdatesAnOpenNotebook() {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .preset(.collegeRuled))
        let notebook = store.notebook(for: note)
        notebook.addPage()
        store.setTemplate(.preset(.isometric), of: note)
        #expect(notebook.pages.allSatisfy { $0.template == .preset(.isometric) })
        #expect(note.template == .preset(.isometric))
        // A later save from the editor keeps it.
        store.save(note)
        #expect(DocumentStore(library: library).notebook(for: note).pages.allSatisfy { $0.template == .preset(.isometric) })
    }

    @Test func customBackgroundIsStoredInThePackageAndReloaded() throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .blank)
        let artwork = try #require(try TemplateArtwork(data: makePNG()))
        var template = PageTemplate.blank
        template.background = artwork.background
        store.notebook(for: note).setTemplate(template, artwork: artwork, forPageAt: 0)
        store.save(note)

        let file = NotePackage.templateURL(for: artwork.background, noteID: note.id, in: library)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let page = try #require(DocumentStore(library: library).notebook(for: note).pages.first)
        #expect(page.template.background == artwork.background)
        #expect(page.templateArtwork?.id == artwork.id)
        #expect(page.templateArtwork?.data == artwork.data)

        // Back on a built-in: the file goes.
        store.setTemplate(.preset(.dots), of: note)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func duplicateCopiesCustomBackgrounds() throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .blank)
        let artwork = try #require(try TemplateArtwork(data: makePNG()))
        var template = PageTemplate.blank
        template.background = artwork.background
        store.notebook(for: note).setTemplate(template, artwork: artwork, forPageAt: 0)
        store.save(note)

        let copy = Note(title: "Copy")
        store.duplicate(note, as: copy)
        let file = NotePackage.templateURL(for: artwork.background, noteID: copy.id, in: library)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

/// A tiny opaque PNG.
private func makePNG() throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
