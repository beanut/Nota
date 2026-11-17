import CoreGraphics
import Foundation
@testable import InkKit
import Metal
import XCTest

/// NOT-99 spike: throwaway prototypes of the committed-layer render architectures the canvas revamp
/// (M1.5) could use, on the 5k-stroke benchmark page. The decision they informed is in InkKit's README
/// (Architecture › Rendering pipeline); the numbers are in the NOT-99 pull request.
///
/// Not part of the benchmark run (`scripts/run-benchmarks.sh` runs only `InkBenchmarks` and
/// `CanvasBenchmarks`), and nothing here is used by shipping code. Run it with
/// `-only-testing:InkKitBenchmarks/RenderSpike` in Release; it prints `[inkbench] spike.*` lines.
///
/// 1. **Tiled Core Graphics**: page-space tiles at a zoom level, each filled by `StrokeRenderer.draw`
///    with the strokes a grid finds for it; tiles filled in parallel.
/// 2. **Metal**: each run's polygons drawn with stencil-then-cover (non-zero winding) into a 4× MSAA
///    target, straight at the viewport. No grain, `.copy` runs or exact multiply: the pixel comparison
///    with Core Graphics says how far from matching that leaves it.
/// 3. **Hybrid**: Core Graphics tiles handed to the GPU as textures; what's timed is the hand-off.
@MainActor
final class RenderSpike: XCTestCase {
    private var corpus: Corpus {
        Corpus.shared
    }

    // MARK: Page

    private struct Page {
        let strokes: [Stroke]
        let geometries: [StrokeGeometry]
        let items: [CommittedRenderer.Item]
        let grid: SpikeGrid
    }

    private func densePage(_ count: Int = 5000) -> Page {
        let strokes = corpus.page(strokes: count)
        let geometries = CommittedRenderer.geometries(for: strokes)
        let items = zip(strokes, geometries).map {
            CommittedRenderer.Item(id: $0.id, brush: $0.brush, color: $0.color, geometry: $1, stroke: nil)
        }
        return Page(strokes: strokes, geometries: geometries, items: items, grid: SpikeGrid(geometries.map(\.bounds)))
    }

    private var fitted: ViewTransform {
        Bench.fittedTransform(for: corpus.pageSize)
    }

    private func zoomed(_ zoom: CGFloat) -> ViewTransform {
        let box = corpus.inkBounds
        return Bench.zoomedTransform(for: corpus.pageSize, zoom: zoom, centredOn: CGPoint(x: box.midX, y: box.midY))
    }

    private func record(_ name: String, _ value: Double, _ unit: String = "ms") {
        BenchResults.record("spike.\(name)", value, unit: unit)
    }

    // MARK: Option 1: tiled Core Graphics

    /// Tile fill times, a full page at the fitted zoom and the viewport at 6× filled as tiles, an undo
    /// redrawing only the tiles one stroke touches, and tile memory, for several tile sizes.
    func testTiledCoreGraphics() {
        let page = densePage()
        measureTiles(page, pieces: nil, prefix: "cg", sides: [256, 512, 1024])
        let start = Bench.now()
        let pieces = SpikePieces(page.items)
        record("cg_culled.split_5k_ms", Bench.milliseconds(since: start))
        measureTiles(page, pieces: pieces, prefix: "cg_culled", sides: [256, 512])

        // Today's renderer on the same machine, for comparison: the screen at 1× and at 6×, in bands.
        record("cg.banded.screen_1x_ms", timeBanded(page, fitted))
        record("cg.banded.screen_6x_ms", timeBanded(page, zoomed(6)))
    }

    /// Option 1 with tiles of each of `sides` pixels. With `pieces`, a tile fills only the parts of each
    /// stroke's path (its strips and stamps) that reach it, instead of the whole path clipped to the tile.
    private func measureTiles(_ page: Page, pieces: SpikePieces?, prefix: String, sides: [Int]) {
        let fittedLevel = fitted.scale * Bench.displayScale // pixels per page point
        let level6 = fittedLevel * 6
        let viewport6 = zoomed(6).toCanvas(Bench.screenBounds)
        for side in sides {
            let name = "\(prefix).tile\(side)"
            // Every tile of the page at the fitted level, filled one at a time.
            let all = SpikeTiles.keys(covering: corpus.pageSize.bounds, level: fittedLevel, side: side)
            var fills: [Double] = [], counts: [Double] = []
            for key in all {
                let start = Bench.now()
                let n = SpikeTiles.fill(key, page: page.items, grid: page.grid, pieces: pieces)
                fills.append(Bench.milliseconds(since: start))
                counts.append(Double(n))
            }
            let s = Stats(fills)
            record("\(name).fill_1x_p50_ms", s.median)
            record("\(name).fill_1x_p95_ms", s.p95)
            record("\(name).fill_1x_max_ms", s.max)
            record("\(name).strokes_per_tile_p95", Stats(counts).p95, "strokes")

            // The whole page, every tile in parallel.
            record("\(name).page_1x_ms", timeParallel(all, page, pieces))
            record("\(name).page_1x_tiles", Double(all.count), "tiles")
            record("\(name).page_1x_mb", Double(all.count * side * side * 4) / 1_048_576, "MB")

            // The screen at 6×: what a pinch to 6× has to fill before it's sharp.
            let view6 = SpikeTiles.keys(covering: viewport6, level: level6, side: side)
            var fills6: [Double] = []
            for key in view6 {
                let start = Bench.now()
                SpikeTiles.fill(key, page: page.items, grid: page.grid, pieces: pieces)
                fills6.append(Bench.milliseconds(since: start))
            }
            record("\(name).fill_6x_p50_ms", Stats(fills6).median)
            record("\(name).fill_6x_p95_ms", Stats(fills6).p95)
            record("\(name).viewport_6x_ms", timeParallel(view6, page, pieces))
            record("\(name).viewport_6x_tiles", Double(view6.count), "tiles")
            record("\(name).viewport_6x_mb", Double(view6.count * side * side * 4) / 1_048_576, "MB")

            measureUndo(page, pieces: pieces, name: name, side: side, viewport6: viewport6)
        }
    }

