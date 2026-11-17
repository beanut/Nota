import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// A wavy stroke across the page at `y`, as a finished `LiveStroke` (what `endStroke` hands on).
@MainActor
private func finishedStroke(y: CGFloat, brush: BrushDescriptor = .pen) -> LiveStroke {
    let live = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA.swatches[0], brush: brush, points: []))
    for i in 0 ..< 40 {
        let x = 60 + CGFloat(i) * 8
        let point = StrokePoint(location: CGPoint(x: x, y: y + sin(CGFloat(i) / 3) * 12), force: 0.7,
                                altitude: .pi / 3, azimuth: 0.4, timestamp: Double(i) / 240)
        _ = live.append(point, minSpacing: 0.15)
    }
    _ = live.advance(predicted: [])
    _ = live.finish()
    return live
}

/// Lets the main queue run until `done`, or fails after `timeout`.
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

/// The committed side split out of `CanvasView` (NOT-100): renders, finished strokes and the settled
/// state, on a real canvas.
@MainActor
@Suite("Render coordinator")
struct RenderCoordinatorTests {
    static let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    let document = CanvasDocument(pageSize: .letter)
    let canvas: CanvasView

    init() throws {
        canvas = CanvasView(frame: Self.bounds, document: document)
        canvas.traitOverrides.displayScale = 2
        canvas.layoutIfNeeded()
    }

    private var coordinator: RenderCoordinator {
        canvas.coordinator
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

    @Test func aNewCanvasSettlesWithAPublishedImageOfItsSurface() async throws {
        try await waitUntil { coordinator.isSettled }
        #expect(canvas.rendersSettled)
        let image = try #require(coordinator.publishedImage)
        #expect(CGFloat(image.width) == coordinator.pixelSize.width)
        #expect(CGFloat(image.height) == coordinator.pixelSize.height)
        #expect(coordinator.pixelSize == CGSize(width: 1200, height: 1600))
        #expect(coordinator.displayedTransform == canvas.viewTransform)
        #expect(canvas.liveView.underlay === image)
    }

    @Test func aCommittedStrokeIsDrawnIntoThePublishedImage() async throws {
        try await waitUntil { coordinator.isSettled }
        let live = finishedStroke(y: 200)
        let geometry = live.geometry()
        let before = document.revision
        document.add(live.stroke)
        coordinator.strokeCommitted(live, geometry: geometry, revisionBefore: before)
        #expect(!coordinator.isSettled) // waiting to be drawn
        #expect(coordinator.pending.count == 1)
        try await waitUntil { coordinator.isSettled }
        #expect(coordinator.pending.isEmpty)
        #expect(coordinator.geometryCache[live.stroke.id] != nil)
        let shown = try #require(coordinator.publishedImage)
        #expect(try differingFraction(shown, reference()) < 0.001)
    }

    @Test func invalidatingARectRedrawsThePageAsItIs() async throws {
        let first = finishedStroke(y: 150), second = finishedStroke(y: 400, brush: .highlighter)
        document.add(first.stroke)
        document.add(second.stroke)
        coordinator.invalidateAll()
        try await waitUntil { coordinator.isSettled }
        #expect(try differingFraction(#require(coordinator.publishedImage), reference()) < 0.001)

        let bounds = coordinator.geometry(for: first.stroke).bounds
        coordinator.forgetGeometry(first.stroke.id)
        _ = document.remove(ids: [first.stroke.id])
        coordinator.invalidate(rect: bounds)
        #expect(!coordinator.isSettled)
        try await waitUntil { coordinator.isSettled }
        #expect(try differingFraction(#require(coordinator.publishedImage), reference()) < 0.001)
    }

    @Test func aRenderDiscardedInFlightStillSettlesOnTheNextOne() async throws {
        try await waitUntil { coordinator.isSettled }
        document.add(finishedStroke(y: 300).stroke)
        coordinator.invalidateAll()
        coordinator.discardInFlight()
        coordinator.requestRender()
        try await waitUntil { coordinator.isSettled }
        #expect(try differingFraction(#require(coordinator.publishedImage), reference()) < 0.001)
    }

    @Test func movingTheViewUnsettlesItUntilARenderAtTheNewTransformLands() async throws {
        try await waitUntil { coordinator.isSettled }
        canvas.gestureBegan()
        canvas.zoom(by: 2, about: CGPoint(x: 300, y: 400))
        #expect(!coordinator.isSettled)
        canvas.gestureEnded()
        try await waitUntil { coordinator.isSettled }
        #expect(coordinator.displayedTransform == canvas.viewTransform)
        #expect(coordinator.targetTransform == canvas.viewTransform)
    }

    @Test func theVisibleRectIsTheSurfaceInPagePoints() {
        let transform = ViewTransform(scale: 2, offset: CGPoint(x: -100, y: 40))
        let visible = coordinator.visibleRect(for: transform)
        #expect(visible == CGRect(x: 50, y: -20, width: 300, height: 400))
    }

    @Test func aSnapshotDrawsTheInkReachingItsBounds() async throws {
        let live = finishedStroke(y: 200)
        document.add(live.stroke)
        var snapshot: CGImage?
        var done = false
        let transform = ViewTransform(scale: 3, offset: CGPoint(x: -150, y: -500))
        coordinator.renderSnapshot(bounds: CGRect(x: 0, y: 0, width: 200, height: 100), transform: transform) {
            snapshot = $0
            done = true
        }
        try await waitUntil { done }
        let image = try #require(snapshot)
        #expect(image.width == 400)
        #expect(image.height == 200)
    }
}

@Suite("Canvas viewport")
struct CanvasViewportTests {
    @Test func snappingPutsTheOffsetOnWholeDevicePixels() {
        let t = ViewTransform(scale: 1.37, offset: CGPoint(x: 10.3, y: -4.71))
        let snapped = t.snapped(toPixels: 2)
        #expect(snapped.scale == t.scale)
        #expect(snapped.offset == CGPoint(x: 10.5, y: -4.5))
        #expect(snapped.snapped(toPixels: 2) == snapped)
        #expect(t.snapped(toPixels: 3).offset.x * 3 == (10.3 * 3).rounded())
        #expect(t.snapped(toPixels: 0) == t)
    }

