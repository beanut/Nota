import CoreGraphics
import Foundation
@testable import InkKit
import UIKit
import XCTest

/// Canvas benchmarks and budgets (NOT-98): the parts of the canvas `InkBenchmarks` doesn't cover. Edits
/// on a dense page, a pinch, a pan at high zoom, a page entering view in continuous scrolling, and the
/// footprint of scrolling a long note.
///
/// Unlike `InkBenchmarks`, which times InkKit's renderers directly, these drive a real `CanvasView` (and
/// `ContinuousCanvasView`) through the entry points its gestures and touches use (`zoom(by:about:)`,
/// `pan(by:)`, `undo()`, `eraseStrokes(along:)`, `endStroke(commit:)`, `place(_:settled:)`), and time
/// until `rendersSettled`: the committed layer shows the page as it is, sharp, at the current transform.
/// So whatever the canvas's render architecture becomes, they keep measuring what the user sees.
///
/// Main-thread work per gesture frame is the frame's wall time minus the time the main run loop spent
/// asleep in it (`MainThreadBusy`), with frames paced at 120 Hz. It counts the gesture step, every render
/// callback the main queue ran in the frame and any wait on a lock, but not Core Animation's render server
/// or the GPU: the views aren't in a window, and the simulator's GPU isn't an iPad's. The on-device
/// Instruments profile (NOT-98) is the check on those.
@MainActor
final class CanvasBenchmarks: XCTestCase {
    /// An edit (undo, erase, pixel erase) shows correct pixels within a frame at 60 Hz.
    static let editBudgetMs = 16.0
    /// No main-thread frame over 8 ms during a pinch or pan (half a 120 Hz frame).
    static let gestureFrameBudgetMs = 8.0
    /// Ink sharp at the new zoom within 150 ms of the fingers lifting.
    static let timeToSharpBudgetMs = 150.0
    /// Rendering the ink one pan step uncovers at 6×, off the main thread, within a 120 Hz frame.
    static let panStepRenderBudgetMs = 8.0
    /// A page entering view in continuous scrolling has its ink within 50 ms.
    static let pageEnterBudgetMs = 50.0
    /// What scrolling a 20-page note of dense pages may add to the footprint.
    static let continuousMemoryBudgetMB = 300.0

