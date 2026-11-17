import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

private let hasMetal = WaxRenderer.shared != nil

/// Lets the main queue run until `done`, or fails after `timeout`.
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

/// How two images of the same size differ: the share of pixels off by more than `tolerance` of 255 in any
/// channel, and the largest difference in any channel.
private func difference(_ a: CGImage, _ b: CGImage, tolerance: Int = 2) -> (fraction: Double, largest: Int) {
    guard a.width == b.width, a.height == b.height, let da = rgba(a), let db = rgba(b) else { return (1, 255) }
    var differing = 0, largest = 0
    var i = 0
    while i + 3 < da.count {
        var off = false
        for c in 0 ..< 4 {
            let d = abs(Int(da[i + c]) - Int(db[i + c]))
            largest = max(largest, d)
            off = off || d > tolerance
        }
        differing += off ? 1 : 0
        i += 4
    }
    return (Double(differing) / Double(a.width * a.height), largest)
}

/// The image's pixels as premultiplied RGBA bytes.
private func rgba(_ image: CGImage) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: image.width * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setBlendMode(.copy)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

/// NOT-110: a stroke committed at the level it was written at takes its pixels from the live layer instead
/// of being drawn into the committed tiles again, and they're what drawing it would give.
@MainActor
// Serialized: a raster stroke waits for its wax on the main queue, which parallel cases keep busy for longer
// than a stroke waits before it is drawn anyway.
@Suite("Live hand-off", .serialized)
struct LiveHandOffTests {
    static let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    let document = CanvasDocument(pageSize: .letter)
    let canvas: CanvasView

    init() {
        canvas = CanvasView(frame: Self.bounds, document: document)
        canvas.traitOverrides.displayScale = 2
        canvas.layoutIfNeeded()
    }

    private var coordinator: RenderCoordinator {
        canvas.coordinator
    }

    /// The brushes to write with: every bundled one but the eraser, the crayon only with Metal.
    static let brushes: [BrushDescriptor] = BrushDescriptor.bundled.filter {
        !$0.erases && (!$0.isRaster || hasMetal)
    }