    @Test func settlingReportsWhetherTheTransformMoved() {
        var viewport = CanvasViewport()
        viewport.transform = ViewTransform(scale: 2, offset: CGPoint(x: 3.25, y: 1))
        let moved = viewport.settleOnPixelGrid(displayScale: 2)
        #expect(moved)
        #expect(viewport.transform.offset == CGPoint(x: 3.5, y: 1))
        let movedAgain = viewport.settleOnPixelGrid(displayScale: 2)
        #expect(!movedAgain)
    }

    @Test func zoomingOutPastTheFittedScaleLandsExactlyOnTheFittedPage() {
        let fitted = ViewTransform(scale: 1, offset: CGPoint(x: 40, y: 20))
        var viewport = CanvasViewport()
        viewport.transform = ViewTransform(scale: 3, offset: CGPoint(x: -500, y: -300))
        viewport.zoom(by: 0.1, about: CGPoint(x: 200, y: 200), fitted: fitted, displayScale: 0)
        #expect(viewport.transform == fitted)
        viewport.zoom(by: 100, about: CGPoint(x: 200, y: 200), fitted: fitted, displayScale: 0)
        #expect(viewport.transform.scale == ViewTransform.maxZoomFactor)
    }

    @Test func gestureStepsStayOnThePixelGridWithoutLosingSlowMovement() {
        var viewport = CanvasViewport()
        viewport.transform = ViewTransform(scale: 1, offset: .zero)
        for _ in 0 ..< 10 {
            viewport.pan(by: CGPoint(x: 0.1, y: -0.2), displayScale: 2) // each step under half a pixel
        }
        #expect(viewport.transform.offset == CGPoint(x: 1, y: -2))
        viewport.pan(by: CGPoint(x: 0.3, y: 0), displayScale: 2)
        #expect(viewport.transform.offset.x == 1.5)
        viewport.zoom(by: 1.3, about: CGPoint(x: 101.7, y: 33.3),
                      fitted: ViewTransform(scale: 0.5, offset: .zero), displayScale: 2)
        let offset = viewport.transform.offset
        #expect((offset.x * 2).rounded() == offset.x * 2 && (offset.y * 2).rounded() == offset.y * 2)
        #expect(viewport.transform.scale == 1.3)
    }

    @Test func aZoomKeepsThePointUnderTheFingersFixed() {
        let fitted = ViewTransform(scale: 1, offset: .zero)
        var viewport = CanvasViewport()
        viewport.transform = ViewTransform(scale: 2, offset: CGPoint(x: -100, y: -100))
        let focus = CGPoint(x: 300, y: 250)
        let under = viewport.transform.toCanvas(focus)
        viewport.zoom(by: 1.5, about: focus, fitted: fitted, displayScale: 0)
        let after = viewport.transform.toView(under)
        #expect(abs(after.x - focus.x) < 1e-9 && abs(after.y - focus.y) < 1e-9)
    }

