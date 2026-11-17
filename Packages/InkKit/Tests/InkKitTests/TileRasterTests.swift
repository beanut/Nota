import CoreGraphics
import Foundation
@testable import InkKit
import Testing

/// A wavy pen stroke across the page at `y`.
private func wave(y: CGFloat, x0: CGFloat = 30, length: Int = 50, seed: Int = 0) -> Stroke {
    let points = (0 ..< length).map { i -> StrokePoint in
        let t = CGFloat(i)
        return StrokePoint(location: CGPoint(x: x0 + t * 9, y: y + 18 * sin((t + CGFloat(seed)) * 0.3)),
                           force: 0.4 + 0.5 * CGFloat(i % 5) / 5, altitude: .pi / 3, azimuth: 0.3,
                           timestamp: Double(i) / 240)
    }
    return Stroke(id: UUID(), color: RGBA.swatches[seed % RGBA.swatches.count], brush: TestBrush.pencil.brush(width: 4),
                  points: points)
}

/// Pixels of two tile images within a level in a few places (region refills aren't byte for byte).
private func sameTile(_ a: CGImage?, _ b: CGImage?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data?, da.count == db.count else {
        return false
    }
    var differing = 0
    da.withUnsafeBytes { pa in
        db.withUnsafeBytes { pb in
            let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
            for i in 0 ..< x.count where abs(Int(x[i]) - Int(y[i])) > 1 {
                differing += 1
            }
        }
    }
    return differing <= 40
}

/// Just enough of a canvas to host a coordinator.
@MainActor
private final class Host: RenderCoordinatorHost {
    var renderTransform = ViewTransform(scale: 1.3, offset: .zero)
    var renderBounds = CGRect(x: 0, y: 0, width: 640, height: 840)
    var restingScale: CGFloat = 1.3
    var isMoving = false
    var isEditingInk = false
    var pencilLocation: CGPoint?
    func fittedTransform() -> ViewTransform {
        renderTransform
    }

    func hasOutstandingEstimates(for _: UUID) -> Bool {
        false
    }

    func renderCoordinatorNeedsLayout() {}
    func renderCoordinatorDidPublish() {}
    func renderCoordinatorDidDrawPending(canvasRect _: CGRect) {}
}

