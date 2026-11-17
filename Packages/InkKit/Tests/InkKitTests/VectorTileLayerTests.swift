import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// Lets the main queue run until `done`, or fails after `timeout`.
@MainActor
private func waitUntil(timeout: TimeInterval = 20, _ done: () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done() {
        guard Date() < deadline else {
            Issue.record("timed out")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// The template, object and tape layers drawn into tiles through the tile cache and scheduler (NOT-109).
@MainActor
@Suite("Vector tile layers")
struct VectorTileLayerTests {
    static let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    static let style = ShapeStyle(color: PenColor(rgb: 0x1C1C1E), lineWidth: 3)

    let document: CanvasDocument
    let canvas: CanvasView

    init() {
        document = CanvasDocument(pageSize: .letter, template: PageTemplate(pattern: .ruled, spacing: 24))
        canvas = CanvasView(frame: Self.bounds, document: document)
        canvas.traitOverrides.displayScale = 2
    }

    private func addObjects() {
        canvas.editDocument {
            document.addObject(ShapeObject(.rectangle, frame: CGRect(x: 80, y: 120, width: 200, height: 120), style: Self.style))
            document.addObject(ShapeObject(.arrow, points: [CGPoint(x: 100, y: 400), CGPoint(x: 420, y: 400)],
                                           style: Self.style))
            document.addObject(TextObject(origin: CGPoint(x: 300, y: 220), width: 200, text: RichText("Tiles, not vectors")))
            document.addObject(TapeObject(from: CGPoint(x: 80, y: 600), to: CGPoint(x: 400, y: 620), color: PenColor(rgb: 0xE8D7A9)))
        }
        canvas.refreshObjects()
    }

    private var layers: [VectorTileLayer] {
        [canvas.templateTiles, canvas.objectTiles, canvas.tapeTiles]
    }

    /// Waits until the template, objects and tape are sharp and nothing more (the margin) is being drawn.
    private func settle() async throws {
        try await waitUntil { canvas.vectorLayersSettled && !layers.contains(where: \.isFilling) }
    }

    private func zoom(by k: CGFloat) {
        canvas.gestureBegan()
        canvas.zoom(by: k, about: CGPoint(x: 300, y: 400))
        canvas.gestureEnded()
    }

    @Test("A pan at one zoom draws no template or object tiles")
    func panDrawsNothing() async throws {
        canvas.layoutIfNeeded()
        addObjects()
        zoom(by: 2)
        try await settle()
        let before = layers.map(\.stats.tilesFilled)
        #expect(before.allSatisfy { $0 > 0 })
        // Back and forth within the ring of tiles kept around the view.
        canvas.gestureBegan()
        for step in 0 ..< 20 {
            canvas.pan(by: CGPoint(x: step < 10 ? -4 : 4, y: step < 10 ? 3 : -3))
        }
        canvas.gestureEnded()
        try await settle()
        #expect(layers.map(\.stats.tilesFilled) == before)
        #expect(canvas.templateTiles.displayedLevel == TileLevel(canvas.viewTransform, displayScale: 2))
    }

    @Test("Settled after a zoom, each layer shows the transform's own level")
    func zoomSettlesAtItsLevel() async throws {
        canvas.layoutIfNeeded()
        addObjects()
        try await settle()
        zoom(by: 2.7)
        try await settle()
        let level = TileLevel(canvas.viewTransform, displayScale: 2)
        for tiles in layers {
            #expect(tiles.displayedLevel == level)
            #expect(tiles.shownImages.allSatisfy { $0.key.level == level })
        }
    }

    @Test("Changing an object draws only the tiles it reaches, and no template")
    func objectChangeRedrawsItsTiles() async throws {
        canvas.layoutIfNeeded()
        addObjects()
        try await settle()
        let template = canvas.templateTiles.stats.tilesFilled, objects = canvas.objectTiles.stats
        let tape = canvas.tapeTiles.stats.tilesFilled
        let shape = ShapeObject(.ellipse, frame: CGRect(x: 30, y: 30, width: 20, height: 20), style: Self.style)
        canvas.editDocument { document.addObject(shape) }
        canvas.refreshObjects()
        try await settle()
        let filled = canvas.objectTiles.stats.tilesFilled - objects.tilesFilled
        let level = canvas.objectTiles.displayedLevel ?? TileLevel(canvas.viewTransform, displayScale: 2)
        let reached = TileKey.keys(covering: ObjectDiff.reach(of: shape), page: document.objectTileHistory.cacheID,
                                   level: level).count
        #expect(filled >= 1)
        #expect(filled <= reached)
        #expect(canvas.templateTiles.stats.tilesFilled == template)
        #expect(canvas.tapeTiles.stats.tilesFilled == tape)
    }

    @Test("Object tiles show what drawing the objects whole shows")
    func tilesMatchVectors() async throws {
        canvas.layoutIfNeeded()
        addObjects()
        zoom(by: 1.6)
        try await settle()
        let t = canvas.viewTransform
        let pixels = RenderCoordinator.pixelSize(of: Self.bounds.size, scale: 2)
        let shownCtx = try #require(TileBitmap.viewBitmap(pixelSize: pixels, scale: 2))
        TileBitmap.compose(canvas.objectTiles.shownImages, at: t, in: shownCtx)
        let shown = try #require(shownCtx.makeImage())
        let wholeCtx = try #require(TileBitmap.viewBitmap(pixelSize: pixels, scale: 2))
        let content = try #require(canvas.objectTiles.content)
        wholeCtx.concatenate(t.affine)
        let visible = t.toCanvas(Self.bounds).intersection(document.pageBounds)
        wholeCtx.clip(to: visible)
        content.draw(wholeCtx, visible, TileLevel(t, displayScale: 2))
        let whole = try #require(wholeCtx.makeImage())
        #expect(differingFraction(shown, whole) < 0.003)
    }

    @Test("A selection dragged moves one image of its objects, and they land back in their tiles")
    func dragMovesFloatingImage() async throws {
        canvas.layoutIfNeeded()
        addObjects()
        try await settle()
        let shape = try #require(document.objects.first { $0 is ShapeObject })
        let selection = PageSelection(objectIDs: [shape.id])
        let box = SelectionBox(rect: shape.bounds)
        var drag = CanvasView.SelectionDrag(handle: .move, start: shape.bounds.origin, box: box,
                                            session: document.beginTransform(selection))
        canvas.lassoSession = .transforming(drag)
        for step in 1 ... 30 {
            drag.transform = CGAffineTransform(translationX: CGFloat(step) * 3, y: CGFloat(step))
            canvas.lassoSession = .transforming(drag)
            canvas.preview(drag)
        }
        #expect(canvas.objectFloat.isShowing)
        #expect(canvas.objectFloat.drawCount == 1)
        try await settle()
        // The tiles left the dragged shape out once, and nothing since.
        let lifted = canvas.objectTiles.stats.tilesFilled
        drag.transform = CGAffineTransform(translationX: 100, y: 40)
        canvas.lassoSession = .transforming(drag)
        canvas.preview(drag)
        try await settle()
        #expect(canvas.objectTiles.stats.tilesFilled == lifted)

        canvas.finishLasso(commit: true)
        // Put down, it shows floating until its tiles are drawn, then only in them.
        try await settle()
        try await waitUntil { !canvas.objectFloat.isShowing }
        let moved = try #require(document.objects.first { $0.id == shape.id })
        #expect(abs(moved.bounds.minX - shape.bounds.minX - 100) < 0.01)
    }

    @Test("Pages on the same template share its tiles")
    func templateTilesShared() {
        let paper = TemplatePaper(template: PageTemplate(pattern: .grid, spacing: 20), pageSize: .letter)
        let other = paper
        #expect(paper.tileContent()?.cacheID == other.tileContent()?.cacheID)
        var cream = paper
        cream.palette = .standard(.cream)
        #expect(paper.tileContent()?.cacheID != cream.tileContent()?.cacheID)
        #expect(TemplatePaper(template: PageTemplate(pattern: .blank, spacing: 20)).tileContent() == nil)
    }

    @Test("What changed between two lists of objects")
    func objectDiff() {
        let a = ShapeObject(.rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), style: Self.style)
        let b = ShapeObject(.rectangle, frame: CGRect(x: 100, y: 100, width: 10, height: 10), style: Self.style)
        #expect(ObjectDiff.touched(from: [a, b], to: [a, b]).isNull)
        let movedB = b.applying(CGAffineTransform(translationX: 50, y: 0))
        let touched = ObjectDiff.touched(from: [a, b], to: [a, movedB])
        #expect(touched.contains(b.bounds) && touched.contains(movedB.bounds) && !touched.intersects(a.bounds))
        #expect(ObjectDiff.touched(from: [a], to: [a, b]).contains(b.bounds))
        #expect(ObjectDiff.touched(from: [a, b], to: [b]).contains(a.bounds))
        let restacked = ObjectDiff.touched(from: [a, b], to: [b, a])
        #expect(restacked.contains(a.bounds) && restacked.contains(b.bounds))
        // An arrow's head reaches past its points' bounds.
        let arrow = ShapeObject(.arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)], style: Self.style)
        #expect(ObjectDiff.reach(of: arrow).height > 10)
    }

    @Test("A change log knows what changed since a version, until it forgets")
    func changeLog() {
        var log = VectorChangeLog()
        log.record(CGRect(x: 0, y: 0, width: 10, height: 10), version: 1)
        log.record(CGRect(x: 50, y: 50, width: 10, height: 10), version: 2)
        #expect(log.touched(from: 1, to: 2) == CGRect(x: 50, y: 50, width: 10, height: 10))
        #expect(log.touched(from: 0, to: 2) == CGRect(x: 0, y: 0, width: 60, height: 60))
        #expect(log.touched(from: 2, to: 2)?.isNull == true)
        for v in 3 ... 3 + VectorChangeLog.limit {
            log.record(.zero, version: v)
        }
        #expect(log.touched(from: 0, to: 3 + VectorChangeLog.limit) == nil)
    }
}

/// The fraction of pixels that differ by more than 2 of 255 in any channel.
private func differingFraction(_ a: CGImage, _ b: CGImage) -> Double {
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
