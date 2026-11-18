import CoreGraphics
import Foundation
@testable import InkKit
import UIKit
import XCTest

/// Ink performance benchmarks and latency budgets (Architecture §6).
///
/// Every benchmark runs InkKit's own code paths on input replayed from `Fixtures/` and records its
/// numbers, with their budgets, through `BenchResults`. Run them with
/// `-configuration Release ENABLE_TESTABILITY=YES` (see the README). The nightly CI job compares the results
/// with a stored baseline (`scripts/bench-compare.py`) and fails on a regression of more than 10%, or when a
/// budget the baseline met is missed. Set `INK_BENCH_ENFORCE_BUDGETS=1` to also fail here on any budget.
@MainActor
final class InkBenchmarks: XCTestCase {
    /// Page open: under 150 ms for a 5k-stroke page.
    static let pageOpenBudgetMs = 150.0
    /// Live-stroke work per touch event: under 2 ms (asserted on the 95th percentile).
    static let liveEventBudgetMs = 2.0
    /// `.ink` file for a 5k-stroke page: under 1 MB, decoded in under 50 ms (NOT-5).
    static let inkFileBudgetKB = 1024.0
    static let inkDecodeBudgetMs = 50.0
    /// A 5k-stroke page open at 6× while writing: its geometry, the screen's bitmap and the live layer (NOT-108).
    static let memory6xBudgetMB = 80.0

    private var corpus: Corpus {
        Corpus.shared
    }

    override func setUp() async throws {
        try await super.setUp()
        let empty = await MainActor.run { Corpus.shared.strokes.isEmpty }
        if empty {
            XCTFail("No recordings in Fixtures/: the benchmarks have no input")
        }
    }

    private func check(_ value: Double, under budget: Double, _ what: String) {
        guard Bench.optimized, ProcessInfo.processInfo.environment["INK_BENCH_ENFORCE_BUDGETS"] == "1" else { return }
        XCTAssertLessThan(value, budget, "\(what): \(value) ms is over the \(budget) ms budget")
    }

    /// Runs `body` under `measure` (so Xcode shows it) `iterations` + 1 times and returns the wall time of
    /// each iteration after the first, in milliseconds.
    private func timed(iterations: Int = Bench.iterations, _ body: () -> Void) -> [Double] {
        var times: [Double] = []
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        measure(metrics: [XCTClockMetric()], options: options) {
            let start = Bench.now()
            body()
            times.append(Bench.milliseconds(since: start))
        }
        return Array(times.dropFirst())
    }

    // MARK: Stroke geometry

    /// Builds the outline geometry (spline, nib hulls, runs) of every stroke in the corpus from scratch,
    /// as opening a page does for each stroke.
    func testStrokeGeometryBuild() {
        let strokes = corpus.strokes
        let times = timed {
            for stroke in strokes {
                _ = StrokeRenderer.geometry(for: stroke)
            }
        }
        let stats = Stats(times)
        BenchResults.record("stroke_geometry.corpus_ms", stats.median, unit: "ms")
        BenchResults.record("stroke_geometry.per_stroke_us", stats.median * 1000 / Double(strokes.count), unit: "us")
    }

    // MARK: Live stroke

    /// Replays every recorded stroke through `LiveStroke` and a full-screen `LiveInkView` at the fitted
    /// zoom, timing each touch event: appending its samples, finalizing segments, rebuilding the predicted
    /// tail, applying estimate updates, then drawing the dirty tiles.
    func testLiveStrokeAppend() {
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let replayer = InputReplayer(viewSize: Bench.screen, transform: transform, displayScale: Bench.displayScale)
        var events: [Double] = []
        var iteration = 0
        measure(metrics: [XCTClockMetric()], options: Bench.measureOptions) {
            defer { iteration += 1 }
            for recorded in corpus.recordedStrokes {
                var last = Bench.now()
                replayer.replay(recorded, transform: transform) { _ in
                    let now = Bench.now()
                    if iteration > 0 {
                        events.append(Double(now - last) / 1_000_000)
                    }
                    last = now
                }
            }
        }
        let stats = Stats(events)
        BenchResults.record("live_event.p50_ms", stats.median, unit: "ms")
        BenchResults.record("live_event.p95_ms", stats.p95, unit: "ms", budget: Self.liveEventBudgetMs)
        BenchResults.record("live_event.p99_ms", stats.p99, unit: "ms")
        check(stats.p95, under: Self.liveEventBudgetMs, "Live-stroke work per touch event (p95)")
    }

