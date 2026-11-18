import CoreGraphics
import Foundation
@testable import InkKit
import UIKit
import XCTest

/// The template and object layers (NOT-109): what panning and zooming a page of objects costs beyond its
/// ink. The page is object-heavy: a PDF template (a page of vector drawing and text) ruled over, 20 text
/// boxes and 10 pictures, and no ink, so what's measured is the template and objects.
///
/// The canvas is in a window, so whatever draws on display (layers drawn as vectors in `draw(_:)`) draws,
/// and main-thread work per frame counts it (`MainThreadBusy`, as `CanvasBenchmarks`). Time to sharp is from
/// the fingers lifting to the template and objects shown sharp at the new zoom.
@MainActor
final class ObjectLayerBenchmarks: XCTestCase {
    static let frames = 60
    static let frameInterval = 1.0 / 120

    private func check(_ value: Double, under budget: Double, _ what: String) {
        guard Bench.optimized, ProcessInfo.processInfo.environment["INK_BENCH_ENFORCE_BUDGETS"] == "1" else { return }
        XCTAssertLessThan(value, budget, "\(what): \(value) is over the \(budget) budget")
    }

    // MARK: The page

    /// A letter-size PDF page of vector drawing: a few thousand short paths and some text, like a scanned
    /// worksheet's or a slide's.
    static func templatePDF(size: CGSize) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        var random = SystemRandomNumberGenerator()
        ctx.setLineWidth(0.6)
        for i in 0 ..< 3000 {
            let x = CGFloat.random(in: 20 ... size.width - 40, using: &random)
            let y = CGFloat.random(in: 20 ... size.height - 40, using: &random)
            ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.3, blue: CGFloat(i % 7) / 7, alpha: 0.5))
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addCurve(to: CGPoint(x: x + 30, y: y + 8), control1: CGPoint(x: x + 8, y: y + 20),
                         control2: CGPoint(x: x + 20, y: y - 12))
            ctx.strokePath()
        }
        UIGraphicsPushContext(ctx)
        let text = String(repeating: "Worksheet question with a line to answer on. ", count: 6)
        for row in 0 ..< 24 {
            (text as NSString).draw(at: CGPoint(x: 30, y: 20 + CGFloat(row) * 31),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 9)])
        }
        UIGraphicsPopContext()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// A photo-sized picture: a gradient with noise, so it doesn't compress to nothing.
    static func pictureData(seed: Int) -> Data {
        let width = 1600, height = 1200
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let image = renderer.image { context in
            let ctx = context.cgContext
            let colors = [UIColor(hue: CGFloat(seed % 10) / 10, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor,
                          UIColor(hue: CGFloat((seed + 4) % 10) / 10, saturation: 0.7, brightness: 0.5, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                         locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            }
            var random = SystemRandomNumberGenerator()
            for _ in 0 ..< 400 {
                ctx.setFillColor(UIColor(white: .random(in: 0 ... 1, using: &random), alpha: 0.3).cgColor)
                ctx.fill(CGRect(x: .random(in: 0 ... CGFloat(width), using: &random),
                                y: .random(in: 0 ... CGFloat(height), using: &random), width: 40, height: 40))
            }
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    /// The object-heavy page: the PDF template ruled over, 20 text boxes in a grid and 10 pictures among them.
    static func objectPage() throws -> CanvasDocument {
        let size = PageSize.letter
        let artwork = try XCTUnwrap(TemplateArtwork(kind: .pdf, data: templatePDF(size: size.size)))
        let template = PageTemplate(pattern: .ruled, spacing: 24, background: artwork.background)
        let document = CanvasDocument(pageSize: size, template: template, templateArtwork: artwork)
        let paragraph = "Notes from the lecture: the main points, with an example, and what to read before next week."
        for i in 0 ..< 20 {
            let col = i % 4, row = i / 4
            let text = RichText([paragraph, paragraph].joined(separator: "\n"))
            document.addObject(TextObject(origin: CGPoint(x: 24 + CGFloat(col) * 148, y: 30 + CGFloat(row) * 150),
                                          width: 132, text: text))
        }
        for i in 0 ..< 10 {
            let id = try XCTUnwrap(ImageAssets.shared.add(pictureData(seed: i)))
            let col = i % 5, row = i / 5
            let frame = CGRect(x: 20 + CGFloat(col) * 116, y: 520 + CGFloat(row) * 120, width: 108, height: 81)
            document.addObject(ImageObject(asset: id, pixelSize: CGSize(width: 1600, height: 1200), frame: frame))
        }
        return document
    }

    /// A full-screen canvas in a window showing the object page fitted, everything drawn.
    private func objectCanvas() throws -> (CanvasView, UIWindow) {
        let canvas = try CanvasView(frame: Bench.screenBounds, document: Self.objectPage())
        canvas.traitOverrides.displayScale = Bench.displayScale
        let window = UIWindow(frame: Bench.screenBounds)
        window.addSubview(canvas)
        window.isHidden = false
        canvas.layoutIfNeeded()
        try settle(canvas)
        // Pictures decode in the background at the sizes asked for, then draw again: let them.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        try settle(canvas)
        return (canvas, window)
    }

    // MARK: Timing

    private func waitUntil(timeout: TimeInterval = 30, _ done: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done() {
            guard Date() < deadline else { throw NotSettled(timeout: timeout) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.0002))
        }
    }

    /// Runs until the template and objects are sharp at the canvas's transform, and the ink settled.
    private func settle(_ canvas: CanvasView) throws {
        try waitUntil { canvas.rendersSettled && Self.vectorsSettled(canvas) }
    }

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

    // MARK: Benchmarks

    /// Panning the object page at 2×, 10 pt a frame for half a second, three times over the same ground:
    /// main-thread work per frame (`objects.pan_ms`, its p95), and the template and object tiles drawn.
    func testObjectPagePan() throws {
        let (canvas, window) = try objectCanvas()
        canvas.gestureBegan()
        canvas.zoom(by: 2, about: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        canvas.gestureEnded()
        try settle(canvas)
        Self.waitForFills(canvas)
        let before = Self.vectorFills(canvas)
        var frames: [Double] = []
        for _ in 0 ..< 3 {
            canvas.gestureBegan()
            frames += paced(frames: Self.frames) { n in
                canvas.pan(by: CGPoint(x: n < Self.frames / 2 ? -10 : 10, y: n < Self.frames / 2 ? -4 : 4))
            }
            canvas.gestureEnded()
            try settle(canvas)
        }
        Self.waitForFills(canvas)
        let after = Self.vectorFills(canvas)
        let f = Stats(frames)
        BenchResults.record("objects.pan_ms", f.p95, unit: "ms", budget: CanvasBenchmarks.gestureFrameBudgetMs)
        BenchResults.record("objects.pan.frame_max_ms", f.max, unit: "ms", budget: CanvasBenchmarks.gestureFrameBudgetMs)
        BenchResults.record("objects.pan.tiles_filled", Double(after.tiles - before.tiles), unit: "tiles")
        check(f.p95, under: CanvasBenchmarks.gestureFrameBudgetMs, "Panning a page of objects: main-thread work per frame (ms, p95)")
        withExtendedLifetime(window) {}
    }

    /// Pinching the object page from fitted to 3× over a quarter of a second, then lifting: main-thread work
    /// per frame, and the time from lifting to the template and objects sharp at 3× (`objects.zoom_settle_ms`),
    /// a level never drawn before each time.
    func testObjectPageZoomSettle() throws {
        let (canvas, window) = try objectCanvas()
        let frames = 30
        let k = pow(3, 1 / CGFloat(frames))
        let focus = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        // Once untimed, so the pictures are decoded at the sizes 3× wants.
        canvas.gestureBegan()
        canvas.zoom(by: 3, about: focus)
        canvas.gestureEnded()
        try settle(canvas)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        var work: [Double] = [], sharp: [Double] = [], fillCPU: [Double] = [], templateCPU: [Double] = []
        for _ in 0 ..< 3 {
            canvas.resetView()
            try settle(canvas)
            Self.forgetZoomedTiles(canvas)
            let before = Self.vectorFills(canvas), templateBefore = Self.templateFillMilliseconds(canvas)
            canvas.gestureBegan()
            work += paced(frames: frames) { _ in canvas.zoom(by: k, about: focus) }
            let start = Bench.now()
            canvas.gestureEnded()
            try settle(canvas)
            sharp.append(Bench.milliseconds(since: start))
            fillCPU.append(Self.vectorFills(canvas).milliseconds - before.milliseconds)
            templateCPU.append(Self.templateFillMilliseconds(canvas) - templateBefore)
        }
        let f = Stats(work), s = Stats(sharp).median
        BenchResults.record("objects.zoom_settle_ms", s, unit: "ms", budget: CanvasBenchmarks.timeToSharpBudgetMs)
        BenchResults.record("objects.zoom.frame_p95_ms", f.p95, unit: "ms", budget: CanvasBenchmarks.gestureFrameBudgetMs)
        BenchResults.record("objects.zoom_settle.fill_cpu_ms", Stats(fillCPU).median, unit: "ms")
        BenchResults.record("objects.zoom_settle.template_fill_cpu_ms", Stats(templateCPU).median, unit: "ms")
        check(s, under: CanvasBenchmarks.timeToSharpBudgetMs, "Zooming a page of objects: time to sharp (ms, median)")
        withExtendedLifetime(window) {}
    }
}

// MARK: - The layers measured

extension ObjectLayerBenchmarks {
    /// Whether the template, objects and tape are sharp at the canvas's transform.
    static func vectorsSettled(_ canvas: CanvasView) -> Bool {
        canvas.vectorLayersSettled
    }

    /// Waits until no template, object or tape tile is being drawn (the ring around the view included).
    static func waitForFills(_ canvas: CanvasView) {
        let deadline = Date(timeIntervalSinceNow: 30)
        while [canvas.templateTiles, canvas.objectTiles, canvas.tapeTiles].contains(where: \.isFilling), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }

    /// The template, object and tape tiles drawn so far, and their drawing time added up.
    static func vectorFills(_ canvas: CanvasView) -> (tiles: Int, milliseconds: Double) {
        let layers = [canvas.templateTiles, canvas.objectTiles, canvas.tapeTiles]
        return (layers.map(\.stats.tilesFilled).reduce(0, +), layers.map(\.stats.fillMilliseconds).reduce(0, +))
    }

    /// The template tiles' drawing time so far.
    static func templateFillMilliseconds(_ canvas: CanvasView) -> Double {
        canvas.templateTiles.stats.fillMilliseconds
    }

    /// Forgets the template and object tiles of every level but the fitted page's, so a zoom draws its level afresh.
    static func forgetZoomedTiles(_ canvas: CanvasView) {
        for tiles in [canvas.templateTiles, canvas.objectTiles, canvas.tapeTiles] {
            guard let id = tiles.content?.cacheID else { continue }
            tiles.cache.removeAll(page: id, except: tiles.restingLevel)
        }
    }
}