    /// 120 Hz: the pace gesture frames are fed at.
    static let frameInterval = 1.0 / 120
    /// Frames in a pinch from the fitted page to 6× (half a second), and in a pan.
    static let gestureFrames = 60

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
        XCTAssertLessThan(value, budget, "\(what): \(value) is over the \(budget) budget")
    }

    // MARK: Setup

    /// A full-screen canvas showing a page of `count` strokes, fitted, drawn and settled, with a
    /// controller (its settings in a throwaway suite) so the eraser works.
    private func denseCanvas(strokes count: Int = 5000) throws -> (CanvasView, CanvasController) {
        let file = InkPageFile(pageID: UUID(), strokes: corpus.page(strokes: count))
        let document = CanvasDocument(file: file, pageSize: corpus.pageSize)
        let suite = "CanvasBenchmarks.\(UUID().uuidString)"
        let controller = try CanvasController(settingsStore: XCTUnwrap(UserDefaults(suiteName: suite)),
                                              penTray: PenTrayStore(fileURL: nil))
        let canvas = CanvasView(frame: Bench.screenBounds, document: document)
        canvas.traitOverrides.displayScale = Bench.displayScale
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
        try waitUntilSettled(canvas, timeout: 60)
        return (canvas, controller)
    }

    /// Runs the main run loop until `canvas` has settled; returns how long that took, in milliseconds.
    @discardableResult
    private func waitUntilSettled(_ canvas: CanvasView, timeout: TimeInterval = 30) throws -> Double {
        try waitUntil(timeout: timeout) { canvas.rendersSettled }
    }

    /// Runs the main run loop until `canvas` has settled and the tiles around its view are filled too
    /// (`rendersSettled` doesn't wait for those): what fill counts are read after.
    private func waitUntilIdle(_ canvas: CanvasView, timeout: TimeInterval = 30) throws {
        try waitUntil(timeout: timeout) { canvas.rendersSettled && !canvas.coordinator.isFilling }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ done: () -> Bool) throws -> Double {
        let start = Bench.now()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done() {
            guard Date() < deadline else {
                throw NotSettled(timeout: timeout)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.0002))
        }
        return Bench.milliseconds(since: start)
    }

    /// The middle of the page's ink, in canvas space.
    private var inkCentre: CGPoint {
        let box = corpus.inkBounds
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// The fraction of pixels in what `canvas` shows that differ from the page drawn from scratch at the
    /// same transform: 0 when its pixels are correct. The reference is drawn through the tile path from
    /// scratch (every tile in view filled again, no cache, all geometry rebuilt) and assembled the same
    /// way, since tiles differ from one whole-screen draw in about 0.1% of pixels (NOT-99), which would
    /// hide a stale tile.
    private func mismatch(of canvas: CanvasView) throws -> Double {
        let coordinator = canvas.coordinator
        let shown = try XCTUnwrap(coordinator.composedImage(), "the canvas shows no tiles")
        let strokes = canvas.document.strokes
        let ink = InkSnapshot(strokes: strokes, index: StrokeIndex(strokes: strokes),
                              geometry: Dictionary(uniqueKeysWithValues: zip(strokes.map(\.id),
                                                                             strokes.map(StrokeRenderer.keptGeometry))),
                              skipped: [])
        let keys = coordinator.visibleKeys(at: canvas.viewTransform, level: coordinator.level(for: canvas.viewTransform))
        var tiles: [(key: TileKey, image: CGImage)] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            let tile = RenderCoordinator.draw(keys[i], from: ink, revision: 0, filler: CoreGraphicsTileFiller())
            if let image = tile.image {
                lock.withLock { tiles.append((keys[i], image)) }
            }
        }
        let ctx = try XCTUnwrap(TileBitmap.viewBitmap(pixelSize: Bench.pixelSize, scale: Bench.displayScale))
        TileBitmap.compose(tiles, at: canvas.viewTransform, in: ctx)
        let reference = try XCTUnwrap(ctx.makeImage())
        return Self.differingFraction(shown, reference)
    }

    /// The fraction of pixels whose channels differ by more than 2 (of 255) between two images.
    static func differingFraction(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow,
              let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data?, da.count == db.count
        else { return 1 }
        var differing = 0
        da.withUnsafeBytes { pa in
            db.withUnsafeBytes { pb in
                let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
                var i = 0
                while i + 3 < x.count {
                    for c in 0 ..< 4 where abs(Int(x[i + c]) - Int(y[i + c])) > 2 {
                        differing += 1
                        break
                    }
                    i += 4
                }
            }
        }
        return Double(differing) / Double(a.width * a.height)
    }

    private func assertCorrectPixels(_ canvas: CanvasView, _ what: String) throws {
        let wrong = try mismatch(of: canvas)
        XCTAssertLessThan(wrong, 0.001, "\(what): \(wrong * 100)% of the pixels shown are wrong")
    }

    // MARK: Edits

    /// Undoing the last stroke on a 5k-stroke page: from `CanvasView.undo()` (the undo button) to the
    /// committed layer showing the page without it.
    func testUndo5k() throws {
        let (canvas, _) = try denseCanvas()
        let extra = corpus.page(strokes: 1)[0]
        var times: [Double] = []
        for _ in 0 ..< 5 {
            canvas.editDocument { canvas.document.add(extra) }
            canvas.redrawFromDocument()
            try waitUntilSettled(canvas)
            let start = Bench.now()
            XCTAssertTrue(canvas.undo())
            try waitUntilSettled(canvas)
            times.append(Bench.milliseconds(since: start))
        }
        try assertCorrectPixels(canvas, "After undo")
        BenchResults.record("edit.undo_5k_ms", Stats(times).median, unit: "ms", budget: Self.editBudgetMs)
        check(Stats(times).median, under: Self.editBudgetMs, "Undo on a 5000-stroke page (ms, median)")
    }

    /// The stroke eraser sweeping once through the middle of a 5k-stroke page's ink: from the eraser's
    /// sample (`eraseStrokes(along:)`, as the touch handling calls it) to correct pixels.
    func testEraseStroke5k() throws {
        let (canvas, controller) = try denseCanvas()
        controller.select(.eraser)
        controller.eraserMode = .stroke
        let c = inkCentre
        var times: [Double] = []
        for _ in 0 ..< 5 {
            let before = canvas.document.strokes.count
            canvas.eraseSession = CanvasView.EraseSession(target: controller.effectiveEraserTarget, before: nil)
            let start = Bench.now()
            canvas.eraseStrokes(along: CGPoint(x: c.x - 15, y: c.y))
            canvas.eraseStrokes(along: CGPoint(x: c.x + 15, y: c.y))
            try waitUntilSettled(canvas)
            times.append(Bench.milliseconds(since: start))
            XCTAssertLessThan(canvas.document.strokes.count, before, "the eraser missed the ink")
            try assertCorrectPixels(canvas, "After erasing")
            canvas.finishErasing()
            XCTAssertTrue(canvas.undo())
            try waitUntilSettled(canvas)
        }
        BenchResults.record("edit.erase_stroke_5k_ms", Stats(times).median, unit: "ms", budget: Self.editBudgetMs)
        check(Stats(times).median, under: Self.editBudgetMs, "Stroke erase on a 5000-stroke page (ms, median)")
    }

    /// A pixel-eraser stroke across the middle of a 5k-stroke page's ink: from the Pencil lifting
    /// (`endStroke(commit:)`: the strokes it cuts through are split, it's added and drawn into the committed
    /// layer) to correct pixels.
    func testPixelErase5k() throws {
        let (canvas, controller) = try denseCanvas()
        controller.select(.eraser)
        controller.eraserMode = .precision
        let template = controller.strokeTemplate(viewScale: canvas.viewTransform.scale)
        let c = inkCentre
        var times: [Double] = []
        for _ in 0 ..< 5 {
            let live = LiveStroke(stroke: Stroke(id: UUID(), color: template.color, brush: template.brush, points: []))
            for i in 0 ... 60 {
                let point = StrokePoint(location: CGPoint(x: c.x - 30 + CGFloat(i), y: c.y + CGFloat(i % 7) - 3),
                                        force: 0.5, altitude: .pi / 2, azimuth: 0, timestamp: Double(i) / 240)
                _ = live.append(point, minSpacing: 0.3 / canvas.viewTransform.scale)
            }
            _ = live.advance(predicted: [])
            canvas.live = live
            let start = Bench.now()
            canvas.endStroke(commit: true)
            try waitUntilSettled(canvas)
            times.append(Bench.milliseconds(since: start))
            try assertCorrectPixels(canvas, "After a pixel erase")
            XCTAssertTrue(canvas.undo())
            try waitUntilSettled(canvas)
        }
        BenchResults.record("edit.pixel_erase_5k_ms", Stats(times).median, unit: "ms", budget: Self.editBudgetMs)
        check(Stats(times).median, under: Self.editBudgetMs, "Pixel erase on a 5000-stroke page (ms, median)")
    }

    // MARK: Gestures

    /// Feeds `frames` gesture steps to the canvas at 120 Hz, letting the main run loop run (render
    /// callbacks and all) for the rest of each frame. Returns each frame's main-thread work in ms.
    private func paced(frames: Int, _ step: (Int) -> Void) -> [Double] {
        let busy = MainThreadBusy()
        defer { busy.stop() }
        let interval = UInt64(Self.frameInterval * 1e9)
        var work: [Double] = []
        for n in 0 ..< frames {
            let start = Bench.now()
            let asleep = busy.asleepNanos
            step(n)
            let deadline = start + interval
            while Bench.now() < deadline {
                let left = Double(deadline - min(Bench.now(), deadline)) / 1e9
                if CFRunLoopRunInMode(.defaultMode, left, true) == .finished {
                    usleep(100)
                }
            }
            let wall = Bench.now() - start
            work.append(Double(wall - min(busy.asleepNanos - asleep, wall)) / 1e6)
        }
        return work
    }

    /// A pinch from the fitted page to 6× over half a second, about the middle of a 5k-stroke page's
    /// ink: main-thread work per frame, and how long after the fingers lift the ink is sharp at 6×.
    func testPinch1xTo6x() throws {
        try pinch1xTo6x(name: "zoom.pinch_1x_6x", holding: 0)
    }

    /// The same pinch, with the fingers held still at 6× for 150 ms before they lift, as a pinch usually
    /// ends: the level it holds is filled meanwhile (NOT-105), so less is left once they lift.
    func testPinch1xTo6xHeld() throws {
        try pinch1xTo6x(name: "zoom.pinch_1x_6x_held", holding: 0.15)
    }

    private func pinch1xTo6x(name: String, holding: TimeInterval) throws {
        let (canvas, _) = try denseCanvas()
        let k = pow(ViewTransform.maxZoomFactor, 1 / CGFloat(Self.gestureFrames))
        var frames: [Double] = []
        var sharp: [Double] = []
        var fillWork: [Double] = [], tiles: [Double] = []
        for _ in 0 ..< 3 {
            canvas.resetView()
            try waitUntilSettled(canvas)
            // Each pinch ends at a level not drawn yet: returning to a cached one fills nothing.
            canvas.coordinator.cache.removeAll(page: canvas.document.cacheID, except: canvas.coordinator.restingLevel)
            let focus = canvas.viewTransform.toView(inkCentre)
            canvas.gestureBegan()
            frames += paced(frames: Self.gestureFrames) { _ in canvas.zoom(by: k, about: focus) }
            if holding > 0 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: holding))
            }
            let start = Bench.now()
            let before = canvas.coordinator.fillStats
            canvas.gestureEnded()
            try waitUntilSettled(canvas)
            sharp.append(Bench.milliseconds(since: start))
            let after = canvas.coordinator.fillStats
            fillWork.append(after.fillMilliseconds - before.fillMilliseconds)
            tiles.append(Double(after.tilesFilled - before.tilesFilled))
        }
        XCTAssertEqual(canvas.viewTransform.scale / canvas.fittedTransform().scale, ViewTransform.maxZoomFactor,
                       accuracy: 0.01)
        try assertCorrectPixels(canvas, "At 6× after the pinch")
        recordGesture(name, frames: frames, sharp: sharp)
        // What getting sharp costs once the fingers lift: the tiles filled by then, and their fill times added
        // up, which time to sharp spreads over the workers.
        BenchResults.record("\(name).tiles_filled", Stats(tiles).median, unit: "tiles")
        BenchResults.record("\(name).fill_cpu_ms", Stats(fillWork).median, unit: "ms")
    }

    /// Panning at 6× across the middle of a 5k-stroke page's ink, 10 pt a frame for half a second.
    func testPan6xDense() throws {
        let (canvas, _) = try denseCanvas()
        canvas.gestureBegan()
        canvas.zoom(by: ViewTransform.maxZoomFactor, about: canvas.viewTransform.toView(inkCentre))
        canvas.gestureEnded()
        try waitUntilIdle(canvas)
        let start6x = canvas.viewTransform
        var frames: [Double] = []
        var sharp: [Double] = []
        let before = canvas.coordinator.fillStats
        for _ in 0 ..< 3 {
            canvas.gestureBegan()
            frames += paced(frames: Self.gestureFrames) { n in
                // Left then back, a little downwards: across the ink without leaving it.
                canvas.pan(by: CGPoint(x: n < Self.gestureFrames / 2 ? -10 : 10, y: -3))
            }
            let start = Bench.now()
            canvas.gestureEnded()
            try waitUntilSettled(canvas)
            sharp.append(Bench.milliseconds(since: start))
        }
        try waitUntilIdle(canvas)
        let fill = canvas.coordinator.fillStats
        XCTAssertNotEqual(canvas.viewTransform, start6x)
        try assertCorrectPixels(canvas, "At 6× after the pan")
        recordGesture("pan.6x_dense", frames: frames, sharp: sharp)

        // The render work each pan step costs, off the main thread: the tiles the pans uncovered (with a
        // tile's margin ahead of the view) filled, spread over their frames.
        let step = (fill.milliseconds - before.milliseconds) / Double(3 * Self.gestureFrames)
        BenchResults.record("pan.6x_dense.step_render_ms", step, unit: "ms", budget: Self.panStepRenderBudgetMs)
        BenchResults.record("pan.6x_dense.tiles_filled", Double(fill.tilesFilled - before.tilesFilled), unit: "tiles")
        check(step, under: Self.panStepRenderBudgetMs, "Render work per pan step at 6× (ms, mean)")

        // Back the way the last pass came (untimed): every tile on the way is cached, so nothing is filled.
        canvas.gestureBegan()
        _ = paced(frames: Self.gestureFrames) { n in
            canvas.pan(by: CGPoint(x: n < Self.gestureFrames / 2 ? -10 : 10, y: 3))
        }
        canvas.gestureEnded()
        try waitUntilIdle(canvas)
        let refilled = canvas.coordinator.fillStats.tilesFilled - fill.tilesFilled
        BenchResults.record("pan.6x_dense.cached_tiles_filled", Double(refilled), unit: "tiles")
        XCTAssertEqual(refilled, 0, "a pan over cached tiles filled some again")
    }

    private func recordGesture(_ name: String, frames: [Double], sharp: [Double]) {
        let f = Stats(frames), s = Stats(sharp).median
        BenchResults.record("\(name).frame_p50_ms", f.median, unit: "ms")
        BenchResults.record("\(name).frame_p95_ms", f.p95, unit: "ms", budget: Self.gestureFrameBudgetMs)
        BenchResults.record("\(name).frame_max_ms", f.max, unit: "ms", budget: Self.gestureFrameBudgetMs)
        BenchResults.record("\(name).time_to_sharp_ms", s, unit: "ms", budget: Self.timeToSharpBudgetMs)
        check(f.p95, under: Self.gestureFrameBudgetMs, "\(name): main-thread work per frame (ms, p95)")
        check(s, under: Self.timeToSharpBudgetMs, "\(name): time to sharp ink (ms, median)")
    }

    // MARK: Continuous scrolling

    /// A 5k-stroke page scrolling into view in continuous mode: `ContinuousCanvasView` hands it a pooled
    /// embedded canvas another page left (`show(_:)`, NOT-107), places it and lays it out
    /// (`place(_:settled:)`, `layoutIfNeeded`); timed until its ink is drawn. The budgeted case
    /// (`scroll.page_enter_5k_ms`) is a page seen before, in this launch or an earlier one (NOT-106): the
    /// page read from its file again (nothing of it in the tile cache) and the tiles it left read back from
    /// the file an app keeps them in (mapped, as `DocumentStore` reads them), then restored. The first time
    /// a page is ever shown (on a new canvas), its tiles in view are filled: `scroll.page_enter_first_5k_ms`,
    /// no budget.
    func testPageEnter5k() throws {
        let suite = "CanvasBenchmarks.\(UUID().uuidString)"
        let controller = try CanvasController(settingsStore: XCTUnwrap(UserDefaults(suiteName: suite)),
                                              penTray: PenTrayStore(fileURL: nil))
        let layout = ContinuousPageLayout(pageSizes: [corpus.pageSize.size, corpus.pageSize.size],
                                          width: Bench.screen.width)
        // The second page with its top a third of the way up the screen, as it comes into view.
        let page = layout.frames[1]
        let viewport = CGRect(x: 0, y: page.minY - Bench.screen.height * 2 / 3, width: Bench.screen.width,
                              height: Bench.screen.height)
        let window = ContinuousPageLayout.renderWindow(forPage: page, viewport: viewport, current: nil)
        let placement = ViewTransform(scale: layout.scale,
                                      offset: CGPoint(x: page.minX - window.minX, y: page.minY - window.minY))
        let file = InkPageFile(pageID: UUID(), strokes: corpus.page(strokes: 5000))
        func enter(_ document: CanvasDocument, on pooled: CanvasView? = nil) throws -> CanvasView {
            let canvas = pooled ?? CanvasView(frame: window, document: document, embedded: true)
            pooled?.show(document)
            canvas.traitOverrides.displayScale = Bench.displayScale
            canvas.controller = controller
            canvas.restingScaleOverride = layout.scale // as `ContinuousCanvasView` sets it
            canvas.place(placement, settled: true)
            canvas.layoutIfNeeded()
            try waitUntilSettled(canvas, timeout: 60)
            return canvas
        }

        // First sight: filled. Then the page scrolls away, leaving its tiles, which the app keeps.
        let first = CanvasDocument(file: file, pageSize: corpus.pageSize)
        let start = Bench.now()
        let shown = try enter(first)
        BenchResults.record("scroll.page_enter_first_5k_ms", Bench.milliseconds(since: start), unit: "ms")
        try waitUntilIdle(shown)
        shown.coordinator.captureTileRaster()
        try waitUntil(timeout: 60) { first.committedTiles != nil }
        let tiles = try XCTUnwrap(first.committedTiles)
        let url = FileManager.default.temporaryDirectory.appending(path: "page-enter-\(UUID().uuidString).tiles")
        try tiles.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var times: [Double] = []
        for _ in 0 ..< 3 {
            let document = CanvasDocument(file: file, pageSize: corpus.pageSize)
            let start = Bench.now()
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            XCTAssertTrue(document.restoreCommittedTiles(data))
            let canvas = try enter(document, on: shown)
            times.append(Bench.milliseconds(since: start))
            XCTAssertEqual(canvas.coordinator.fillStats.tilesFilled, 0, "a page seen before filled tiles")
        }
        let median = Stats(times).median
        BenchResults.record("scroll.page_enter_5k_ms", median, unit: "ms", budget: Self.pageEnterBudgetMs)
        check(median, under: Self.pageEnterBudgetMs, "A 5000-stroke page entering view (ms, median)")
    }

    /// A 20-page note of 5k-stroke pages in continuous scrolling, as the app shows it: in a window (so
    /// pages leaving view leave their tiles, and drawn layers are drawn), with each page's tiles written to a
    /// file and swapped for the mapped file as `DocumentStore` does (NOT-106).
    ///
    /// 1. **Memory** (`memory.continuous_20_pages_mb`): scrolled from the first page to the last a page at
    ///    a time, each page's ink drawn for the first time: the peak footprint over a settled baseline taken
    ///    before the note was made, less the note itself (its strokes in memory, `model_mb`). The note is
    ///    counted as the heap it holds, not as the footprint it added: making it reuses whatever memory
    ///    malloc kept from the benchmarks before, so its footprint (and with it a footprint-only split)
    ///    swings by 70 MB from run to run while the peak doesn't (NOT-112).
    /// 2. **A fling** (`scroll.fling_20_pages.*`, NOT-107) back to the top and down to the bottom again at
    ///    6,000 points a second (50 a frame at 120 Hz), every page seen before: main-thread work per
    ///    frame, and the frames on which a page on screen showed paper where its ink belongs (a tile in view
    ///    not laid out, with no resting-level tile under it). Canvases made during the fling are counted
    ///    too: the pool should make none.
    func testMemoryContinuous20Pages() throws {
        let start = Bench.settledFootprint()
        let heapStart = Bench.heapInUse()
        let pages = (0 ..< 20).map { _ in
            CanvasDocument(file: InkPageFile(pageID: UUID(), strokes: corpus.page(strokes: 5000)),
                           pageSize: corpus.pageSize)
        }
        let notebook = InkNotebook(pages: pages, defaultPageSize: corpus.pageSize)
        let kept = try KeptTiles(pages: pages)
        let model = Bench.heapInUse().subtractingClamped(heapStart)
        let before = Bench.settledFootprint()
        var peak = before

        let suite = "CanvasBenchmarks.\(UUID().uuidString)"
        let controller = try CanvasController(settingsStore: XCTUnwrap(UserDefaults(suiteName: suite)),
                                              penTray: PenTrayStore(fileURL: nil))
        let view = ContinuousCanvasView(notebook: notebook, controller: controller, telemetry: PencilTelemetry())
        view.traitOverrides.displayScale = Bench.displayScale
        view.frame = Bench.screenBounds
        let window = UIWindow(frame: Bench.screenBounds)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        func settled() -> Bool {
            !view.liveCanvases.isEmpty && view.liveCanvases.allSatisfy { $0.rendersSettled && !$0.coordinator.isFilling }
        }
        for index in pages.indices {
            view.scroll(toPage: index, animated: false)
            view.layoutIfNeeded()
            try waitUntil(timeout: 120) {
                peak = max(peak, Bench.footprint())
                return settled()
            }
        }
        let mb = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        let added = mb(peak.subtractingClamped(start).subtractingClamped(model))
        BenchResults.record("memory.continuous_20_pages_mb", added, unit: "MB", budget: Self.continuousMemoryBudgetMB)
        BenchResults.record("memory.continuous_20_pages.model_mb", mb(model), unit: "MB")
        check(added, under: Self.continuousMemoryBudgetMB, "Scrolling a 20-page note (MB over the note)")

        // The fling: up to the top, then down to the bottom, every page seen before.
        try waitUntil(timeout: 60) { kept.isIdle }
        let speed: CGFloat = 50 // content points a frame
        let bottom = view.contentOffsetForTesting
        var blankFrames = 0, blankTiles = 0
        func blank() -> Int {
            view.pagesInView.map { index -> Int in
                guard let canvas = view.canvas(showing: pages[index].id) else { return 1 }
                let onScreen = canvas.convert(view.bounds, from: view)
                return canvas.coordinator.blankTiles(in: canvas.viewTransform.toCanvas(onScreen))
            }
            .reduce(0, +)
        }
        var maxPeak = before
        func step(to y: CGFloat) {
            view.scrollForTesting(toY: y)
            let b = blank()
            blankTiles += b
            blankFrames += b > 0 ? 1 : 0
            maxPeak = max(maxPeak, Bench.footprint())
        }
        let count = Int((bottom / speed).rounded(.up))
        var frames = paced(frames: count) { n in step(to: bottom - CGFloat(n + 1) * speed) }
        // The pool has as many canvases as a fling needs now: the way back down makes none.
        let madeGoingUp = view.canvasesMade
        frames += paced(frames: count) { n in step(to: CGFloat(n + 1) * speed) }
        view.endScrollingForTesting()
        let f = Stats(frames)
        BenchResults.record("scroll.fling_20_pages.frame_p50_ms", f.median, unit: "ms")
        BenchResults.record("scroll.fling_20_pages.frame_p95_ms", f.p95, unit: "ms", budget: Self.gestureFrameBudgetMs)
        BenchResults.record("scroll.fling_20_pages.frame_max_ms", f.max, unit: "ms", budget: Self.gestureFrameBudgetMs)
        BenchResults.record("scroll.fling_20_pages.blank_frames", Double(blankFrames), unit: "frames", budget: 0.5)
        BenchResults.record("scroll.fling_20_pages.blank_tiles", Double(blankTiles), unit: "tiles")
        BenchResults.record("scroll.fling_20_pages.canvases_made", Double(view.canvasesMade - madeGoingUp),
                            unit: "canvases")
        BenchResults.record("scroll.fling_20_pages.peak_mb", mb(maxPeak.subtractingClamped(start).subtractingClamped(model)),
                            unit: "MB")
        check(f.p95, under: Self.gestureFrameBudgetMs, "Fling through 20 pages: main-thread work per frame (ms, p95)")
        XCTAssertEqual(view.canvasesMade, madeGoingUp, "the fling made canvases instead of reusing them")
        withExtendedLifetime((view, notebook, window, kept)) {}
    }
}