    /// The longest recorded stroke (the tilted shading scribble), replayed alone. Per-event work must not
    /// grow with stroke length, so the last quarter of its events is held to the same budget as the first.
    func testLiveStrokeAppendLongStroke() throws {
        let recorded = try XCTUnwrap(corpus.longestStroke)
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let replayer = InputReplayer(viewSize: Bench.screen, transform: transform, displayScale: Bench.displayScale)
        let count = recorded.events.count
        var first: [Double] = []
        var lastQuarter: [Double] = []
        var iteration = 0
        measure(metrics: [XCTClockMetric()], options: Bench.measureOptions) {
            defer { iteration += 1 }
            var last = Bench.now()
            replayer.replay(recorded, transform: transform) { n in
                let now = Bench.now()
                let ms = Double(now - last) / 1_000_000
                last = now
                guard iteration > 0 else { return }
                if n < count / 4 {
                    first.append(ms)
                } else if n >= count * 3 / 4 {
                    lastQuarter.append(ms)
                }
            }
        }
        let early = Stats(first), late = Stats(lastQuarter)
        BenchResults.record("live_event.long_stroke.first_quarter_p95_ms", early.p95, unit: "ms")
        BenchResults.record("live_event.long_stroke.last_quarter_p95_ms", late.p95, unit: "ms",
                            budget: Self.liveEventBudgetMs)
        check(late.p95, under: Self.liveEventBudgetMs, "Live-stroke work late in a long stroke (p95)")
    }

    // MARK: Stamp brushes

    /// The stamp path's benchmark brush (NOT-16): a dry brush, with bristles and every kind of jitter,
    /// sized from each recorded stroke's width. Held to the live budget like any brush (NOT-110).
    static func stampBrush(width: CGFloat) -> BrushDescriptor {
        BrushDescriptor(name: "Benchmark Dry Brush", size: width * 0.5 ... width * 2,
                        texture: .bristle(count: 8, spread: 0.9), spacing: 0.3,
                        jitter: .init(size: 0.3, angle: 0.2, scatter: 0.1, opacity: 0.4, seed: 1))
    }

    /// `testStrokeGeometryBuild` with every corpus stroke drawn with the stamp brush.
    func testStampBrushGeometryBuild() {
        let strokes = corpus.strokes.map { stroke in
            var stroke = stroke
            stroke.brush = Self.stampBrush(width: stroke.brush.maxWidth)
            return stroke
        }
        let times = timed {
            for stroke in strokes {
                _ = StrokeRenderer.geometry(for: stroke)
            }
        }
        let stats = Stats(times)
        BenchResults.record("stroke_geometry.stamp.corpus_ms", stats.median, unit: "ms")
        BenchResults.record("stroke_geometry.stamp.per_stroke_us", stats.median * 1000 / Double(strokes.count),
                            unit: "us")
    }

    /// `testLiveStrokeAppend` with every recorded stroke drawn with the stamp brush.
    func testStampBrushLiveStroke() {
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let replayer = InputReplayer(viewSize: Bench.screen, transform: transform, displayScale: Bench.displayScale)
        let recordings = corpus.recordedStrokes.map { recorded in
            var recorded = recorded
            recorded.brush = Self.stampBrush(width: CGFloat(recorded.style.width))
            return recorded
        }
        var events: [Double] = []
        var iteration = 0
        measure(metrics: [XCTClockMetric()], options: Bench.measureOptions) {
            defer { iteration += 1 }
            for recorded in recordings {
                var last = Bench.now()
                replayer.replay(recorded, transform: transform) { _ in
                    let now = Bench.now()
                    if iteration > 0 {
                        events.append(Double(now - last) / 1_000_000)
                    }
                    last = now
                }
            }
        }
        let stats = Stats(events)
        BenchResults.record("live_event.stamp.p50_ms", stats.median, unit: "ms")
        BenchResults.record("live_event.stamp.p95_ms", stats.p95, unit: "ms", budget: Self.liveEventBudgetMs)
        BenchResults.record("live_event.stamp.p99_ms", stats.p99, unit: "ms", budget: Self.liveEventBudgetMs)
        check(stats.p95, under: Self.liveEventBudgetMs, "Live-stroke work per touch event with a stamp brush (p95)")
    }