    /// Writes a stroke the way the canvas does, event by event through the live layer, then commits it
    /// as `endStroke` does. Waves across `y`, over several committed tiles.
    @discardableResult
    private func write(_ brush: BrushDescriptor, y: CGFloat, from x0: CGFloat = 40, to x1: CGFloat = 520) -> LiveStroke {
        let live = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA.swatches[2], brush: brush, points: []))
        canvas.live = live
        let steps = 90
        for i in 0 ... steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = StrokePoint(location: CGPoint(x: x0 + (x1 - x0) * t, y: y + sin(t * 9) * 40),
                                    force: 0.4 + 0.4 * t, altitude: .pi / 3, azimuth: 0.6,
                                    timestamp: Double(i) / 240)
            live.append(point, minSpacing: 0.15)
            canvas.invalidateLive(canvasRect: live.advance(predicted: []))
            canvas.liveView.displayPendingTiles()
        }
        if let (segment, dirty) = live.finish() {
            canvas.liveView.geometryChanged(of: live, fromSegment: segment, canvasRect: dirty)
            canvas.invalidateLive(canvasRect: dirty)
        }
        canvas.live = nil
        let geometry = live.geometry()
        coordinator.cache(geometry, for: live.stroke.id)
        let before = document.inkVersion
        canvas.editDocument { document.add(live.stroke) } // as `endStroke` does: not an edit from elsewhere
        coordinator.strokeCommitted(live, geometry: geometry, revisionBefore: before)
        return live
    }

    /// The page drawn from scratch at the canvas's transform.
    private func reference() throws -> CGImage {
        let items = document.strokes.map {
            CommittedRenderer.Item(id: $0.id, brush: $0.brush, color: $0.color, geometry: nil, stroke: $0)
        }
        let ctx = try #require(CommittedRenderer.makeBitmap(pixelSize: coordinator.pixelSize, scale: 2))
        CommittedRenderer.render(items, into: ctx, bounds: Self.bounds, transform: canvas.viewTransform)
        return try #require(ctx.makeImage())
    }

    /// Each cached tile at the displayed level against the same tile filled from scratch.
    private func expectTilesMatchFills(_ comment: Comment) throws {
        let geometry = Dictionary(document.strokes.map { ($0.id, StrokeRenderer.keptGeometry(for: $0)) },
                                  uniquingKeysWith: { $1 })
        let ink = InkSnapshot(strokes: document.strokes, index: document.strokeIndex, geometry: geometry, skipped: [])
        let level = coordinator.displayedLevel
        var compared = 0
        for (key, tile) in coordinator.cache.tiles(page: document.cacheID) where key.level == level {
            let filled = RenderCoordinator.draw(key, from: ink, revision: document.inkVersion,
                                                filler: CoreGraphicsTileFiller()).image
            guard let shown = tile.image, let filled else {
                // Neither has ink, or the one that has an image is blank.
                let one = tile.image ?? filled
                #expect(one.flatMap(rgba).map { $0.allSatisfy { $0 == 0 } } ?? true, "\(comment) tile \(key.col),\(key.row)")
                continue
            }
            let diff = difference(shown, filled)
            // Laying the stroke's own pixels on rounds once more than drawing it on does: a level or two at
            // its anti-aliased edges.
            #expect(diff.fraction < 0.002, "\(comment) tile \(key.col),\(key.row): \(diff)")
            compared += 1
        }
        #expect(compared > 0)
    }

    @Test(arguments: brushes)
    func aStrokeCommittedAtItsOwnLevelIsLaidOnNotFilledAgain(brush: BrushDescriptor) async throws {
        document.add(Stroke(id: UUID(), color: RGBA.swatches[0], brush: .pen, points: (0 ..< 30).map {
            StrokePoint(location: CGPoint(x: 80 + CGFloat($0) * 14, y: 300), force: 0.6, altitude: .pi / 2,
                        azimuth: 0, timestamp: Double($0) / 240)
        }))
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
        let before = coordinator.fillStats
        write(brush, y: 300)
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling && coordinator.pending.isEmpty }
        let stats = coordinator.fillStats
        if brush.blend == .normal {
            #expect(stats.finishedStrokeFills == before.finishedStrokeFills, "\(brush.name) was filled again")
            #expect(stats.finishedStrokeCopies > before.finishedStrokeCopies)
        } else {
            // Multiply needs what's under it: drawn from its geometry, as before.
            #expect(stats.finishedStrokeFills > before.finishedStrokeFills)
        }
        try expectTilesMatchFills(Comment(rawValue: brush.name))
        // Grain drawn over the whole page at once (`CommittedRenderer`) differs from tiles by more than this
        // whoever draws them; the tiles are held to fills above.
        if !brush.usesPattern {
            let whole = try difference(#require(coordinator.composedImage()), reference())
            #expect(whole.fraction < 0.002, "\(whole)")
        }
    }

    @Test func zoomedInTheStrokeIsStillLaidOnAtThatLevel() async throws {
        canvas.gestureBegan()
        canvas.zoom(by: 2.37, about: CGPoint(x: 233, y: 371))
        canvas.gestureEnded()
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
        let before = coordinator.fillStats
        let page = canvas.viewTransform.toCanvas(CGRect(x: 20, y: 300, width: 560, height: 10))
        write(.pencil, y: page.midY, from: page.minX, to: page.maxX)
        write(.pen, y: page.midY + 20, from: page.minX, to: page.maxX)
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling && coordinator.pending.isEmpty }
        // The resting (fitted) level's tiles are filled; the level written at takes the live layer's pixels.
        #expect(coordinator.fillStats.finishedStrokeCopies > before.finishedStrokeCopies)
        try expectTilesMatchFills("zoomed")
    }

    @Test func aStrokeRunningOffScreenIsFilledWhereTheLiveLayerNeverDrewIt() async throws {
        canvas.gestureBegan()
        canvas.zoom(by: 3, about: CGPoint(x: 300, y: 400))
        canvas.gestureEnded()
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
        // Cache the tiles past the right edge too, as a pan there and back would.
        canvas.gestureBegan()
        canvas.pan(by: CGPoint(x: -500, y: 0))
        canvas.gestureEnded()
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
        canvas.gestureBegan()
        canvas.pan(by: CGPoint(x: 500, y: 0))
        canvas.gestureEnded()
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
        let before = coordinator.fillStats
        let view = canvas.viewTransform
        let left = view.toCanvas(CGPoint(x: 100, y: 400)), right = view.toCanvas(CGPoint(x: 900, y: 400))
        write(.pen, y: left.y, from: left.x, to: right.x)
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling && coordinator.pending.isEmpty }
        #expect(coordinator.fillStats.finishedStrokeCopies > before.finishedStrokeCopies)
        #expect(coordinator.fillStats.finishedStrokeFills > before.finishedStrokeFills)
        try expectTilesMatchFills("off screen")
    }

    @Test func liveTilesLieOnTheCommittedGrid() throws {
        canvas.gestureBegan()
        canvas.zoom(by: 1.7, about: CGPoint(x: 211, y: 157))
        canvas.gestureEnded()
        let live = write(.pen, y: 200)
        // While it waits to be drawn, the hand-off covers its tiles at the canvas's level.
        let baked = try #require(canvas.liveView.bakedInk(of: live))
        #expect(baked.level == TileLevel(canvas.viewTransform, displayScale: 2))
        #expect(baked.tiles.values.contains { $0 != nil })
        for (key, image) in baked.tiles {
            guard let image else { continue }
            #expect(image.width == LiveInkView.tilePixels, "\(key)")
        }
    }
}
