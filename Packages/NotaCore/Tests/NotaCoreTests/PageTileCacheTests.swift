import CoreGraphics
import Foundation
@_spi(Testing) import InkKit
@testable import NotaCore
import Testing

/// Pages' tiles kept between launches (NOT-106). "Relaunching" is a fresh `DocumentStore` (and a fresh
/// tile cache) on the same folders.
@Suite("Page tile cache")
@MainActor
struct PageTileCacheTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    private var library: URL {
        root.appending(path: "Library", directoryHint: .isDirectory)
    }

    private var tilesFolder: URL {
        root.appending(path: "Tiles", directoryHint: .isDirectory)
    }

    private func launch(byteLimit: Int = 256 << 20) -> (DocumentStore, PageTileCache) {
        let cache = PageTileCache(directory: tilesFolder, byteLimit: byteLimit)
        return (DocumentStore(library: library, autosaveDelay: .seconds(60), tileCache: cache), cache)
    }

    private func draw(on page: CanvasDocument, at x: CGFloat = 20) {
        page.drawTestStroke(through: [CGPoint(x: x, y: 20), CGPoint(x: x + 30, y: 60), CGPoint(x: x + 60, y: 40)])
    }

    /// A saved note with ink on its page, and its page.
    private func savedNote(_ store: DocumentStore, title: String = "Test") async -> (Note, CanvasDocument) {
        let note = Note(title: title)
        store.create(note, size: .a5, template: .preset(.dots))
        let page = await store.notebook(for: note).pages[0]
        draw(on: page)
        store.save(note)
        await store.flush()
        return (note, page)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ done: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done() {
            guard Date() < deadline else {
                Issue.record("timed out")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func tileFile(_ cache: PageTileCache, _ page: CanvasDocument, of note: Note) -> URL {
        cache.url(ofPage: page.id, note: note.id)
    }

    /// Leaves the page's tiles, as a canvas going away does, and waits until they're kept (once the save's
    /// hash of the page's ink is in).
    private func leaveTiles(on page: CanvasDocument, of note: Note, in cache: PageTileCache,
                            pixelsPerPoint: CGFloat = 1) async throws {
        page.leaveTilesForTesting(pixelsPerPoint: pixelsPerPoint)
        try await waitUntil { exists(tileFile(cache, page, of: note)) }
        await cache.flush()
    }

    @Test func tilesLeftOnASavedPageComeBackAfterARelaunch() async throws {
        let (store, cache) = launch()
        let (note, page) = await savedNote(store)
        try await leaveTiles(on: page, of: note, in: cache)
        let left = try #require(page.committedTiles)

        let (relaunched, _) = launch()
        let reopened = await relaunched.notebook(for: note).pages[0]
        let restored = try #require(reopened.committedTiles)
        #expect(restored.data == left.data)
        #expect(restored.inkVersion == reopened.inkVersion)
        #expect(reopened.strokeCount == 1)
    }

    @Test func tilesOfInkNotSavedYetWaitForTheSave() async throws {
        let (store, cache) = launch()
        let (note, page) = await savedNote(store)
        try await waitUntil { store.isLoaded(note.id) }
        draw(on: page, at: 120) // not saved yet: autosave is a minute away
        page.leaveTilesForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)
        await cache.flush()
        #expect(!exists(tileFile(cache, page, of: note)))
        store.save(note)
        await store.flush()
        try await waitUntil { exists(tileFile(cache, page, of: note)) }
        await cache.flush()

        let (relaunched, _) = launch()
        let reopened = await relaunched.notebook(for: note).pages[0]
        #expect(reopened.strokeCount == 2)
        #expect(reopened.committedTiles?.data == page.committedTiles?.data)
    }

    /// Tiles of ink saved over since aren't shown: the page fills, and the stale file goes.
    @Test func staleTilesAreDroppedAndThePageFilled() async throws {
        let (store, cache) = launch()
        let (note, page) = await savedNote(store)
        try await leaveTiles(on: page, of: note, in: cache)
        draw(on: page, at: 140) // saved, but no canvas left tiles for it
        store.save(note)
        await store.flush()
        await cache.flush()
        #expect(exists(tileFile(cache, page, of: note)))

        let (relaunched, relaunchedCache) = launch()
        let reopened = await relaunched.notebook(for: note).pages[0]
        #expect(reopened.strokeCount == 2)
        #expect(reopened.committedTiles == nil)
        await relaunchedCache.flush()
        #expect(!exists(tileFile(cache, page, of: note)))
    }

    /// A damaged or foreign tiles file never stops a note opening: the page opens with its ink, without
    /// tiles, and the file goes.
    @Test(arguments: ["header", "tiles", "truncated"])
    func corruptTilesFilesAreDroppedAndThePageFilled(_ damage: String) async throws {
        let (store, cache) = launch()
        let (note, page) = await savedNote(store, title: damage)
        try await leaveTiles(on: page, of: note, in: cache)
        let url = tileFile(cache, page, of: note)
        var bytes = try Data(contentsOf: url)
        switch damage {
        case "header": bytes[0] ^= 0xFF
        case "tiles": bytes[40] ^= 0xFF // InkKit's own header, after the cache's
        default: bytes = bytes.prefix(60)
        }
        try bytes.write(to: url)

        let (relaunched, relaunchedCache) = launch()
        let reopened = await relaunched.notebook(for: note).pages[0]
        #expect(reopened.strokeCount == 1)
        #expect(reopened.committedTiles == nil)
        await relaunchedCache.flush()
        #expect(!exists(url))
    }

    @Test func theLeastRecentlyOpenedNotesTilesGoPastTheLimit() async throws {
        let (store, cache) = launch()
        let (older, olderPage) = await savedNote(store, title: "Older")
        try await leaveTiles(on: olderPage, of: older, in: cache, pixelsPerPoint: 2)
        let one = cache.byteCount
        #expect(one > 0)
        // Opened long ago.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)],
                                              ofItemAtPath: cache.folder(ofNote: older.id).path)

        // A cache with room for one note's tiles: keeping the newer note's lets the older's go.
        let small = PageTileCache(directory: tilesFolder, byteLimit: one + one / 2)
        let newerStore = DocumentStore(library: library, autosaveDelay: .seconds(60), tileCache: small)
        let (newer, newerPage) = await savedNote(newerStore, title: "Newer")
        try await leaveTiles(on: newerPage, of: newer, in: small, pixelsPerPoint: 2)
        #expect(!exists(small.folder(ofNote: older.id)))
        #expect(exists(tileFile(small, newerPage, of: newer)))
    }

    @Test func deletingANoteForgetsItsTiles() async throws {
        let (store, cache) = launch()
        let (note, page) = await savedNote(store)
        try await leaveTiles(on: page, of: note, in: cache)
        store.discard(noteID: note.id)
        await cache.flush()
        #expect(!exists(cache.folder(ofNote: note.id)))
    }

    @Test func tilesOfPagesANoteNoLongerHasGoWhenItOpens() async throws {
        let (store, cache) = launch()
        let (note, page) = await savedNote(store)
        try await leaveTiles(on: page, of: note, in: cache)
        let stray = cache.url(ofPage: UUID(), note: note.id)
        try FileManager.default.copyItem(at: tileFile(cache, page, of: note), to: stray)

        let (relaunched, _) = launch()
        _ = await relaunched.notebook(for: note)
        #expect(!exists(stray))
        #expect(exists(tileFile(cache, page, of: note)))
    }

    @Test func withoutATileCacheNothingIsKept() async {
        let store = DocumentStore(library: library, autosaveDelay: .seconds(60))
        let (_, page) = await savedNote(store)
        page.leaveTilesForTesting()
        #expect(page.committedTiles != nil)
        #expect(!exists(tilesFolder))
    }
}
