import CoreGraphics
import Foundation
@testable import InkKit
import Testing

private let hasMetal = WaxRenderer.shared != nil

/// Pixels differing by more than 2 of 255 in any channel between two images of one size, and the worst
/// difference.
private func differences(_ a: CGImage, _ b: CGImage) -> (count: Int, worst: Int)? {
    guard a.width == b.width, a.height == b.height, let da = rgbaBytes(a), let db = rgbaBytes(b) else { return nil }
    var count = 0, worst = 0
    for p in stride(from: 0, to: da.count, by: 4) {
        var delta = 0
        for c in 0 ..< 4 {
            delta = max(delta, abs(Int(da[p + c]) - Int(db[p + c])))
        }
        worst = max(worst, delta)
        if delta > 2 {
            count += 1
        }
    }
    return (count, worst)
}

/// The kinds of ink a tile has to get right where it's cut from its neighbours.
enum TileInk: String, CaseIterable {
    case plain, multiRun, grain, scaledGrain, multiply, eraser, crayon

    func brush() -> BrushDescriptor {
        switch self {
        case .plain: return TestBrush.pen.brush(width: 4)
        case .multiRun: return TestBrush.pen.brush(width: 5, tilt: true) // alpha varies with tilt: several runs
        case .grain: return TestBrush.pencil.brush(width: 4, tilt: true)
        case .scaledGrain:
            var brush = TestBrush.pencil.brush(width: 6, tilt: true)
            brush.texture = .grain(scale: 2.5, contrast: 1, seed: 7) // a 160-pixel cell: no multiple of 64
            return brush
        case .multiply: return TestBrush.highlighter.brush(width: 16)
        case .eraser: return TestBrush.pixelEraser.brush(width: 9)
        case .crayon: return BrushDescriptor.crayon
        }
    }
}

/// A page of wavy strokes crossing each other and the tile edges. Every third stroke is of `kind` (all
/// of them for the eraser's page would erase nothing, so it's drawn over pen ink).
private func strokePage(of kind: TileInk, count: Int = 24, size: CGSize = CGSize(width: 480, height: 640)) -> [Stroke] {
    (0 ..< count).map { n in
        let brush = n % 3 == 2 || kind == .plain ? kind.brush() : TestBrush.pen.brush(width: 3)
        let y0 = CGFloat(n * 61 % Int(size.height - 40)) + 20, x0 = CGFloat(n * 53 % 120) + 5
        let points = (0 ..< 48).map { (i: Int) -> StrokePoint in
            let t = CGFloat(i)
            let location = CGPoint(x: x0 + t * 8, y: y0 + 22 * sin(CGFloat(i + n) * 0.31))
            return StrokePoint(location: location, force: 0.3 + 0.6 * CGFloat(i % 7) / 7,
                               altitude: 0.3 + CGFloat(i % 5) * 0.25, azimuth: t * 0.2, timestamp: Double(i) / 240)
        }
        let color = brush.blend == .multiply ? RGBA(r: 1, g: 0.85, b: 0.2) : RGBA.swatches[n % RGBA.swatches.count]
        return Stroke(id: UUID(), color: color, brush: brush, points: points,
                      createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(n)))
    }
}

private func snapshot(_ strokes: [Stroke]) -> InkSnapshot {
    InkSnapshot(strokes: strokes, index: StrokeIndex(strokes: strokes),
                geometry: Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, StrokeRenderer.geometry(for: $0)) }),
                skipped: [])
}

/// Not on the main actor: these fill a lot of tiles, and canvases in other suites need the main queue.
@Suite("Committed tiles")
struct TileTests {
    static let pageSize = CGSize(width: 480, height: 640)
    static let level = TileLevel(pixelsPerPoint: 2)
    let page = UUID()