    @Test func theSlideBackEasesOutAndArrives() {
        let from = ViewTransform(scale: 1, offset: CGPoint(x: 100, y: 0))
        let to = ViewTransform(scale: 1, offset: .zero)
        let slide = CanvasViewport.Slide(from: from, to: to, start: 10)
        #expect(slide.transform(at: 10).transform == from)
        #expect(!slide.transform(at: 10).done)
        let half = slide.transform(at: 10 + CanvasViewport.Slide.duration / 2).transform.offset.x
        #expect(half < 50) // ease out: more than half way at half time
        let end = slide.transform(at: 10 + CanvasViewport.Slide.duration)
        #expect(end.transform == to)
        #expect(end.done)
    }

    @MainActor
    @Test func aCanvasSettlesItsOwnGesturesOnThePixelGrid() {
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 601, height: 803), document: CanvasDocument(pageSize: .a4))
        canvas.traitOverrides.displayScale = 2
        canvas.layoutIfNeeded()
        let onGrid = { (t: ViewTransform) in
            (t.offset.x * 2).rounded() == t.offset.x * 2 && (t.offset.y * 2).rounded() == t.offset.y * 2
        }
        #expect(onGrid(canvas.fittedTransform()))
        #expect(canvas.viewTransform == canvas.fittedTransform())
        canvas.gestureBegan()
        canvas.zoom(by: 1.37, about: CGPoint(x: 211.3, y: 377.7))
        canvas.pan(by: CGPoint(x: 3.3, y: -7.1))
        canvas.gestureEnded()
        #expect(onGrid(canvas.viewTransform))
        #expect(canvas.viewTransform.scale == canvas.fittedTransform().scale * 1.37)
    }
}

@Suite("Estimate tracker")
struct EstimateTrackerTests {
    @Test func aStrokeIsOutstandingUntilEverySampleIsResolved() {
        var tracker = EstimateTracker()
        let stroke = UUID()
        tracker.expect(1, strokeID: stroke, index: 0)
        tracker.expect(2, strokeID: stroke, index: 1)
        #expect(tracker.count == 2)
        #expect(tracker.isOutstanding(stroke))
        #expect(tracker.point(for: 2) == EstimateTracker.PointRef(strokeID: stroke, index: 1))
        tracker.resolve(1)
        #expect(tracker.isOutstanding(stroke))
        tracker.resolve(2)
        #expect(!tracker.isOutstanding(stroke))
        #expect(tracker.point(for: 2) == nil)
        tracker.resolve(2) // already resolved: nothing changes
        #expect(tracker.count == 0)
    }

    @Test func aKeyReusedForAnotherPointReleasesTheOldOne() {
        var tracker = EstimateTracker()
        let a = UUID(), b = UUID()
        tracker.expect(7, strokeID: a, index: 3)
        tracker.expect(7, strokeID: b, index: 0)
        #expect(!tracker.isOutstanding(a))
        #expect(tracker.isOutstanding(b))
        #expect(tracker.count == 1)
    }

    @Test func tooManyUnresolvedSamplesAreGivenUp() {
        var tracker = EstimateTracker()
        let stroke = UUID()
        for i in 0 ... EstimateTracker.limit {
            tracker.expect(NSNumber(value: i), strokeID: stroke, index: i)
        }
        tracker.pruneIfOverflowing()
        #expect(tracker.count == 0)
        #expect(!tracker.isOutstanding(stroke))
        tracker.expect(1, strokeID: stroke, index: 0)
        tracker.pruneIfOverflowing()
        #expect(tracker.count == 1)
    }

    @Test func fingerForceIsHeavySlowAndLightFast() {
        var input = CanvasInput()
        let first = input.fingerForce(at: .zero, time: 0, predicted: false)
        #expect(first == 0.6)
        // Slow: barely moving, the force rises towards 1.
        let slow = input.fingerForce(at: CGPoint(x: 1, y: 0), time: 0.1, predicted: false)
        #expect(slow > 0.6)
        // A predicted sample doesn't move the model on.
        _ = input.fingerForce(at: CGPoint(x: 5000, y: 0), time: 0.2, predicted: true)
        #expect(input.fingerPrevious?.force == slow)
        let fast = input.fingerForce(at: CGPoint(x: 2000, y: 0), time: 0.2, predicted: false)
        #expect(fast < slow)
    }
}