    /// Undo of a handwriting stroke in the middle of the ink: refill the tiles its bounds reach, at the
    /// fitted level and at 6×.
    private func measureUndo(_ page: Page, pieces: SpikePieces?, name: String, side: Int, viewport6: CGRect) {
        let fittedLevel = fitted.scale * Bench.displayScale, level6 = fittedLevel * 6
        let centre = CGRect(x: viewport6.midX - 20, y: viewport6.midY - 20, width: 40, height: 40)
        // The most recent stroke there that's word-sized, not the long shading scribble.
        let victim = page.grid.query(centre).last { page.geometries[$0].bounds.width < 60 } ?? 0
        let dirty = page.geometries[victim].bounds.insetBy(dx: -2, dy: -2)
        var remaining = page.items
        remaining.remove(at: victim)
        let grid = SpikeGrid(remaining.map { $0.geometry!.bounds })
        var remainingPieces = pieces
        remainingPieces?.remove(at: victim)
        let dirty1 = SpikeTiles.keys(covering: dirty, level: fittedLevel, side: side)
        let dirty6 = SpikeTiles.keys(covering: dirty.intersection(viewport6), level: level6, side: side)
        let keys = dirty1 + dirty6
        var undo: [Double] = [], visible: [Double] = []
        for _ in 0 ..< 5 {
            let start = Bench.now()
            DispatchQueue.concurrentPerform(iterations: keys.count) { i in
                SpikeTiles.fill(keys[i], page: remaining, grid: grid, pieces: remainingPieces)
            }
            undo.append(Bench.milliseconds(since: start))
            // Only the level on screen (6×): what the user waits for.
            let shown = Bench.now()
            DispatchQueue.concurrentPerform(iterations: dirty6.count) { i in
                SpikeTiles.fill(dirty6[i], page: remaining, grid: grid, pieces: remainingPieces)
            }
            visible.append(Bench.milliseconds(since: shown))
        }
        // Dirty rect: only the stroke's padded bounds inside each tile are cleared and redrawn.
        var rectOnly: [Double] = []
        for _ in 0 ..< 5 {
            let start = Bench.now()
            DispatchQueue.concurrentPerform(iterations: keys.count) { i in
                SpikeTiles.fill(keys[i], page: remaining, grid: grid, pieces: remainingPieces, region: dirty)
            }
            rectOnly.append(Bench.milliseconds(since: start))
        }
        record("\(name).undo_one_stroke_ms", Stats(undo).median)
        record("\(name).undo_visible_6x_ms", Stats(visible).median)
        record("\(name).undo_dirty_rect_ms", Stats(rectOnly).median)
        record("\(name).undo_dirty_rect_strokes", Double(grid.query(dirty).count), "strokes")
        record("\(name).undo_tiles", Double(keys.count), "tiles")
        record("undo_victim_width_pt", page.geometries[victim].bounds.width, "pt")
    }