    // MARK: Raster brush

    /// `testLiveStrokeAppend` with every recorded stroke drawn with the crayon (NOT-93), a raster brush. The
    /// live layer only encodes GPU work for each event and doesn't wait for it (`LiveInkView.requestWax`),
    /// so after each event the main queue is drained, as the app's run loop would: the event's time
    /// includes copying back whatever wax the GPU has finished, but not waiting for it. How long the GPU
    /// takes to send wax back is recorded on its own (`live_event.crayon.wax_latency_*`).
    func testCrayonLiveStroke() throws {
        let wax = try XCTUnwrap(WaxRenderer.shared, "no Metal device")
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let replayer = InputReplayer(viewSize: Bench.screen, transform: transform, displayScale: Bench.displayScale)
        let recordings = corpus.recordedStrokes.map { recorded in
            var recorded = recorded
            recorded.brush = Self.crayon(width: CGFloat(recorded.style.width))
            return recorded
        }
        var events: [Double] = []
        var latencies: [Double] = []
        wax.latencyObserver = { latencies.append($0) }
        defer { wax.latencyObserver = nil }
        var iteration = 0
        measure(metrics: [XCTClockMetric()], options: Bench.measureOptions) {
            defer { iteration += 1 }
            for recorded in recordings {
                var last = Bench.now()
                replayer.replay(recorded, transform: transform) { _ in
                    RunLoop.main.run(until: Date())
                    let now = Bench.now()
                    if iteration > 0 {
                        events.append(Double(now - last) / 1_000_000)
                    }
                    last = now
                }
                Self.drain(replayer.liveView)
            }
        }
        XCTAssertFalse(latencies.isEmpty, "no wax came back from the GPU during the replay")
        let stats = Stats(events), latency = Stats(latencies)
        BenchResults.record("live_event.crayon.p50_ms", stats.median, unit: "ms")
        BenchResults.record("live_event.crayon.p95_ms", stats.p95, unit: "ms", budget: Self.liveEventBudgetMs)
        BenchResults.record("live_event.crayon.p99_ms", stats.p99, unit: "ms")
        BenchResults.record("live_event.crayon.wax_latency_p50_ms", latency.median, unit: "ms")
        BenchResults.record("live_event.crayon.wax_latency_p95_ms", latency.p95, unit: "ms")
        check(stats.p95, under: Self.liveEventBudgetMs, "Crayon live-stroke work per touch event (p95)")
    }

    /// The longest recorded stroke drawn with the crayon: its tiles keep their settled pressure on the GPU,
    /// so each event's work must not grow with the stroke's length.
    func testCrayonLiveStrokeLongStroke() throws {
        var recorded = try XCTUnwrap(corpus.longestStroke)
        recorded.brush = Self.crayon(width: CGFloat(recorded.style.width))
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let replayer = InputReplayer(viewSize: Bench.screen, transform: transform, displayScale: Bench.displayScale)
        let count = recorded.events.count
        var first: [Double] = []
        var lastQuarter: [Double] = []
        var iteration = 0
        measure(metrics: [XCTClockMetric()], options: Bench.measureOptions) {
            defer { iteration += 1 }
            var last = Bench.now()
            replayer.replay(recorded, transform: transform) { n in
                RunLoop.main.run(until: Date())
                let now = Bench.now()
                let ms = Double(now - last) / 1_000_000
                last = now
                guard iteration > 0 else { return }
                if n < count / 4 {
                    first.append(ms)
                } else if n >= count * 3 / 4 {
                    lastQuarter.append(ms)
                }
            }
            Self.drain(replayer.liveView)
        }
        let early = Stats(first), late = Stats(lastQuarter)
        BenchResults.record("live_event.crayon.long_stroke.first_quarter_p95_ms", early.p95, unit: "ms")
        BenchResults.record("live_event.crayon.long_stroke.last_quarter_p95_ms", late.p95, unit: "ms",
                            budget: Self.liveEventBudgetMs)
        check(late.p95, under: Self.liveEventBudgetMs, "Crayon live-stroke work late in a long stroke (p95)")
    }