    /// The page drawn whole at `level`, as one bitmap the size of all its tiles.
    private func whole(_ ink: InkSnapshot, keys: [TileKey]) throws -> CGImage {
        let cols = (keys.map(\.col).max() ?? 0) + 1, rows = (keys.map(\.row).max() ?? 0) + 1
        let rect = CGRect(x: 0, y: 0, width: cols * TileKey.side, height: rows * TileKey.side)
        let ctx = try #require(TileBitmap.context(pixelRect: rect, level: Self.level))
        CoreGraphicsTileFiller().draw(rect: rect.applying(CGAffineTransform(scaleX: 1 / 2, y: 1 / 2)), level: Self.level,
                                      strokes: ink.drawable(in: CGRect(x: -1000, y: -1000, width: 10000, height: 10000)),
                                      into: ctx)
        return try #require(ctx.makeImage())
    }

    @Test func keysCoverARectInPagePixels() {
        let level = TileLevel(pixelsPerPoint: 3)
        let side = CGFloat(TileKey.side) / 3
        let keys = TileKey.keys(covering: CGRect(x: side - 1, y: 0, width: side, height: side * 2), page: page,
                                level: level)
        #expect(keys.map(\.col) == [0, 1, 0, 1])
        #expect(keys.map(\.row) == [0, 0, 1, 1])
        #expect(keys[3].rect == CGRect(x: side, y: side, width: side, height: side))
        #expect(keys[3].pixelRect == CGRect(x: 256, y: 256, width: 256, height: 256))
        #expect(TileKey.keys(covering: .null, page: page, level: level).isEmpty)
        #expect(TileLevel(pixelsPerPoint: 2).isNear(TileLevel(pixelsPerPoint: 2.039)))
        #expect(!TileLevel(pixelsPerPoint: 2).isNear(TileLevel(pixelsPerPoint: 2.05)))
    }

    /// Tiles assembled are the page drawn whole: no seams at the tile edges and nothing different inside
    /// (Core Graphics' coverage of a path cut by another clip may differ by a level or two), for every kind
    /// of ink, the scaled grain whose cell isn't a whole number of tiles included.
    @Test(arguments: TileInk.allCases)
    func tilesAssembleIntoThePageDrawnWhole(_ kind: TileInk) throws {
        guard kind != .crayon || hasMetal else { return }
        let ink = snapshot(strokePage(of: kind))
        let keys = TileKey.keys(covering: CGRect(origin: .zero, size: Self.pageSize), page: page, level: Self.level)
        let whole = try whole(ink, keys: keys)
        var differing = 0, edge = 0
        for key in keys {
            let tile = RenderCoordinator.draw(key, from: ink, revision: 1, filler: CoreGraphicsTileFiller())
            let crop = try #require(whole.cropping(to: key.pixelRect))
            guard let image = tile.image else {
                #expect(rgbaBytes(crop)?.allSatisfy { $0 == 0 } == true, "an empty tile where the page has ink")
                continue
            }
            let diff = try #require(differences(image, crop))
            differing += diff.count
            // Seams: the two pixels along each edge on their own.
            let edges = [CGRect(x: 0, y: 0, width: 256, height: 2), CGRect(x: 0, y: 254, width: 256, height: 2),
                         CGRect(x: 0, y: 0, width: 2, height: 256), CGRect(x: 254, y: 0, width: 2, height: 256)]
            for rect in edges {
                let a = try #require(image.cropping(to: rect)), b = try #require(crop.cropping(to: rect))
                edge += try #require(differences(a, b)).count
            }
        }
        let total = Double(keys.count * TileKey.side * TileKey.side)
        #expect(Double(differing) / total < 0.002, "\(kind): \(Double(differing) / total * 100)% of pixels differ")
        #expect(Double(edge) / total < 0.0005, "\(kind): \(edge) seam pixels differ")
    }