    /// Whether a page assembled from tiles is pixel for pixel the page drawn whole: seams, the multiply
    /// highlighter, the pixel eraser and pencil grain.
    func testTiledCoreGraphicsMatchesWholePage() throws {
        let page = densePage(2000)
        let pieces = SpikePieces(page.items)
        let level = fitted.scale * Bench.displayScale
        let kinds: [(String, (CommittedRenderer.Item) -> Bool)] = [
            ("", { _ in true }),
            (".plain", { $0.geometry!.runs.count == 1 && $0.brush.texture.grain == nil && $0.brush.blend == .normal }),
            (".multi_run", { $0.geometry!.runs.count > 1 && $0.brush.texture.grain == nil && $0.brush.blend == .normal }),
            (".grain", { $0.brush.texture.grain != nil }),
            (".multiply", { $0.brush.blend == .multiply })
        ]
        let variants = [(256, false, false, 0), (256, true, true, 0), (512, true, true, 0)]
            + (1 ..< kinds.count).map { (256, true, true, $0) }
        for (side, culled, pinned, kind) in variants {
            let items = page.items.map { kinds[kind].1($0) ? $0 : CommittedRenderer.Item(id: $0.id, brush: $0.brush,
                                                                                         color: $0.color, geometry: nil,
                                                                                         stroke: nil) }
            let keys = SpikeTiles.keys(covering: corpus.pageSize.bounds, level: level, side: side)
            let cols = (keys.map(\.col).max() ?? 0) + 1, rows = (keys.map(\.row).max() ?? 0) + 1
            let size = CGSize(width: cols * side, height: rows * side)
            // Whole: the page at the level's scale, offset 0, as one bitmap.
            let whole = try XCTUnwrap(CommittedRenderer.makeBitmap(pixelSize: size, scale: 1))
            CommittedRenderer.render(items.filter { $0.geometry != nil }, into: whole,
                                     bounds: CGRect(origin: .zero, size: size),
                                     transform: ViewTransform(scale: level, offset: .zero), parallel: false)
            let wholeImage = try XCTUnwrap(whole.makeImage())
            if kind == 0, !culled {
                // For scale: today's bands against the same page drawn on one thread.
                let banded = try XCTUnwrap(CommittedRenderer.makeBitmap(pixelSize: size, scale: 1))
                CommittedRenderer.render(page.items, into: banded, bounds: CGRect(origin: .zero, size: size),
                                         transform: ViewTransform(scale: level, offset: .zero), parallel: true)
                try record("cg.banded.mismatch_vs_whole_pct",
                           CanvasBenchmarks.differingFraction(XCTUnwrap(banded.makeImage()), wholeImage) * 100, "%")
            }
            // Each tile drawn on its own, against the same pixels cut out of the whole page.
            var edge = 0, inside = 0, worst = 0
            for key in keys {
                let tile = try XCTUnwrap(SpikeTiles.render(key, page: items, grid: page.grid,
                                                           pieces: culled ? pieces : nil,
                                                           pagePixelHeight: pinned ? rows * side : nil))
                let crop = try XCTUnwrap(wholeImage.cropping(to: CGRect(x: key.col * side, y: key.row * side,
                                                                        width: side, height: side)))
                let diff = try Self.differences(XCTUnwrap(Self.unflipped(tile)), XCTUnwrap(Self.unflipped(crop)), side: side)
                edge += diff.edge
                inside += diff.inside
                worst = max(worst, diff.worst)
            }
            let total = Double(keys.count * side * side)
            let name = "\(culled ? "cg_culled" : "cg").tile\(side)\(pinned ? ".grain_pinned" : "")\(kinds[kind].0)"
            record("\(name).seam_mismatch_edge_pct", Double(edge) / total * 100, "%")
            record("\(name).seam_mismatch_inside_pct", Double(inside) / total * 100, "%")
            record("\(name).seam_mismatch_worst", Double(worst), "levels")
        }
    }

    /// Where a Core Graphics tile's time goes: the fill cost per stroke of each kind, in one 256-pixel tile
    /// in the middle of the ink at the fitted level, with pieces culled to the tile.
    func testTileFillCostByKind() throws {
        let page = densePage()
        let pieces = SpikePieces(page.items)
        let level = fitted.scale * Bench.displayScale
        let box = corpus.inkBounds
        let key = try XCTUnwrap(SpikeTiles.keys(covering: CGRect(x: box.midX, y: box.midY, width: 1, height: 1),
                                                level: level, side: 256).first)
        let kinds: [(String, (CommittedRenderer.Item) -> Bool)] = [
            ("all", { _ in true }),
            ("plain", { $0.geometry!.runs.count == 1 && $0.brush.texture.grain == nil && $0.brush.blend == .normal }),
            ("multi_run", { $0.geometry!.runs.count > 1 && $0.brush.texture.grain == nil }),
            ("grain", { $0.brush.texture.grain != nil }),
            ("multiply", { $0.brush.blend == .multiply }),
            ("eraser", { $0.brush.blend == .destinationOut })
        ]
        for (name, include) in kinds {
            // Strokes not of this kind lose their geometry, so the tile skips them.
            let items = page.items.map { include($0) ? $0 : CommittedRenderer.Item(id: $0.id, brush: $0.brush,
                                                                                   color: $0.color, geometry: nil,
                                                                                   stroke: nil) }
            var times: [Double] = []
            var count = 0
            for _ in 0 ..< 3 {
                let start = Bench.now()
                count = SpikeTiles.fill(key, page: items, grid: page.grid, pieces: pieces)
                times.append(Bench.milliseconds(since: start))
            }
            record("cg_kind.\(name).strokes", Double(count), "strokes")
            record("cg_kind.\(name).us_per_stroke", Stats(times).median * 1000 / Double(max(count, 1)), "us")
        }
    }