@MainActor
private func waitUntil(timeout: TimeInterval = 30, _ done: () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done() {
        guard Date() < deadline else {
            Issue.record("timed out")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// A page's tiles kept as a `TileRaster` (NOT-106): left by canvases going away, restored instead of
/// filled, caught up after edits from the page's change log, and read back from bytes after a relaunch.
@MainActor
@Suite("Kept page tiles", .serialized)
struct TileRasterTests {
    let document = CanvasDocument(pageSize: .letter)
    private let host = Host()

    init() {
        for n in 0 ..< 14 {
            document.add(wave(y: 40 + CGFloat(n) * 52, seed: n))
        }
    }

    /// A coordinator on its own cache (cold, as after a relaunch or the shared cache letting the page go).
    private func coordinator(embedded: Bool = false, cache: TileCache = TileCache(byteBudget: 128 << 20),
                             for page: CanvasDocument? = nil) -> RenderCoordinator {
        let scheduler = RenderScheduler(limits: .init(idle: 4, gesture: 2, lowPriority: 2), frameInterval: 0)
        let coordinator = RenderCoordinator(document: page ?? document, embedded: embedded, cache: cache,
                                            scheduler: scheduler)
        coordinator.host = host
        coordinator.resize(to: host.renderBounds, scale: 2)
        return coordinator
    }

    private func settle(_ coordinator: RenderCoordinator) async throws {
        coordinator.requestRender()
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
    }

    /// Settles a canvas on the page, then lets it go, leaving the page's raster.
    private func capture(embedded: Bool = false) async throws -> TileRaster {
        let before = document.tileRasterGeneration
        let shown = coordinator(embedded: embedded)
        try await settle(shown)
        shown.captureTileRaster()
        try await waitUntil { document.tileRasterGeneration != before }
        return try #require(document.tileRaster)
    }

    /// Every tile the cache holds at the page's version is the tile drawn from scratch. Drawn off the main
    /// actor: canvases in other suites need it.
    private func expectTilesDrawnFromScratch(in cache: TileCache, page: CanvasDocument? = nil) async {
        let page = page ?? document
        let strokes = page.strokes, index = page.strokeIndex
        let held = cache.tiles(page: page.cacheID).filter { $0.value.revision == page.inkVersion }
        #expect(!held.isEmpty)
        let wrong = await Task.detached { () -> [String] in
            let geometry = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, StrokeRenderer.keptGeometry(for: $0)) })
            let ink = InkSnapshot(strokes: strokes, index: index, geometry: geometry, skipped: [])
            return held.compactMap { key, tile in
                let expected = RenderCoordinator.draw(key, from: ink, revision: 0, filler: CoreGraphicsTileFiller())
                return sameTile(tile.image, expected.image) ? nil : "\(key.col),\(key.row)"
            }
        }.value
        #expect(wrong.isEmpty, "tiles \(wrong) aren't the tiles drawn from scratch")
    }

    @Test func aPageShownAgainIsRestoredNotFilled() async throws {
        let raster = try await capture()
        #expect(raster.revision == document.inkVersion)
        let cache = TileCache(byteBudget: 128 << 20)
        let reopened = coordinator(cache: cache)
        try await settle(reopened)
        #expect(reopened.fillStats.tilesFilled == 0)
        #expect(reopened.fillStats.tilesRestored > 0)
        await expectTilesDrawnFromScratch(in: cache)
    }

    /// An edit after the raster was left: the tiles it didn't reach are restored as they are, those it did
    /// are restored and refilled only where it reached, and the page is what drawing it from scratch gives.
    @Test func anEditSinceTheRasterRefillsOnlyWhereItReached() async throws {
        let raster = try await capture()
        let added = wave(y: 300, x0: 120, length: 8, seed: 3)
        document.add(added)
        #expect(document.inkVersion > raster.revision)
        let cache = TileCache(byteBudget: 128 << 20)
        let reopened = coordinator(cache: cache)
        try await settle(reopened)
        let stats = reopened.fillStats
        #expect(stats.tilesRestored > 0)
        #expect(stats.tilesFilled > 0)
        #expect(stats.tilesFilled == stats.tilesRefilledInPart, "only parts of tiles are filled")
        let reach = StrokeIndex.reach(of: added)
        let level = reopened.level(for: host.renderTransform)
        let reached = TileKey.keys(covering: reach.intersection(document.pageBounds), page: document.cacheID, level: level)
        #expect(stats.tilesFilled <= reached.count)
        await expectTilesDrawnFromScratch(in: cache)

        // Left again: the tiles nothing reached are carried over; the page's raster is at its version now.
        reopened.captureTileRaster()
        try await waitUntil { document.tileRaster?.revision == document.inkVersion }
        let again = try #require(document.tileRaster)
        #expect(again.tileCount == raster.tileCount)
    }

    /// Changes the log doesn't know (older than it keeps; here, made before the page was copied, as a copy
    /// starts its log afresh) can't be caught up: those tiles are filled whole.
    @Test func aRasterOlderThanTheLogIsFilledAgain() async throws {
        _ = try await capture()
        document.add(wave(y: 700, x0: 20, length: 3, seed: 5))
        let copy = document.copy()
        #expect(copy.tileRaster != nil)
        #expect(copy.inkChanges.base > copy.tileRaster?.revision ?? .max)
        let cache = TileCache(byteBudget: 128 << 20)
        let reopened = coordinator(cache: cache, for: copy)
        try await settle(reopened)
        #expect(reopened.fillStats.tilesRestored == 0)
        await expectTilesDrawnFromScratch(in: cache, page: copy)
    }

    /// A raster whose tile pixels are damaged falls back to filling those tiles.
    @Test func damagedTilesInARasterAreFilled() async throws {
        let raster = try await capture()
        var data = raster.data
        for i in 44 + 20 * raster.tileCount ..< data.count {
            data[i] = 0x33
        }
        let page = CanvasDocument(file: document.inkFile, pageSize: document.pageSize)
        #expect(page.restoreCommittedTiles(data))
        let cache = TileCache(byteBudget: 128 << 20)
        let reopened = coordinator(cache: cache, for: page)
        try await settle(reopened)
        #expect(reopened.fillStats.tilesRestored < raster.tileCount)
        #expect(reopened.fillStats.tilesFilled > 0)
        await expectTilesDrawnFromScratch(in: cache, page: page)
    }

    /// After a relaunch: the page read from its file again, its tiles from their bytes. Nothing is filled.
    @Test func aRelaunchedPageShowsItsKeptTilesWithoutFilling() async throws {
        let raster = try await capture()
        let relaunched = CanvasDocument(file: document.inkFile, pageSize: document.pageSize)
        #expect(relaunched.inkVersion == 0)
        #expect(relaunched.restoreCommittedTiles(Data(raster.data)))
        let cache = TileCache(byteBudget: 128 << 20)
        let shown = coordinator(cache: cache, for: relaunched)
        try await settle(shown)
        #expect(shown.fillStats.tilesFilled == 0)
        #expect(shown.fillStats.tilesRestored > 0)
        await expectTilesDrawnFromScratch(in: cache, page: relaunched)
    }

    /// An embedded page (continuous scrolling) leaves the tiles it had, and fills none to complete them; a
    /// paged canvas fills the rest so the whole page comes back.
    @Test func anEmbeddedPageLeavesOnlyTheTilesItHad() async throws {
        host.renderTransform = ViewTransform(scale: 1.3, offset: CGPoint(x: 0, y: -500)) // the bottom of the page
        let embedded = try await capture(embedded: true)
        let level = TileLevel(pixelsPerPoint: host.restingScale * 2)
        let all = TileKey.keys(covering: document.pageBounds, page: document.cacheID, level: level)
        #expect(embedded.tileCount > 0)
        #expect(embedded.tileCount < all.count)
        let paged = try await capture()
        #expect(paged.tileCount == all.count)
    }

    @Test func observersHearWhenTilesAreLeft() async throws {
        var heard = 0
        let owner = NSObject()
        document.observeCommittedTiles(owner) { heard += 1 }
        _ = try await capture()
        #expect(heard == 1)
        let tiles = try #require(document.committedTiles)
        #expect(tiles.inkVersion == document.inkVersion)
        // The app's stored copy of the same bytes replaces the one in memory.
        let stored = Data(tiles.data)
        document.adoptPersistedTiles(stored, for: tiles)
        #expect(document.committedTiles?.data == stored)
        document.stopObservingCommittedTiles(owner)
        document.add(wave(y: 500, seed: 9))
        _ = try await capture()
        #expect(heard == 1)
    }
}