/// What the app does with the tiles a page leaves (`DocumentStore`, NOT-106), for the continuous
/// scrolling benchmark: each capture is written to a file off the main thread and the page swaps its copy
/// in memory for the mapped file, so kept tiles cost what they cost in the app.
@MainActor
final class KeptTiles {
    private let folder: URL
    private let queue = DispatchQueue(label: "KeptTiles")
    private var writing = 0

    init(pages: [CanvasDocument]) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "kept-tiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for page in pages {
            page.observeCommittedTiles(self) { [weak self, weak page] in
                guard let self, let page, let tiles = page.committedTiles else { return }
                let url = folder.appending(path: "\(page.id.uuidString).tiles")
                writing += 1
                queue.async {
                    let mapped = (try? tiles.data.write(to: url)).flatMap { try? Data(contentsOf: url, options: .alwaysMapped) }
                    DispatchQueue.main.async {
                        self.writing -= 1
                        if let mapped {
                            page.adoptPersistedTiles(mapped, for: tiles)
                        }
                    }
                }
            }
        }
    }

    var isIdle: Bool {
        writing == 0
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The canvas was still drawing when a benchmark gave up waiting for it.
struct NotSettled: Error, CustomStringConvertible {
    let timeout: TimeInterval
    var description: String {
        "The canvas didn't settle within \(timeout) s"
    }
}

/// Counts how long the main run loop sleeps (between its before-waiting and after-waiting
/// activities), so a frame's main-thread work is its wall time minus that.
@MainActor
final class MainThreadBusy {
    private(set) var asleepNanos: UInt64 = 0
    private var sleptAt: UInt64?
    private var observer: CFRunLoopObserver?

    init() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeWaiting, .afterWaiting]).rawValue,
                                                          true, CFIndex.max) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                if activity == .beforeWaiting {
                    self.sleptAt = Bench.now()
                } else if let at = self.sleptAt {
                    self.asleepNanos += Bench.now() - at
                    self.sleptAt = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
    }
}

extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}