    /// Pixels of two `side`-square images differing by more than 2 levels, within 2 pixels of the edge and
    /// inside that, and the largest difference.
    private struct Differences {
        var edge = 0, inside = 0, worst = 0
    }

    private static func differences(_ a: CGImage, _ b: CGImage, side: Int) -> Differences {
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data?, da.count == db.count
        else { return Differences(edge: side * side, inside: 0, worst: 255) }
        var edge = 0, inside = 0, worst = 0
        da.withUnsafeBytes { pa in
            db.withUnsafeBytes { pb in
                let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
                for row in 0 ..< side {
                    for col in 0 ..< side {
                        let i = (row * side + col) * 4
                        let d = (0 ..< 4).map { abs(Int(x[i + $0]) - Int(y[i + $0])) }.max() ?? 0
                        worst = max(worst, d)
                        guard d > 2 else { continue }
                        if row < 2 || col < 2 || row >= side - 2 || col >= side - 2 {
                            edge += 1
                        } else {
                            inside += 1
                        }
                    }
                }
            }
        }
        return Differences(edge: edge, inside: inside, worst: worst)
    }

    /// `image`'s pixels in a fresh bitmap, rows top to bottom, so two images can be compared byte for byte.
    private static func unflipped(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: space, bitmapInfo: CommittedRenderer.bitmapInfo)
        else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private func timeParallel(_ keys: [SpikeTiles.Key], _ page: Page, _ pieces: SpikePieces?) -> Double {
        var times: [Double] = []
        for _ in 0 ..< 3 {
            let start = Bench.now()
            DispatchQueue.concurrentPerform(iterations: keys.count) { i in
                SpikeTiles.fill(keys[i], page: page.items, grid: page.grid, pieces: pieces)
            }
            times.append(Bench.milliseconds(since: start))
        }
        return Stats(times).median
    }

    private func timeBanded(_ page: Page, _ transform: ViewTransform) -> Double {
        guard let ctx = CommittedRenderer.makeBitmap(pixelSize: Bench.pixelSize, scale: Bench.displayScale) else { return -1 }
        var times: [Double] = []
        for _ in 0 ..< 3 {
            let start = Bench.now()
            CommittedRenderer.render(page.items, into: ctx, bounds: Bench.screenBounds, transform: transform)
            times.append(Bench.milliseconds(since: start))
        }
        return Stats(times).median
    }

    // MARK: Option 2: Metal

    /// The page drawn on the GPU straight at the viewport, at 1× and 6×, and into one 512-pixel tile;
    /// the CPU cost of tessellating it; and how its pixels compare with Core Graphics'.
    func testMetal() throws {
        let page = densePage()
        let start = Bench.now()
        let renderer = try XCTUnwrap(SpikeMetal(page.items), "no Metal device")
        record("metal.tessellate_5k_ms", Bench.milliseconds(since: start))
        record("metal.vertex_mb", Double(renderer.vertexBytes) / 1_048_576, "MB")
        record("metal.multi_run_strokes", Double(renderer.multiRunStrokes), "strokes")
        record("metal.grain_strokes", Double(page.strokes.filter { $0.brush.texture.grain != nil }.count), "strokes")

        let px = (Int(Bench.pixelSize.width), Int(Bench.pixelSize.height))
        for (name, transform) in [("1x", fitted), ("6x", zoomed(6))] {
            var gpu: [Double] = [], encode: [Double] = []
            for _ in 0 ..< 5 {
                let timing = try XCTUnwrap(renderer.draw(transform: transform, pixelWidth: px.0, pixelHeight: px.1))
                gpu.append(timing.total)
                encode.append(timing.encode)
            }
            record("metal.screen_\(name)_ms", Stats(gpu).median)
            record("metal.screen_\(name)_encode_ms", Stats(encode).median)

            let shown = try XCTUnwrap(renderer.image(transform: transform, pixelWidth: px.0, pixelHeight: px.1))
            let ctx = try XCTUnwrap(CommittedRenderer.makeBitmap(pixelSize: Bench.pixelSize, scale: Bench.displayScale))
            CommittedRenderer.render(page.items, into: ctx, bounds: Bench.screenBounds, transform: transform)
            let reference = try XCTUnwrap(ctx.makeImage())
            record("metal.screen_\(name)_mismatch_pct", CanvasBenchmarks.differingFraction(shown, reference) * 100, "%")
            record("metal.screen_\(name)_mismatch_over16_pct",
                   SpikeMetal.differingFraction(shown, reference, over: 16) * 100, "%")
        }

        // One 512-pixel tile in the middle of the ink at 6×: an undo's worth of fill.
        let six = zoomed(6)
        let tile = ViewTransform(scale: six.scale, offset: CGPoint(x: six.offset.x - Bench.screen.width / 2 + 128,
                                                                   y: six.offset.y - Bench.screen.height / 2 + 128))
        var tileTimes: [Double] = []
        for _ in 0 ..< 5 {
            try tileTimes.append(XCTUnwrap(renderer.draw(transform: tile, pixelWidth: 512, pixelHeight: 512)).total)
        }
        record("metal.tile512_6x_ms", Stats(tileTimes).median)
        record("metal.targets_screen_mb", Double(px.0 * px.1 * (4 * 4 + 4 * 5 + 4)) / 1_048_576, "MB")
    }