    /// The tiles against `PageRenderer`'s page (thumbnails, PDF, the goldens), which stays whole: within
    /// 0.2% of pixels. The page is a whole number of grain cells tall, so both pin the grain alike.
    @Test(arguments: [TileInk.plain, .multiRun, .grain, .scaledGrain, .multiply, .eraser])
    func tilesMatchThePageRenderer(_ kind: TileInk) throws {
        let strokes = strokePage(of: kind)
        let ink = snapshot(strokes)
        let bounds = CGRect(origin: .zero, size: Self.pageSize)
        let reference = try #require(PageRenderer.image(strokes: strokes, objects: [], region: bounds, scale: 2))
        let keys = TileKey.keys(covering: bounds, page: page, level: Self.level)
        let ctx = try #require(TileBitmap.viewBitmap(pixelSize: reference.size, scale: 1))
        let tiles = keys.compactMap { key in
            RenderCoordinator.draw(key, from: ink, revision: 1, filler: CoreGraphicsTileFiller()).image.map { (key, $0) }
        }
        TileBitmap.compose(tiles, at: ViewTransform(scale: 2, offset: .zero), in: ctx)
        let assembled = try #require(ctx.makeImage())
        let diff = try #require(differences(assembled, reference))
        let fraction = Double(diff.count) / Double(reference.width * reference.height)
        #expect(fraction < 0.002, "\(kind): \(fraction * 100)% of pixels differ from the page renderer")
    }