    /// Lets the GPU work of the last stroke finish (untimed), so it doesn't spill into the next one.
    private static func drain(_ view: LiveInkView) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while view.rasterWorkPending, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }

    /// The crayon at a recorded stroke's width.
    static func crayon(width: CGFloat) -> BrushDescriptor {
        BrushDescriptor.crayon.personalized(width: width, minimumWidthRatio: BrushDescriptor.neutralMinimumWidthRatio,
                                            pressureExponent: BrushDescriptor.neutralPressureExponent, tilt: true)
    }

    /// Filling every tile of a fitted page of 500 crayon strokes, geometry cached, on every core: a new
    /// level near the fitted zoom, one GPU pass per stroke and tile. No budget: a page reopened restores
    /// its `TileRaster`, and an edit refills only what it reached.
    func testCrayonPageRedraw() {
        let page = corpus.distinctPage(strokes: 500).map { stroke in
            var stroke = stroke
            stroke.brush = Self.crayon(width: stroke.brush.maxWidth)
            return stroke
        }
        let ink = snapshot(page, geometry: StrokeRenderer.geometries(for: page))
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let times = timed(iterations: 5) {
            _ = screenTiles(of: ink, at: transform)
        }
        BenchResults.record("full_redraw.crayon_500_ms", Stats(times).median, unit: "ms")
    }

    /// `strokes` and their geometry as a tile fill takes them.
    private func snapshot(_ strokes: [Stroke], geometry: [StrokeGeometry]) -> InkSnapshot {
        InkSnapshot(strokes: strokes, index: StrokeIndex(strokes: strokes),
                    geometry: Dictionary(uniqueKeysWithValues: zip(strokes.map(\.id), geometry)), skipped: [])
    }

    /// The tiles of the corpus page in view of the screen at `transform`, filled from `ink` on every core,
    /// all at once (the canvas's jobs, without the scheduler's limits).
    private func screenTiles(of ink: InkSnapshot, at transform: ViewTransform) -> [(key: TileKey, image: CGImage?)] {
        let level = TileLevel(transform, displayScale: Bench.displayScale)
        let keys = TileKey.keys(covering: transform.toCanvas(Bench.screenBounds).intersection(corpus.pageSize.bounds),
                                page: UUID(), level: level)
        var images = [CGImage?](repeating: nil, count: keys.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            let image = RenderCoordinator.draw(keys[i], from: ink, revision: 1, filler: CoreGraphicsTileFiller()).image
            lock.withLock { images[i] = image }
        }
        return Array(zip(keys, images)).map { (key: $0.0, image: $0.1) }
    }

    // MARK: Page open

    /// Opening a page the canvas has shown before, in this launch or an earlier one, once the tile cache
    /// has let its tiles go (or never had them): the page's `TileRaster` (its fitted-level tiles,
    /// compressed) read from the file an app keeps it in (mapped, as `DocumentStore` reads it), then
    /// decompressed tile by tile, exactly as the canvas's render jobs do instead of filling them. This is
    /// the budgeted page open; with the tiles still cached, opening fills and restores nothing.
    func testPageOpen5k() throws {
        let (tiles, level) = try fittedTiles(strokes: 5000)
        let saved = try XCTUnwrap(TileRaster(tiles: tiles, revision: 1, level: level, pageSize: corpus.pageSize.size))
        let url = FileManager.default.temporaryDirectory.appending(path: "page-open-\(UUID().uuidString).tiles")
        try saved.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var restored: [Tile?] = []
        let times = timed {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                  let raster = TileRaster(data: data, revision: 0)
            else { return XCTFail("The kept tiles didn't read back") }
            restored = tiles.map { key, _ in raster.holds(key) ? raster.restore(key) : nil }
        }
        for ((_, image), tile) in zip(tiles, restored) {
            XCTAssertEqual(tile?.image?.dataProvider?.data as Data?, image?.dataProvider?.data as Data?,
                           "The reopened page must be pixel for pixel the page that was shown")
        }
        BenchResults.record("page_open.5k_ms", Stats(times).median, unit: "ms", budget: Self.pageOpenBudgetMs)
        check(Stats(times).median, under: Self.pageOpenBudgetMs, "Page open with 5000 strokes (median)")
    }

    /// Leaving a page: compressing the 5k-stroke page's fitted-level tiles into its `TileRaster`. Runs in
    /// the background after the page closes, so it has no budget, but it bounds how soon a page reopened
    /// straight away (and evicted from the cache) can be restored rather than drawn. Leaving it again after
    /// an edit compresses only the tiles the edit reached; the rest are carried over.
    func testPageRasterCapture5k() throws {
        let (tiles, level) = try fittedTiles(strokes: 5000)
        var raster: TileRaster?
        let times = timed(iterations: 3) {
            raster = TileRaster(tiles: tiles, revision: 1, level: level, pageSize: corpus.pageSize.size)
        }
        let saved = try XCTUnwrap(raster)
        BenchResults.record("page_raster.capture_5k_ms", Stats(times).median, unit: "ms")
        BenchResults.record("page_raster.5k_kb", Double(saved.byteCount) / 1024, unit: "KB")
    }

    /// A page of `count` strokes as the fitted canvas's tiles, filled on every core.
    private func fittedTiles(strokes count: Int) throws -> ([(key: TileKey, image: CGImage?)], TileLevel) {
        let page = corpus.page(strokes: count)
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let tiles = screenTiles(of: snapshot(page, geometry: StrokeRenderer.geometries(for: page)), at: transform)
        return (tiles, TileLevel(transform, displayScale: Bench.displayScale))
    }

    /// Opening a page with no raster to restore (the first time it's ever shown): every stroke's geometry
    /// built (nothing is kept yet) and every tile of the fitted page filled, on every core. The canvas does
    /// the same through the scheduler, which keeps a core back and builds only the geometry its tiles
    /// reach (`scroll.page_enter_first_5k_ms` times that through a real canvas).
    private func pageOpenCold(strokes count: Int, iterations: Int) {
        let page = corpus.page(strokes: count)
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let times = timed(iterations: iterations) {
            _ = screenTiles(of: snapshot(page, geometry: StrokeRenderer.geometries(for: page)), at: transform)
        }
        BenchResults.record("page_open_cold.\(count / 1000)k_ms", Stats(times).median, unit: "ms")
    }

    func testPageOpenCold1k() {
        pageOpenCold(strokes: 1000, iterations: 5)
    }

    func testPageOpenCold5k() {
        pageOpenCold(strokes: 5000, iterations: 3)
    }

    func testPageOpenCold20k() {
        pageOpenCold(strokes: 20000, iterations: 2)
    }

    // MARK: Ink file

    /// Saving a 5k-stroke page's ink in the `.ink` format (NOT-5): the encoded size, and the encode time
    /// (on save, off the main actor). The page's copies of the corpus are each stretched a little, so the
    /// compressor can't shrink the page by matching one copy against the last, as it would on the tiled page.
    func testInkFileEncode5k() {
        let strokes = corpus.distinctPage(strokes: 5000)
        let points = strokes.reduce(0) { $0 + $1.points.count }
        let file = InkPageFile(pageID: UUID(), strokes: strokes)
        var data = Data()
        let times = timed(iterations: 5) { data = file.encoded() }
        BenchResults.record("ink_file.5k_kb", Double(data.count) / 1024, unit: "KB", budget: Self.inkFileBudgetKB)
        BenchResults.record("ink_file.bytes_per_point", Double(data.count) / Double(points), unit: "B")
        BenchResults.record("ink_file.encode_5k_ms", Stats(times).median, unit: "ms")
    }

    /// Reading that page back: decompressing and parsing every stroke, as opening a page will once NOT-6
    /// reads ink from disk (when it joins `page_open`).
    func testInkFileDecode5k() {
        let data = InkPageFile(pageID: UUID(), strokes: corpus.distinctPage(strokes: 5000)).encoded()
        var decoded: InkPageFile?
        let times = timed { decoded = try? InkPageFile(data: data) }
        XCTAssertEqual(decoded?.strokeCount, 5000)
        XCTAssertEqual(decoded?.encoded(), data, "Re-encoding a decoded page must give the same bytes")
        BenchResults.record("ink_file.decode_5k_ms", Stats(times).median, unit: "ms", budget: Self.inkDecodeBudgetMs)
        check(Stats(times).median, under: Self.inkDecodeBudgetMs, "Decoding a 5000-stroke page (median)")
    }

    // MARK: Full-page redraw

    /// Filling every tile of a fitted 5k-stroke page with every stroke's geometry cached, on every core:
    /// what a new zoom level near the fitted one costs (the canvas fills it progressively, centre-out, over
    /// the scaled tiles of the last). Undo, erase and pans no longer redraw the page (NOT-102, NOT-104).
    func testFullPageRedraw5k() {
        let page = corpus.page(strokes: 5000)
        let ink = snapshot(page, geometry: StrokeRenderer.geometries(for: page))
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let times = timed(iterations: 3) {
            _ = screenTiles(of: ink, at: transform)
        }
        BenchResults.record("full_redraw.5k_ms", Stats(times).median, unit: "ms")
    }

    // MARK: Stroke index

    /// Building a 20k-stroke page's `StrokeIndex` from scratch, as opening it does (off the main actor).
    func testStrokeIndexBuild20k() {
        let page = corpus.page(strokes: 20000)
        var index: StrokeIndex?
        let times = timed(iterations: 5) {
            index = StrokeIndex(strokes: page)
        }
        XCTAssertEqual(index?.strokeCount, 20000)
        BenchResults.record("index.build_20k_ms", Stats(times).median, unit: "ms")
    }

    /// A tile-sized query (128 pt, a 256-pixel tile at 2×) costs the same on a 5k-stroke page and on a
    /// 20k-stroke one holding the same 5k strokes plus 15k elsewhere: it depends on what's near, not on the
    /// page's size. A scan of every stroke's rect, what culling did before the index, is there to compare.
    func testStrokeIndexTileQuery() {
        let near = corpus.page(strokes: 5000)
        let far = corpus.page(strokes: 15000).map { $0.applying(CGAffineTransform(translationX: 0, y: 5000)) }
        let size = corpus.pageSize
        let tiles = stride(from: 0, to: size.height, by: 128).flatMap { y in
            stride(from: 0, to: size.width, by: 128).map { x in CGRect(x: x, y: y, width: 128, height: 128) }
        }
        // Timed by hand: `measure` can run only once per test, and this times three things.
        func perQuery(_ body: (CGRect) -> Int) -> Double {
            var found = 0, times: [Double] = []
            for _ in 0 ..< Bench.iterations + 1 {
                let start = Bench.now()
                for _ in 0 ..< 10 {
                    for tile in tiles {
                        found &+= body(tile)
                    }
                }
                times.append(Bench.milliseconds(since: start))
            }
            XCTAssertGreaterThan(found, 0)
            return Stats(Array(times.dropFirst())).median * 1000 / Double(10 * tiles.count)
        }
        let index5k = StrokeIndex(strokes: near), index20k = StrokeIndex(strokes: near + far)
        let reaches20k = (near + far).map(StrokeIndex.reach(of:))
        BenchResults.record("index.query_tile_5k_us", perQuery { index5k.strokes(in: $0).count }, unit: "us")
        BenchResults.record("index.query_tile_20k_us", perQuery { index20k.strokes(in: $0).count }, unit: "us")
        BenchResults.record("index.scan_tile_20k_us", perQuery { tile in
            reaches20k.reduce(0) { $0 + ($1.intersects(tile) ? 1 : 0) }
        }, unit: "us")
        // The whole page (the fitted page's query), which walks the strokes instead of the cells.
        let page = size.bounds
        BenchResults.record("index.query_page_5k_us", perQuery { _ in index5k.strokes(in: page).count }, unit: "us")
    }

    // MARK: Memory

    /// Memory with a 5k-stroke page open at 6× zoom (the maximum) while writing: the page's stroke geometry,
    /// the tiles in view filled at 6×, and the live layer's tiles and baked tile bitmaps as the corpus is
    /// replayed on top. Peak footprint over the baseline before the page was opened.
    ///
    /// The geometry is every stroke's, built once as filling the whole fitted page does, and kept as the page
    /// keeps it (NOT-108): packed, in an app-wide cache under `GeometryCache.shared`'s budget
    /// (`geometry_packed_mb` is what that budget counts). `geometry_mb` is the heap it holds; before NOT-108
    /// every canvas kept every stroke's `CGPath`s, ~295 MB of heap (108 MB by the footprint this measured
    /// then). The footprint baseline is taken with free memory handed back first, so the earlier benchmarks'
    /// leftovers can't be reused and make the page look cheaper than it is.
    func testMemoryAt6xZoom() {
        let page = corpus.page(strokes: 5000)
        let before = Bench.settledFootprint()
        let heapBefore = Bench.heapInUse()
        var peak = before

        let cache = GeometryCache(budget: GeometryCache.shared.budget,
                                  unpackedBudget: GeometryCache.shared.unpackedBudget)
        let geometry = PageGeometry(cache: cache)
        for stroke in page {
            _ = geometry.geometry(for: stroke)
        }
        let geometryBytes = Bench.heapInUse().subtractingClamped(heapBefore)
        peak = max(peak, Bench.footprint())

        let box = corpus.inkBounds
        let transform = Bench.zoomedTransform(for: corpus.pageSize, zoom: ViewTransform.maxZoomFactor,
                                              centredOn: CGPoint(x: box.midX, y: box.midY))
        // The tiles in view filled, from the strokes in view unpacked to draw, as the canvas fills them.
        let inView = transform.toCanvas(Bench.screenBounds)
        let shown = page.filter { geometry.bounds(for: $0).intersects(inView) }
        let tiles = screenTiles(of: snapshot(shown, geometry: shown.map { geometry.geometry(for: $0) }), at: transform)
        peak = max(peak, Bench.footprint())

        let replayer = InputReplayer(viewSize: Bench.screen, transform: transform, displayScale: Bench.displayScale)
        var tilesPeak = 0
        for recorded in corpus.recordedStrokes {
            replayer.replay(recorded, transform: transform) { _ in
                tilesPeak = max(tilesPeak, replayer.liveView.tileMemory)
                peak = max(peak, Bench.footprint())
            }
        }
        XCTAssertTrue(tiles.contains { $0.image != nil })

        let mb = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        BenchResults.record("memory.6x.peak_mb", mb(peak.subtractingClamped(before)), unit: "MB",
                            budget: Self.memory6xBudgetMB)
        BenchResults.record("memory.6x.geometry_mb", mb(geometryBytes), unit: "MB")
        BenchResults.record("memory.6x.geometry_packed_mb", mb(UInt64(cache.byteCount)), unit: "MB")
        BenchResults.record("memory.6x.geometry_unpacked_mb", mb(UInt64(cache.unpackedByteCount)), unit: "MB")
        BenchResults.record("memory.6x.live_tiles_peak_mb", mb(UInt64(tilesPeak)), unit: "MB")
        withExtendedLifetime((geometry, tiles)) {}
    }
}