    // MARK: Option 3: hybrid

    /// Handing a filled Core Graphics tile to the GPU: snapshotting it as an image (what `CALayer.contents`
    /// takes) and uploading it into a texture.
    func testHybridHandOff() throws {
        let page = densePage()
        let level = fitted.scale * Bench.displayScale * 6
        let keys = SpikeTiles.keys(covering: zoomed(6).toCanvas(Bench.screenBounds), level: level, side: 512)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 512, height: 512,
                                                                  mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var snapshot: [Double] = [], upload: [Double] = []
        for key in keys {
            let ctx = try XCTUnwrap(SpikeTiles.context(key))
            SpikeTiles.draw(key, page: page.items, grid: page.grid, into: ctx)
            var start = Bench.now()
            let image = ctx.makeImage()
            snapshot.append(Bench.milliseconds(since: start))
            XCTAssertNotNil(image)
            start = Bench.now()
            if let data = ctx.data {
                texture.replace(region: MTLRegionMake2D(0, 0, 512, 512), mipmapLevel: 0, withBytes: data,
                                bytesPerRow: ctx.bytesPerRow)
            }
            upload.append(Bench.milliseconds(since: start))
        }
        record("hybrid.tile512.snapshot_p50_ms", Stats(snapshot).median)
        record("hybrid.tile512.upload_p50_ms", Stats(upload).median)
    }
}

// MARK: - Prototype pieces

/// A uniform grid over stroke bounds: which strokes reach a rect, in page order.
struct SpikeGrid: @unchecked Sendable {
    static let cell: CGFloat = 32
    private var buckets: [Int: [Int32]] = [:]

    init(_ bounds: [CGRect]) {
        for (i, box) in bounds.enumerated() where !box.isNull {
            forEachCell(box) { buckets[$0, default: []].append(Int32(i)) }
        }
    }

    private func forEachCell(_ rect: CGRect, _ body: (Int) -> Void) {
        let x0 = Int((rect.minX / Self.cell).rounded(.down)), x1 = Int((rect.maxX / Self.cell).rounded(.down))
        let y0 = Int((rect.minY / Self.cell).rounded(.down)), y1 = Int((rect.maxY / Self.cell).rounded(.down))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0 ... y1 {
            for x in x0 ... x1 {
                body(y &* 65536 &+ x)
            }
        }
    }

    /// Indices of strokes whose cells meet `rect`, sorted (page order).
    func query(_ rect: CGRect) -> [Int] {
        var found = Set<Int32>()
        forEachCell(rect) { found.formUnion(buckets[$0] ?? []) }
        return found.map(Int.init).sorted()
    }
}

/// Page-space tiles: tile (col, row) at `level` pixels per page point covers page pixels
/// [col × side, (col + 1) × side) × [row × side, (row + 1) × side).
enum SpikeTiles {
    struct Key: Hashable {
        let level: CGFloat
        let col: Int
        let row: Int
        let side: Int

