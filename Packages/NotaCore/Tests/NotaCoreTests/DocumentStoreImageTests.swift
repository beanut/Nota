import CoreGraphics
import Foundation
@_spi(Testing) import InkKit
@testable import NotaCore
import Testing

/// Pictures in note packages: stored once in `assets/`, read back after a relaunch, carried along when a
/// note is duplicated or its pages are sent to another note, and cleaned up once no page uses them.
/// Each test has its own library folder and its own `ImageAssets`, so "relaunching" starts with nothing in
/// memory.
@Suite("DocumentStore pictures")
@MainActor
struct DocumentStoreImageTests {
    private let library = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    private func store(_ assets: ImageAssets) -> DocumentStore {
        DocumentStore(library: library, assets: assets)
    }

    private func assetFiles(of note: Note) -> [String] {
        let folder = NotePackage.assetsURL(for: note.id, in: library)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Puts the picture on `page` as an `ImageObject`, the way the canvas inserts one.
    @discardableResult
    private func place(_ data: Data, on page: CanvasDocument, in assets: ImageAssets, x: CGFloat = 20) throws -> ImageObject {
        let id = try #require(assets.add(data))
        let image = ImageObject(asset: id, pixelSize: CGSize(width: 4, height: 4), frame: CGRect(x: x, y: 20, width: 80, height: 80))
        page.addObject(image)
        return image
    }

    @Test func aPictureIsStoredOnceAndReadBackAfterARelaunch() async throws {
        let assets = ImageAssets()
        let documents = store(assets)
        let note = Note(title: "Photos")
        documents.create(note, size: .letter, template: .blank)
        let page = try #require(await documents.notebook(for: note).pages.first)
        let data = try makePNG(red: 0.1)
        let image = try place(data, on: page, in: assets)
        try place(data, on: page, in: assets, x: 200) // the same picture again
        documents.save(note)
        await documents.flush()

        #expect(assetFiles(of: note) == ["\(image.asset).png"])
        let file = NotePackage.assetURL(for: image.asset, fileExtension: "png", noteID: note.id, in: library)
        #expect(try Data(contentsOf: file) == data)

        // A fresh app: nothing in memory, the picture is found in the package.
        let fresh = ImageAssets()
        let reopened = try #require(await store(fresh).notebook(for: note).pages.first)
        let read = reopened.objects.compactMap { $0 as? ImageObject }
        #expect(read.count == 2)
        #expect(read.first == image)
        #expect(fresh.data(for: image.asset) == data)
    }

    @Test func picturesNoPageUsesAreRemovedWhenTheNoteIsNextOpened() async throws {
        let assets = ImageAssets()
        let documents = store(assets)
        let note = Note(title: "Photos")
        documents.create(note, size: .letter, template: .blank)
        let page = try #require(await documents.notebook(for: note).pages.first)
        let kept = try place(makePNG(red: 0.3), on: page, in: assets)
        try place(makePNG(red: 0.5), on: page, in: assets, x: 200)
        documents.save(note)
        await documents.flush()
        #expect(assetFiles(of: note).count == 2)

        page.undoForTesting() // takes the second picture off the page
        documents.save(note)
        await documents.flush()
        // Still there while undo could bring it back.
        #expect(assetFiles(of: note).count == 2)

        _ = await store(ImageAssets()).notebook(for: note)
        #expect(assetFiles(of: note) == ["\(kept.asset).png"])
    }

    @Test func duplicatingANoteCopiesItsPictures() async throws {
        let assets = ImageAssets()
        let documents = store(assets)
        let original = Note(title: "Original"), copy = Note(title: "Copy")
        documents.create(original, size: .letter, template: .blank)
        let page = try #require(await documents.notebook(for: original).pages.first)
        let image = try place(makePNG(red: 0.7), on: page, in: assets)
        documents.duplicate(original, as: copy)
        await documents.flush()
        #expect(assetFiles(of: copy) == ["\(image.asset).png"])
        let reopened = try #require(await store(ImageAssets()).notebook(for: copy).pages.first)
        #expect((reopened.objects.first as? ImageObject)?.asset == image.asset)
    }

    @Test func pagesSentToAnotherNoteBringTheirPictures() async throws {
        let assets = ImageAssets()
        let documents = store(assets)
        let source = Note(title: "Source"), target = Note(title: "Target")
        documents.create(source, size: .letter, template: .blank)
        documents.create(target, size: .letter, template: .blank)
        let sourceNotebook = await documents.notebook(for: source)
        let image = try place(makePNG(red: 0.9), on: sourceNotebook.pages[0], in: assets)
        documents.save(source)
        await documents.flush()

        await documents.addPages(sourceNotebook.pages.map { $0.copy() }, to: target)
        await documents.flush()
        #expect(assetFiles(of: target) == ["\(image.asset).png"])
    }
}