/// Regenerates the synthetic fixture. Skipped unless `INK_BENCH_WRITE_FIXTURE` names the file to write:
///
///     TEST_RUNNER_INK_BENCH_WRITE_FIXTURE=$PWD/Tests/InkKitBenchmarks/Fixtures/handwriting.synthetic.inkrec.json \
///       xcodebuild test -scheme InkKit -only-testing:InkKitBenchmarks/FixtureGeneration …
///
/// Changing the fixture changes every number, so record new baselines in the same change.
@MainActor
final class FixtureGeneration: XCTestCase {
    func testWriteSyntheticFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["INK_BENCH_WRITE_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set INK_BENCH_WRITE_FIXTURE to regenerate the synthetic fixture")
        }
        let scale = Double(Bench.fittedTransform(for: .letter).scale)
        let recording = SyntheticPencil.handwriting(viewScale: scale)
        try recording.encoded().write(to: URL(fileURLWithPath: path))
        let samples = recording.strokes.reduce(0) { $0 + $1.events.reduce(0) { $0 + ($1.samples?.count ?? 0) } }
        print("[inkbench] wrote \(recording.strokes.count) strokes, \(samples) samples to \(path)")
    }

    /// Renders every fixture as committed to `<INK_BENCH_PREVIEW_DIR>/<fixture>.png`, to eyeball the input.
    func testWriteFixturePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["INK_BENCH_PREVIEW_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set INK_BENCH_PREVIEW_DIR to render previews of the fixtures")
        }
        for (n, recording) in Corpus.shared.recordings.enumerated() {
            let doc = CanvasDocument(pageSize: recording.pageSize)
            for recorded in recording.strokes {
                doc.add(recorded.committedStroke())
            }
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let image = try XCTUnwrap(PageRenderer.image(of: doc.snapshot(), pixelWidth: 1224) { ctx, size in
                ctx.setFillColor(white)
                ctx.fill(CGRect(origin: .zero, size: size))
            })
            let png = try XCTUnwrap(UIImage(cgImage: image).pngData())
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("fixture-\(n).png"))
        }
    }
}