        /// The tile in page points.
        var rect: CGRect {
            let s = CGFloat(side) / level
            return CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)
        }
    }

    static func keys(covering rect: CGRect, level: CGFloat, side: Int) -> [Key] {
        guard !rect.isNull, !rect.isEmpty else { return [] }
        let s = CGFloat(side) / level
        let c0 = Int((rect.minX / s).rounded(.down)), c1 = Int((rect.maxX / s).rounded(.up)) - 1
        let r0 = Int((rect.minY / s).rounded(.down)), r1 = Int((rect.maxY / s).rounded(.up)) - 1
        guard c0 <= c1, r0 <= r1 else { return [] }
        return (r0 ... r1).flatMap { r in (c0 ... c1).map { Key(level: level, col: $0, row: r, side: side) } }
    }

    static func context(_ key: Key) -> CGContext? {
        CommittedRenderer.makeBitmap(pixelSize: CGSize(width: key.side, height: key.side), scale: 1)
    }

    /// Draws the strokes reaching `key` into `ctx`, a fresh tile bitmap. Returns how many it drew.
    /// With `region` (page points), only that part of the tile is cleared and redrawn: a dirty rect.
    @discardableResult
    static func draw(_ key: Key, page: [CommittedRenderer.Item], grid: SpikeGrid, pieces: SpikePieces? = nil,
                     region: CGRect? = nil, pagePixelHeight: Int? = nil, into ctx: CGContext) -> Int {
        let rect = region.map { $0.intersection(key.rect) } ?? key.rect
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        // A pixel of anti-aliasing at this level, in page points.
        let reach = rect.insetBy(dx: -2 / key.level, dy: -2 / key.level)
        let hits = grid.query(rect.insetBy(dx: -2, dy: -2))
        ctx.saveGState()
        ctx.translateBy(x: -CGFloat(key.col * key.side), y: -CGFloat(key.row * key.side))
        ctx.scaleBy(x: key.level, y: key.level)
        if region != nil {
            ctx.clip(to: rect)
            ctx.clear(rect)
        }
        // The tile's corner is a whole number of pattern tiles from the page's, so the grain lines up.
        if let pagePixelHeight {
            // The pattern is anchored at the bitmap's bottom-left corner in device pixels: move it to where
            // the whole page's bitmap has it, in full, not modulo 64 (a scaled grain's cell isn't 64).
            ctx.setPatternPhase(CGSize(width: -CGFloat(key.col * key.side),
                                       height: -CGFloat(pagePixelHeight - (key.row + 1) * key.side)))
        } else {
            PencilTexture.prepareContext(ctx, phase: .zero)
        }
        var drawn = 0
        for i in hits {
            guard let geometry = page[i].geometry else { continue }
            let clip = geometry.bounds.insetBy(dx: -2, dy: -2)
            guard clip.intersects(rect) else { continue }
            var runs = geometry.runs
            if let pieces {
                runs = pieces.runs(of: i, reaching: reach)
                guard !runs.isEmpty else { continue }
            }
            StrokeRenderer.draw(runs: runs, clip: clip.intersection(reach), brush: page[i].brush,
                                color: page[i].color, in: ctx)
            drawn += 1
        }
        ctx.restoreGState()
        return drawn
    }

    @discardableResult
    static func fill(_ key: Key, page: [CommittedRenderer.Item], grid: SpikeGrid, pieces: SpikePieces?,
                     region: CGRect? = nil) -> Int {
        guard let ctx = context(key) else { return 0 }
        return draw(key, page: page, grid: grid, pieces: pieces, region: region, into: ctx)
    }

    static func render(_ key: Key, page: [CommittedRenderer.Item], grid: SpikeGrid, pieces: SpikePieces?,
                       pagePixelHeight: Int? = nil) -> CGImage? {
        guard let ctx = context(key) else { return nil }
        draw(key, page: page, grid: grid, pieces: pieces, pagePixelHeight: pagePixelHeight, into: ctx)
        return ctx.makeImage()
    }
}

/// Each stroke's runs cut into their subpaths (strips of up to a chunk, and stamps) with bounds, so a
/// tile can fill only the pieces that reach it. Pieces outside a tile add nothing to its pixels under
/// non-zero winding, so the result is the same; what's saved is Core Graphics walking their vertices.
struct SpikePieces: @unchecked Sendable {
    struct Piece {
        let path: CGPath
        let bounds: CGRect
    }

    /// Per stroke, per run: the run's alpha, stamps and pieces.
    private var strokes: [[(run: StrokeRun, pieces: [Piece])]]

    init(_ items: [CommittedRenderer.Item]) {
        strokes = items.map { item in
            (item.geometry?.runs ?? []).map { run in
                var pieces: [Piece] = []
                var current = CGMutablePath()
                run.path.applyWithBlock { element in
                    let e = element.pointee
                    switch e.type {
                    case .moveToPoint:
                        current.move(to: e.points[0])
                    case .addLineToPoint:
                        current.addLine(to: e.points[0])
                    case .closeSubpath:
                        current.closeSubpath()
                        pieces.append(Piece(path: current, bounds: current.boundingBoxOfPath))
                        current = CGMutablePath()
                    default:
                        break
                    }
                }
                if !current.isEmpty {
                    pieces.append(Piece(path: current, bounds: current.boundingBoxOfPath))
                }
                return (run, pieces)
            }
        }
    }

    mutating func remove(at index: Int) {
        strokes.remove(at: index)
    }

    /// Stroke `index`'s runs with only the pieces that reach `rect`; runs with none are left out.
    func runs(of index: Int, reaching rect: CGRect) -> [StrokeRun] {
        strokes[index].compactMap { entry in
            let path = CGMutablePath()
            for piece in entry.pieces where piece.bounds.intersects(rect) {
                path.addPath(piece.path)
            }
            return path.isEmpty ? nil : StrokeRun(path: path, alpha: entry.run.alpha, stamps: entry.run.stamps)
        }
    }
}