    /// Grain tiles filled on several threads at once, at several levels, are the bytes of the tile filled
    /// alone. Core Graphics caches a pattern image's rasterization, so threads sharing one pattern at
    /// different scales used to leave each other a few pixels (NOT-112): each thread keeps its own patterns.
    @Test(arguments: [TileInk.grain, .scaledGrain])
    func grainFillsOnManyThreadsAreAFillAlone(_ kind: TileInk) {
        let ink = snapshot(strokePage(of: kind))
        let levels = [TileLevel(pixelsPerPoint: 2), TileLevel(pixelsPerPoint: 2.37), TileLevel(pixelsPerPoint: 3.1),
                      TileLevel(pixelsPerPoint: 5.5)]
        let key = TileKey(page: page, level: levels[1], col: 0, row: 3)
        let alone = RenderCoordinator.draw(key, from: ink, revision: 0, filler: CoreGraphicsTileFiller()).image
        let expected = alone?.dataProvider?.data as Data?
        #expect(expected != nil)
        let lock = NSLock()
        var differing = 0
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let level = levels[i % levels.count]
            let tile = level == key.level ? key : TileKey(page: page, level: level, col: i % 3, row: i % 5)
            let data = RenderCoordinator.draw(tile, from: ink, revision: 0, filler: CoreGraphicsTileFiller())
                .image?.dataProvider?.data as Data?
            if tile == key, data != expected {
                lock.withLock { differing += 1 }
            }
        }
        #expect(differing == 0, "\(kind): \(differing) of 50 fills differ from the tile filled alone")
    }

    /// A tile drawn twice from scratch is the same bytes, and a stroke drawn on top of a cached tile (a
    /// finished stroke committed) is what filling the tile again with it gives.
    @Test func aStrokeDrawnIntoATileMatchesTheTileFilledAgain() throws {
        let strokes = strokePage(of: .multiRun)
        let ink = snapshot(strokes)
        let before = snapshot(Array(strokes.dropLast()))
        let filler = CoreGraphicsTileFiller()
        for key in TileKey.keys(covering: CGRect(origin: .zero, size: Self.pageSize), page: page, level: Self.level) {
            let fresh = RenderCoordinator.draw(key, from: ink, revision: 2, filler: filler)
            let again = RenderCoordinator.draw(key, from: ink, revision: 2, filler: filler)
            #expect(fresh.image?.dataProvider?.data == again.image?.dataProvider?.data)

            let old = RenderCoordinator.draw(key, from: before, revision: 1, filler: filler)
            let last = try #require(strokes.last)
            let ctx = try #require(TileBitmap.context(for: key, startingFrom: old.image))
            filler.fill(key, region: nil, strokes: [TileStroke(geometry: StrokeRenderer.geometry(for: last),
                                                               brush: last.brush, color: last.color)], into: ctx)
            let drawn = try #require(ctx.makeImage())
            guard let expected = fresh.image else { continue }
            let diff = try #require(differences(drawn, expected))
            let differing = diff.count
            #expect(differing <= 2, "tile \(key.col), \(key.row): \(differing) pixels differ")
        }
    }

    /// A raster of the `.grain` page's tiles at `revision`, and the tiles.
    private func raster(revision: Int = 4) throws -> (TileRaster, [(key: TileKey, image: CGImage?)]) {
        let ink = snapshot(strokePage(of: .grain))
        let keys = TileKey.keys(covering: CGRect(origin: .zero, size: Self.pageSize), page: page, level: Self.level)
        let tiles: [(key: TileKey, image: CGImage?)] = keys.map { key in
            (key, RenderCoordinator.draw(key, from: ink, revision: revision, filler: CoreGraphicsTileFiller()).image)
        }
        return try (#require(TileRaster(tiles: tiles, revision: revision, level: Self.level, pageSize: Self.pageSize)), tiles)
    }

    @Test func aRasterRestoresTheSameTiles() throws {
        let (raster, tiles) = try raster()
        let inked = tiles.filter { $0.image != nil }.count
        #expect(inked > 0)
        #expect(raster.byteCount < inked * 256 * 1024 / 2)
        #expect(raster.tileCount == tiles.count)
        for (key, image) in tiles {
            #expect(raster.holds(key))
            let restored = try #require(raster.restore(key))
            #expect(restored.revision == 4)
            #expect(restored.image?.dataProvider?.data == image?.dataProvider?.data)
        }
        let elsewhere = TileKey(page: page, level: TileLevel(pixelsPerPoint: 3), col: 0, row: 0)
        #expect(!raster.holds(elsewhere))
        #expect(raster.restore(TileKey(page: page, level: Self.level, col: 40, row: 0)) == nil)
    }

    /// The bytes an app keeps between launches read back as the same raster, at the revision given.
    @Test func aRasterReadFromItsBytesIsTheSameRaster() throws {
        let (raster, tiles) = try raster()
        let read = try #require(TileRaster(data: raster.data, revision: 0))
        #expect(read.revision == 0)
        #expect(read.level == Self.level)
        #expect(read.pageSize == Self.pageSize)
        #expect(read.tileCount == raster.tileCount)
        for (key, image) in tiles {
            #expect(read.restore(key)?.image?.dataProvider?.data == image?.dataProvider?.data)
        }
        // From a slice (as an app's own file header would leave it).
        let framed = Data([1, 2, 3]) + raster.data
        let slice = framed[framed.startIndex + 3 ..< framed.endIndex]
        let fromSlice = try #require(TileRaster(data: slice, revision: 2))
        let key = try #require(tiles.first { $0.image != nil }).key
        #expect(fromSlice.restore(key)?.image?.dataProvider?.data == read.restore(key)?.image?.dataProvider?.data)
        // Carried into a new raster still compressed, the same tiles.
        let entries = tiles.compactMap { tile in raster.blob(for: tile.key).map { TileRaster.Entry(
            col: tile.key.col,
            row: tile.key.row,
            blob: $0
        ) } }
        let carried = try #require(TileRaster(entries: entries, revision: 5, level: Self.level, pageSize: Self.pageSize))
        #expect(carried.restore(key)?.image?.dataProvider?.data == read.restore(key)?.image?.dataProvider?.data)
    }

    /// Bytes that aren't a raster this InkKit can show are refused, so the page is filled instead.
    @Test func damagedOrForeignBytesAreNotARaster() throws {
        let (raster, tiles) = try raster()
        let data = raster.data
        #expect(TileRaster(data: Data(), revision: 0) == nil)
        #expect(TileRaster(data: data.prefix(30), revision: 0) == nil) // cut in the header
        #expect(TileRaster(data: data.prefix(60), revision: 0) == nil) // cut in the entries
        var magic = data
        magic[0] ^= 0xFF
        #expect(TileRaster(data: magic, revision: 0) == nil)
        var renderer = data
        renderer[8] &+= 1 // an older or newer renderer drew these pixels
        #expect(TileRaster(data: renderer, revision: 0) == nil)
        var format = data
        format[4] &+= 1
        #expect(TileRaster(data: format, revision: 0) == nil)
        // A tile whose pixels are damaged doesn't restore (its fill draws it), while the others do.
        let inked = try #require(tiles.first { $0.image != nil }).key
        let blobStart = 44 + 20 * raster.tileCount
        var pixels = data
        for i in blobStart ..< data.count {
            pixels[i] = 0x5A
        }
        let damaged = try #require(TileRaster(data: pixels, revision: 0))
        #expect(damaged.restore(inked) == nil)
        // Cut short: entries past the end are refused.
        #expect(TileRaster(data: data.prefix(data.count - 1), revision: 0) == nil)
    }

    @MainActor
    @Test func aDocumentKeepsItsRasterThroughEdits() {
        let doc = CanvasDocument()
        doc.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        let key = TileKey(page: doc.cacheID, level: Self.level, col: 0, row: 0)
        let ink = snapshot(doc.strokes)
        let tile = RenderCoordinator.draw(key, from: ink, revision: doc.inkVersion, filler: CoreGraphicsTileFiller())
        let version = doc.inkVersion
        doc.tileRaster = TileRaster(tiles: [(key, tile.image)], revision: version, level: Self.level,
                                    pageSize: doc.pageBounds.size)
        doc.undo()
        // Labelled with the version it shows; the log says what changed since.
        #expect(doc.tileRaster?.revision == version)
        #expect(doc.inkChanges.changes(from: version, to: doc.inkVersion)?.isEmpty == false)
    }

    /// Filling happens before the main actor is entered: canvases in other suites need it.
    @Test func aDocumentTakesKeptTilesOnlyForItsSizeOfPage() async throws {
        let (raster, _) = try raster()
        try await expectOnlyItsSizeOfPageTakes(raster)
    }

    @MainActor
    private func expectOnlyItsSizeOfPageTakes(_ raster: TileRaster) throws {
        let doc = CanvasDocument(pageSize: PageSize(width: Self.pageSize.width, height: Self.pageSize.height))
        #expect(doc.restoreCommittedTiles(raster.data))
        #expect(doc.tileRaster?.revision == doc.inkVersion)
        #expect(doc.committedTiles?.data == raster.data)
        let other = CanvasDocument(pageSize: .letter)
        #expect(!other.restoreCommittedTiles(raster.data))
        #expect(!other.restoreCommittedTiles(Data("not tiles".utf8)))
        #expect(other.tileRaster == nil)
    }
}

