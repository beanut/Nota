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

    // MARK: Page open

    /// Opening a page: a fresh screen-sized committed bitmap, every stroke's geometry built (nothing is
    /// cached yet), and the whole page drawn at the fitted zoom, exactly as `CanvasView`'s first full
    /// render. Ink isn't stored on disk yet; decoding joins this measurement when it is.
    private func pageOpen(strokes count: Int, iterations: Int, budget: Double? = nil) {
        let page = corpus.page(strokes: count)
        let items = page.map { CommittedRenderer.Item(id: $0.id, kind: $0.tool, color: $0.color, geometry: nil, stroke: $0) }
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let pixels = CGSize(width: Bench.screen.width * Bench.displayScale, height: Bench.screen.height * Bench.displayScale)
        let times = timed(iterations: iterations) {
            guard let ctx = CommittedRenderer.makeBitmap(pixelSize: pixels, scale: Bench.displayScale) else {
                return XCTFail("Couldn't make the committed bitmap")
            }
            CommittedRenderer.render(items, into: ctx, bounds: Bench.screenBounds, transform: transform)
            _ = ctx.makeImage()
        }
        let name = "page_open.\(count / 1000)k_ms"
        BenchResults.record(name, Stats(times).median, unit: "ms", budget: budget)
        if let budget {
            check(Stats(times).median, under: budget, "Page open with \(count) strokes (median)")
        }
    }

    func testPageOpen1k() {
        pageOpen(strokes: 1000, iterations: 5)
    }

    func testPageOpen5k() {
        pageOpen(strokes: 5000, iterations: 3, budget: Self.pageOpenBudgetMs)
    }

    func testPageOpen20k() {
        pageOpen(strokes: 20000, iterations: 2)
    }

    // MARK: Full-page redraw

    /// Redrawing a 5k-stroke page into the existing bitmap with every stroke's geometry cached: what undo,
    /// erase and the end of a zoom or pan cost.
    func testFullPageRedraw5k() throws {
        let page = corpus.page(strokes: 5000)
        let items = page.map {
            CommittedRenderer.Item(id: $0.id, kind: $0.tool, color: $0.color,
                                   geometry: StrokeRenderer.geometry(for: $0), stroke: nil)
        }
        let transform = Bench.fittedTransform(for: corpus.pageSize)
        let pixels = CGSize(width: Bench.screen.width * Bench.displayScale, height: Bench.screen.height * Bench.displayScale)
        let ctx = try XCTUnwrap(CommittedRenderer.makeBitmap(pixelSize: pixels, scale: Bench.displayScale))
        let times = timed(iterations: 3) {
            CommittedRenderer.render(items, into: ctx, bounds: Bench.screenBounds, transform: transform)
            _ = ctx.makeImage()
        }
        BenchResults.record("full_redraw.5k_ms", Stats(times).median, unit: "ms")
    }

    // MARK: Memory

    /// Memory with a 5k-stroke page open at 6× zoom (the maximum) while writing: the cached geometry of
    /// every stroke, the committed bitmap drawn at 6×, and the live layer's tiles and baked tile bitmaps
    /// as the corpus is replayed on top. Peak footprint over the baseline before the page was opened.
    func testMemoryAt6xZoom() throws {
        let page = corpus.page(strokes: 5000)
        let before = Bench.footprint()
        var peak = before

        var cache: [UUID: StrokeGeometry] = [:]
        for stroke in page {
            cache[stroke.id] = StrokeRenderer.geometry(for: stroke)
        }
        let geometryBytes = Bench.footprint().subtractingClamped(before)

        let box = corpus.inkBounds
        let transform = Bench.zoomedTransform(for: corpus.pageSize, zoom: ViewTransform.maxZoomFactor,
                                              centredOn: CGPoint(x: box.midX, y: box.midY))
        let pixels = CGSize(width: Bench.screen.width * Bench.displayScale, height: Bench.screen.height * Bench.displayScale)
        let ctx = try XCTUnwrap(CommittedRenderer.makeBitmap(pixelSize: pixels, scale: Bench.displayScale))
        let items = page.map { CommittedRenderer.Item(id: $0.id, kind: $0.tool, color: $0.color, geometry: cache[$0.id], stroke: nil) }
        CommittedRenderer.render(items, into: ctx, bounds: Bench.screenBounds, transform: transform)
        let image = ctx.makeImage()
        peak = max(peak, Bench.footprint())

        let replayer = InputReplayer(viewSize: Bench.screen, transform: transform, displayScale: Bench.displayScale)
        var tilesPeak = 0
        for recorded in corpus.recordedStrokes {
            replayer.replay(recorded, transform: transform) { _ in
                tilesPeak = max(tilesPeak, replayer.liveView.tileMemory)
                peak = max(peak, Bench.footprint())
            }
        }
        XCTAssertNotNil(image)

        let mb = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        BenchResults.record("memory.6x.peak_mb", mb(peak.subtractingClamped(before)), unit: "MB")
        BenchResults.record("memory.6x.geometry_mb", mb(geometryBytes), unit: "MB")
        BenchResults.record("memory.6x.live_tiles_peak_mb", mb(UInt64(tilesPeak)), unit: "MB")
        withExtendedLifetime((cache, image)) {}
    }
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
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