/// Strokes drawn with Metal: each run's polygons with stencil-then-cover, into 4× MSAA.
final class SpikeMetal {
    private struct Run {
        let fanStart: Int
        let fanCount: Int
        let coverStart: Int
        let color: SIMD4<Float> // premultiplied
        let blend: BrushDescriptor.BlendMode
        let bounds: CGRect
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let vertices: MTLBuffer
    private let runs: [Run]
    private let stencilPipeline: MTLRenderPipelineState
    private var coverPipelines: [BrushDescriptor.BlendMode: MTLRenderPipelineState] = [:]
    private let stencilWrite: MTLDepthStencilState
    private let stencilCover: MTLDepthStencilState
    let vertexBytes: Int
    let multiRunStrokes: Int

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct SpikeUniforms { float2 scale; float2 offset; float4 color; };
    vertex float4 spikeVertex(uint vid [[vertex_id]], const device float2 *pos [[buffer(0)]],
                              constant SpikeUniforms &u [[buffer(1)]]) {
        return float4(pos[vid] * u.scale + u.offset, 0, 1);
    }
    fragment float4 spikeFragment(constant SpikeUniforms &u [[buffer(1)]]) { return u.color; }
    """

    private struct Uniforms {
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
        var color: SIMD4<Float>
    }

    init?(_ items: [CommittedRenderer.Item]) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil)
        else { return nil }
        self.device = device
        self.queue = queue
        var points: [SIMD2<Float>] = []
        var runs: [Run] = []
        var multi = 0
        for item in items {
            guard let geometry = item.geometry else { continue }
            if geometry.runs.count > 1 {
                multi += 1
            }
            for run in geometry.runs {
                let fanStart = points.count
                for contour in Self.contours(of: run.path) where contour.count >= 3 {
                    for i in 1 ..< contour.count - 1 {
                        points += [contour[0], contour[i], contour[i + 1]]
                    }
                }
                let fanCount = points.count - fanStart
                let b = run.path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
                let corners = [SIMD2(Float(b.minX), Float(b.minY)), SIMD2(Float(b.maxX), Float(b.minY)),
                               SIMD2(Float(b.minX), Float(b.maxY)), SIMD2(Float(b.maxX), Float(b.maxY))]
                let coverStart = points.count
                points += [corners[0], corners[1], corners[2], corners[1], corners[3], corners[2]]
                let a = Float(item.color.a * run.alpha)
                let color = SIMD4(Float(item.color.r) * a, Float(item.color.g) * a, Float(item.color.b) * a, a)
                runs.append(Run(fanStart: fanStart, fanCount: fanCount, coverStart: coverStart, color: color,
                                blend: item.brush.blend, bounds: b))
            }
        }
        vertexBytes = points.count * MemoryLayout<SIMD2<Float>>.stride
        guard let vertices = points.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared)
        }) else { return nil }
        self.vertices = vertices
        self.runs = runs
        multiRunStrokes = multi

        func pipeline(_ configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "spikeVertex")
            d.fragmentFunction = library.makeFunction(name: "spikeFragment")
            d.rasterSampleCount = Self.samples
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float_stencil8
            d.stencilAttachmentPixelFormat = .depth32Float_stencil8
            configure(d.colorAttachments[0])
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let stencil = pipeline({ $0.writeMask = [] }) else { return nil }
        stencilPipeline = stencil
        for blend in BrushDescriptor.BlendMode.allCases {
            coverPipelines[blend] = pipeline { a in
                a.isBlendingEnabled = true
                switch blend {
                case .normal:
                    a.sourceRGBBlendFactor = .one
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                case .multiply: // src × dst + dst × (1 − src α): drops CG's src × (1 − dst α) term
                    a.sourceRGBBlendFactor = .destinationColor
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                case .destinationOut:
                    a.sourceRGBBlendFactor = .zero
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                }
                a.sourceAlphaBlendFactor = blend == .destinationOut ? .zero : .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        }

        let write = MTLDepthStencilDescriptor()
        let front = MTLStencilDescriptor(), back = MTLStencilDescriptor()
        front.depthStencilPassOperation = .incrementWrap
        back.depthStencilPassOperation = .decrementWrap
        write.frontFaceStencil = front
        write.backFaceStencil = back
        let cover = MTLDepthStencilDescriptor()
        let test = MTLStencilDescriptor()
        test.stencilCompareFunction = .notEqual
        test.depthStencilPassOperation = .zero
        cover.frontFaceStencil = test
        cover.backFaceStencil = test
        guard let w = device.makeDepthStencilState(descriptor: write), let c = device.makeDepthStencilState(descriptor: cover)
        else { return nil }
        stencilWrite = w
        stencilCover = c
    }

    static let samples = 4

    /// A path made of `addLines` polygons as point lists, in page space.
    private static func contours(of path: CGPath) -> [[SIMD2<Float>]] {
        var result: [[SIMD2<Float>]] = []
        var current: [SIMD2<Float>] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if !current.isEmpty {
                    result.append(current)
                }
                current = [SIMD2(Float(e.points[0].x), Float(e.points[0].y))]
            case .addLineToPoint:
                current.append(SIMD2(Float(e.points[0].x), Float(e.points[0].y)))
            case .addQuadCurveToPoint:
                current.append(SIMD2(Float(e.points[1].x), Float(e.points[1].y)))
            case .addCurveToPoint:
                current.append(SIMD2(Float(e.points[2].x), Float(e.points[2].y)))
            case .closeSubpath:
                if !current.isEmpty {
                    result.append(current)
                }
                current = []
            @unknown default:
                break
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    struct Timing {
        let encode: Double
        let total: Double
    }

    private struct Targets {
        let msaa: MTLTexture
        let stencil: MTLTexture
        let resolve: MTLTexture
    }

    private var targetCache: [Int: Targets] = [:]

    /// The MSAA colour, stencil and resolve textures for a size, made once (allocation isn't what's timed).
    private func targets(width: Int, height: Int) -> Targets? {
        if let cached = targetCache[width << 20 | height] {
            return cached
        }
        func texture(_ format: MTLPixelFormat, samples: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                             mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.storageMode = .private
            d.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: d)
        }
        guard let msaa = texture(.bgra8Unorm, samples: Self.samples),
              let stencil = texture(.depth32Float_stencil8, samples: Self.samples),
              let resolve = texture(.bgra8Unorm, samples: 1)
        else { return nil }
        let made = Targets(msaa: msaa, stencil: stencil, resolve: resolve)
        targetCache[width << 20 | height] = made
        return made
    }

    /// Encodes the page at `transform` (view points, at the benchmark's display scale) into a target of the
    /// given pixel size; `readback`, when given, receives the resolved pixels.
    private func encode(transform: ViewTransform, width: Int, height: Int, into commands: MTLCommandBuffer,
                        readback: MTLBuffer?) -> Bool {
        guard let targets = targets(width: width, height: height) else { return false }
        let msaa = targets.msaa, stencil = targets.stencil, resolve = targets.resolve
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.stencilAttachment.texture = stencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        pass.depthAttachment.texture = stencil
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let ds = Float(Bench.displayScale)
        let scale = SIMD2(2 * Float(transform.scale) * ds / Float(width), -2 * Float(transform.scale) * ds / Float(height))
        let offset = SIMD2(2 * Float(transform.offset.x) * ds / Float(width) - 1,
                           1 - 2 * Float(transform.offset.y) * ds / Float(height))
        let visible = transform.toCanvas(CGRect(x: 0, y: 0, width: CGFloat(width) / CGFloat(ds),
                                                height: CGFloat(height) / CGFloat(ds)))
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        for run in runs where run.bounds.intersects(visible) && run.fanCount > 0 {
            var u = Uniforms(scale: scale, offset: offset, color: run.color)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setRenderPipelineState(stencilPipeline)
            encoder.setDepthStencilState(stencilWrite)
            encoder.drawPrimitives(type: .triangle, vertexStart: run.fanStart, vertexCount: run.fanCount)
            encoder.setRenderPipelineState(coverPipelines[run.blend]!)
            encoder.setDepthStencilState(stencilCover)
            encoder.setStencilReferenceValue(0)
            encoder.drawPrimitives(type: .triangle, vertexStart: run.coverStart, vertexCount: 6)
        }
        encoder.endEncoding()
        if let readback, let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: resolve, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                      destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
            blit.endEncoding()
        }
        return true
    }

    /// Draws the page and waits for the GPU; times encoding and the whole draw, in milliseconds.
    func draw(transform: ViewTransform, pixelWidth: Int, pixelHeight: Int) -> Timing? {
        let start = Bench.now()
        guard let commands = queue.makeCommandBuffer(),
              encode(transform: transform, width: pixelWidth, height: pixelHeight, into: commands, readback: nil)
        else { return nil }
        let encoded = Bench.milliseconds(since: start)
        commands.commit()
        commands.waitUntilCompleted()
        return Timing(encode: encoded, total: Bench.milliseconds(since: start))
    }

    /// The page drawn at `transform`, as an image laid out like `CommittedRenderer.makeBitmap`'s.
    func image(transform: ViewTransform, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let buffer = device.makeBuffer(length: pixelWidth * pixelHeight * 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(),
              encode(transform: transform, width: pixelWidth, height: pixelHeight, into: commands, readback: buffer)
        else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        let data = Data(bytes: buffer.contents(), count: buffer.length)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pixelWidth * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CommittedRenderer.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The fraction of pixels with a channel more than `over` (of 255) apart.
    static func differingFraction(_ a: CGImage, _ b: CGImage, over: Int) -> Double {
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data?, da.count == db.count
        else { return 1 }
        var differing = 0
        da.withUnsafeBytes { pa in
            db.withUnsafeBytes { pb in
                let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
                var i = 0
                while i + 3 < x.count {
                    for c in 0 ..< 4 where abs(Int(x[i + c]) - Int(y[i + c])) > over {
                        differing += 1
                        break
                    }
                    i += 4
                }
            }
        }
        return Double(differing) / Double(a.width * a.height)
    }
}