@Suite("Tile cache")
struct TileCacheTests {
    let page = UUID()
    static let image: CGImage = {
        let ctx = TileBitmap.context(pixelRect: CGRect(x: 0, y: 0, width: 256, height: 256),
                                     level: TileLevel(pixelsPerPoint: 1))!
        return ctx.makeImage()!
    }()

    private func key(_ col: Int, level: CGFloat = 2) -> TileKey {
        TileKey(page: page, level: TileLevel(pixelsPerPoint: level), col: col, row: 0)
    }

    @Test func evictsLeastRecentlyUsedTilesNoOneShowsFirst() {
        let tileBytes = 256 * 256 * 4
        let cache = TileCache(byteBudget: tileBytes * 4)
        let owner = ObjectIdentifier(cache)
        // Shown: 0 and 1 at level 2; the resting level is 1.
        cache.setInterest(owner, page: page, visible: [key(0), key(1)], resting: TileLevel(pixelsPerPoint: 1))
        cache.store(Tile(image: Self.image, revision: 1), for: key(0))
        cache.store(Tile(image: Self.image, revision: 1), for: key(1))
        cache.store(Tile(image: Self.image, revision: 1), for: key(0, level: 1)) // resting, off screen
        cache.store(Tile(image: Self.image, revision: 1), for: key(5)) // neither
        #expect(cache.count == 4)
        cache.store(Tile(image: Self.image, revision: 1), for: key(6)) // over budget
        #expect(cache.bytes <= tileBytes * 4)
        #expect(cache.tile(for: key(5)) == nil, "the least recently used tile no one shows goes first")
        #expect(cache.tile(for: key(0)) != nil && cache.tile(for: key(1)) != nil, "tiles on screen stay")
        #expect(cache.tile(for: key(0, level: 1)) != nil, "the resting level goes after other levels")
        cache.store(Tile(image: Self.image, revision: 1), for: key(7))
        #expect(cache.tile(for: key(0)) != nil && cache.tile(for: key(1)) != nil)
        #expect(cache.tile(for: key(0, level: 1)) == nil || cache.tile(for: key(6)) == nil)
    }

