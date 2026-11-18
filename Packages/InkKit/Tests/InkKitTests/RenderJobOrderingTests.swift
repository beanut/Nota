import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// A stroke across the page at `y`.
private func stroke(y: CGFloat) -> Stroke {
    let points = (0 ..< 60).map { i in
        StrokePoint(location: CGPoint(x: 20 + CGFloat(i) * 9, y: y + sin(CGFloat(i) / 3) * 10), force: 0.6,
                    altitude: .pi / 3, azimuth: 0.4, timestamp: Double(i) / 240)
    }
    return Stroke(id: UUID(), color: RGBA.swatches[0], brush: .pen, points: points)
}

@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ done: () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done() {
        guard Date() < deadline else {
            Issue.record("timed out")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Fills tiles as Core Graphics does, but only once its gate is open, ignoring cancellation (so a job that
/// was dropped still finishes its work), and records the order tiles were filled in.
private final class GatedFiller: TileFiller, @unchecked Sendable { // guarded by `condition`
    private let condition = NSCondition()
    private var open: Bool
    private var order: [TileKey] = []

    init(open: Bool) {
        self.open = open
    }

    func setOpen(_ value: Bool) {
        condition.withLock {
            open = value
            condition.broadcast()
        }
    }

    var filled: [TileKey] {
        condition.withLock { order }
    }

    func fill(_ key: TileKey, region: CGRect?, strokes: [TileStroke], into ctx: CGContext,
              isCancelled _: () -> Bool) -> Int {
        condition.withLock {
            while !open {
                condition.wait()
            }
            order.append(key)
        }
        return CoreGraphicsTileFiller().fill(key, region: region, strokes: strokes, into: ctx)
    }
}

/// What worker threads record, in order.
private final class Log: @unchecked Sendable { // guarded by `lock`
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }

    var all: [String] {
        lock.withLock { items }
    }
}

/// Just enough of a canvas to host a coordinator.
@MainActor
private final class Host: RenderCoordinatorHost {
    var renderTransform = ViewTransform()
    var renderBounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    var restingScale: CGFloat = 1
    var isMoving = false
    var isEditingInk = false
    var pencilLocation: CGPoint?
    func fittedTransform() -> ViewTransform {
        ViewTransform()
    }

    func hasOutstandingEstimates(for _: UUID) -> Bool {
        false
    }

    func renderCoordinatorNeedsLayout() {}
    func renderCoordinatorDidPublish() {}
    func renderCoordinatorDidDrawPending(canvasRect _: CGRect) {}
}

/// The coordinator's fills on the render scheduler (NOT-103): which tiles go first, and that a fill
/// overtaken by a change or a discard never puts its pixels in the cache.
@MainActor
@Suite("Render jobs", .serialized)
struct RenderJobOrderingTests {
    let document = CanvasDocument(pageSize: .letter)
    private let host = Host()
    let cache = TileCache(byteBudget: 64 << 20)

    private func coordinator(filler: GatedFiller, workers: Int = 4) -> RenderCoordinator {
        let scheduler = RenderScheduler(limits: .init(idle: workers, gesture: workers, lowPriority: 1),
                                        frameInterval: 0)
        let coordinator = RenderCoordinator(document: document, embedded: true, cache: cache, filler: filler,
                                            scheduler: scheduler)
        coordinator.host = host
        return coordinator
    }

    @Test func visibleTilesFillCentreOutBeforeTheMarginAndThePencilsTileFirst() async throws {
        for y in stride(from: 40, through: 760, by: 40) {
            document.add(stroke(y: CGFloat(y)))
        }
        host.renderTransform = ViewTransform(scale: 3, offset: CGPoint(x: -600, y: -900))
        let pencil = CGPoint(x: 220, y: 320) // near the bottom right of the view
        host.pencilLocation = pencil
        let filler = GatedFiller(open: false)
        let coordinator = coordinator(filler: filler, workers: 1)
        coordinator.resize(to: host.renderBounds, scale: 2)
        filler.setOpen(true)
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }

        let level = coordinator.level(for: host.renderTransform)
        let visible = coordinator.visibleKeys(at: host.renderTransform, level: level, centreOut: true)
        // Only tiles with ink reach the filler.
        let filled = filler.filled
        #expect(filled.allSatisfy { $0.level == level })
        let inked = Set(filled)
        let underPencil = visible.filter { $0.rect.insetBy(dx: -8, dy: -8).contains(pencil) }
        #expect(!underPencil.isEmpty)
        // One worker, every job queued before the first started: under the Pencil, then the rest in view
        // from the middle out, then the margin.
        let expected = (underPencil + visible.filter { !underPencil.contains($0) }).filter(inked.contains)
        #expect(Array(filled.prefix(expected.count)) == expected)
        let margin = filled.dropFirst(expected.count)
        #expect(!margin.isEmpty)
        #expect(margin.allSatisfy { !visible.contains($0) })
    }

    @Test func aDiscardedFillNeverPublishesItsPixels() async throws {
        document.add(stroke(y: 300))
        let filler = GatedFiller(open: false)
        let coordinator = coordinator(filler: filler)
        coordinator.resize(to: host.renderBounds, scale: 2)
        #expect(coordinator.isFilling)
        coordinator.discardInFlight()
        #expect(!coordinator.isFilling)
        filler.setOpen(true) // the running jobs finish their work anyway
        try await waitUntil { coordinator.scheduler.counts == (0, 0) }
        try await Task.sleep(nanoseconds: 30_000_000) // and their batch is published
        #expect(cache.tiles(page: document.cacheID).isEmpty)
        #expect(coordinator.fillStats.tilesFilled == 0)
        #expect(!coordinator.isSettled)

        coordinator.requestRender()
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
        #expect(coordinator.fillStats.tilesFilled > 0)
    }

    @Test func fillsOvertakenByAnEditAreDroppedOrRefilledAndTheNewRevisionLands() async throws {
        for y in stride(from: 40, through: 760, by: 60) {
            document.add(stroke(y: CGFloat(y)))
        }
        let filler = GatedFiller(open: false)
        let workers = 2
        let coordinator = coordinator(filler: filler, workers: workers)
        coordinator.resize(to: host.renderBounds, scale: 2)
        let first = document.inkVersion
        // Another stroke before any fill lands: the queued jobs drawing `first` are dropped; the ones
        // already running finish, and their tiles are filled again.
        document.add(stroke(y: 500))
        coordinator.invalidateAll()
        #expect(document.inkVersion != first)
        filler.setOpen(true)
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
        let level = coordinator.level(for: host.renderTransform)
        let keys = coordinator.visibleKeys(at: host.renderTransform, level: level)
        #expect(cache.tiles(for: keys).allSatisfy { $0?.revision == document.inkVersion })
        // One fill per tile for the new revision, plus at most the ones that were running for the old.
        let tiles = cache.tiles(page: document.cacheID).count
        #expect(coordinator.fillStats.tilesFilled >= tiles)
        #expect(coordinator.fillStats.tilesFilled <= tiles + workers)
        // And they're the page as it is.
        let snapshot = InkSnapshot(strokes: document.strokes, index: document.strokeIndex,
                                   geometry: Dictionary(uniqueKeysWithValues: document.strokes.map {
                                       ($0.id, StrokeRenderer.keptGeometry(for: $0))
                                   }), skipped: [])
        for key in keys {
            let expected = RenderCoordinator.draw(key, from: snapshot, revision: 0, filler: CoreGraphicsTileFiller())
            let held = try #require(cache.tile(for: key))
            #expect(held.image?.dataProvider?.data == expected.image?.dataProvider?.data)
        }
    }

    @Test func fillsDuringAGestureRunOnFewerWorkers() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 6, gesture: 2, lowPriority: 1), frameInterval: 0)
        host.isMoving = true
        let coordinator = RenderCoordinator(document: document, embedded: true, cache: cache,
                                            filler: CoreGraphicsTileFiller(), scheduler: scheduler)
        coordinator.host = host
        coordinator.resize(to: host.renderBounds, scale: 2)
        // The coordinator told the scheduler its view is moving: any job now waits for one of two workers.
        let gate = DispatchSemaphore(value: 0)
        let log = Log()
        for _ in 0 ..< 4 {
            scheduler.submit(RenderJob(priority: .underPencil, work: { _ -> Bool? in
                log.append("started")
                gate.wait()
                return true
            }, publish: { (_: Bool?) in }))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(scheduler.counts.running <= 2)
        host.isMoving = false
        coordinator.updateLayerTransform() // the gesture ended
        try await waitUntil { log.all.count == 4 }
        for _ in 0 ..< 4 {
            gate.signal()
        }
        try await waitUntil { scheduler.counts == (0, 0) }
    }
}