    @Test func levelsZoomedThroughGoBeforeTheShownLevelsMargin() {
        let tileBytes = 256 * 256 * 4
        let cache = TileCache(byteBudget: tileBytes * 4)
        let owner = ObjectIdentifier(cache)
        cache.setInterest(owner, page: page, visible: [key(0)], resting: TileLevel(pixelsPerPoint: 1),
                          shown: [TileLevel(pixelsPerPoint: 2)])
        cache.store(Tile(image: Self.image, revision: 1), for: key(0)) // on screen
        cache.store(Tile(image: Self.image, revision: 1), for: key(0, level: 3)) // a level zoomed through
        cache.store(Tile(image: Self.image, revision: 1), for: key(1)) // the shown level's margin
        cache.store(Tile(image: Self.image, revision: 1), for: key(0, level: 1)) // resting
        _ = cache.tile(for: key(0, level: 3)) // used since the margin tile was
        // Over budget: evicted down to 90% of it, two tiles.
        cache.store(Tile(image: Self.image, revision: 1), for: key(2))
        #expect(cache.tile(for: key(0, level: 3)) == nil, "a level no one shows goes first, though used later")
        #expect(cache.tile(for: key(1)) == nil, "then the shown level's least recently used margin")
        #expect(cache.tile(for: key(0)) != nil && cache.tile(for: key(2)) != nil)
        #expect(cache.tile(for: key(0, level: 1)) != nil, "the resting level goes last")
    }

    @Test func aRefillNeverReplacesANewerRevision() {
        let cache = TileCache(byteBudget: 1 << 30)
        cache.store(Tile(image: nil, revision: 5), for: key(0))
        cache.storeIfNewer(Tile(image: Self.image, revision: 4), for: key(0))
        #expect(cache.tile(for: key(0))?.revision == 5)
        cache.storeIfNewer(Tile(image: Self.image, revision: 6), for: key(0))
        #expect(cache.tile(for: key(0))?.revision == 6)
        cache.storeIfNewer(Tile(image: nil, revision: Tile.unknownRevision), for: key(0))
        #expect(cache.tile(for: key(0))?.revision == Tile.unknownRevision) // mid-edit pixels always land
    }

    @Test func aChangeAdvancesTheTilesItDoesNotReach() {
        let cache = TileCache(byteBudget: 1 << 30)
        for col in 0 ..< 3 {
            cache.store(Tile(image: Self.image, revision: 3), for: key(col))
        }
        cache.store(Tile(image: Self.image, revision: 2), for: key(3))
        // Level 2: a tile is 128 points wide; the change is inside tile 1.
        cache.advance(page: page, from: 3, to: 4, outside: CGRect(x: 150, y: 10, width: 20, height: 20))
        #expect(cache.tiles(for: (0 ..< 4).map { key($0) }).map { $0?.revision } == [4, 3, 4, 2])
        #expect(cache.levels(page: page) == [TileLevel(pixelsPerPoint: 2)])
        cache.removeAll(page: page)
        #expect(cache.count == 0 && cache.bytes == 0)
    }
}

private extension CGImage {
    var size: CGSize {
        CGSize(width: width, height: height)
    }
}
