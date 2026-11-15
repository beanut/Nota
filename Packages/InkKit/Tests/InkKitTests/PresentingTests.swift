import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

@Suite("Laser pointer: fading and expiry")
struct LaserTrailTests {
    @Test func aTrailFadesOverASecondAndIsGoneAfterIt() {
        var trail = LaserTrail(mode: .trail)
        trail.begin(at: CGPoint(x: 0, y: 0), time: 10)
        trail.move(to: CGPoint(x: 10, y: 0), time: 10.2)
        trail.move(to: CGPoint(x: 20, y: 0), time: 10.4)
        trail.end(time: 10.4)
        #expect(trail.points.count == 3)
        let first = trail.points[0]
        #expect(abs(trail.opacity(of: first, now: 10.5) - 0.5) < 1e-9)
        trail.prune(now: 11.3) // the first two have faded away
        #expect(trail.points.map(\.location.x) == [20])
        #expect(trail.points[0].startsLine) // what's left is a line of its own
        #expect(!trail.isEmpty)
        trail.prune(now: 11.5)
        #expect(trail.isEmpty)
    }

    @Test func thePointUnderATouchThatsDownStays() {
        var trail = LaserTrail(mode: .trail)
        trail.begin(at: CGPoint(x: 5, y: 5), time: 0)
        trail.prune(now: 30)
        #expect(trail.points.count == 1)
        #expect(trail.headOpacity(now: 30) == 1)
    }

    @Test func aNewLineDoesntJoinTheLastOne() {
        var trail = LaserTrail(mode: .trail)
        trail.begin(at: .zero, time: 0)
        trail.move(to: CGPoint(x: 10, y: 0), time: 0.1)
        trail.end(time: 0.1)
        trail.begin(at: CGPoint(x: 100, y: 100), time: 0.3)
        #expect(trail.points.map(\.startsLine) == [true, false, true])
        #expect(trail.bounds == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func theDotFollowsTheTouchAndFadesQuicklyOnceItLifts() {
        var trail = LaserTrail(mode: .dot)
        trail.begin(at: .zero, time: 0)
        trail.move(to: CGPoint(x: 50, y: 50), time: 0.5)
        #expect(trail.points.count == 1)
        #expect(trail.head?.location == CGPoint(x: 50, y: 50))
        trail.end(time: 1)
        #expect(abs(trail.headOpacity(now: 1 + LaserTrail.dotFadeDuration / 2) - 0.5) < 1e-9)
        trail.prune(now: 1 + LaserTrail.dotFadeDuration)
        #expect(trail.isEmpty)
    }
}

@MainActor
@Suite("Presentation mode")
struct PresentationTests {
    @Test func theDisplayShowsThePagePresentedLast() {
        let presentation = InkPresentation()
        let first = CanvasDocument(), second = CanvasDocument()
        presentation.present(first)
        presentation.present(second)
        #expect(presentation.page === second)
        presentation.stopPresenting(first) // not the one shown: nothing changes
        #expect(presentation.page === second)
        presentation.stopPresenting(second)
        #expect(presentation.page == nil)
    }

    @Test func onlyThePresentedPagesLaserReachesTheDisplay() {
        let presentation = InkPresentation()
        let shown = CanvasDocument(), other = CanvasDocument()
        presentation.present(shown)
        final class Counter: @unchecked Sendable { var posts = 0 }
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(forName: InkPresentation.laserDidChangeNotification,
                                                              object: presentation, queue: nil) { _ in counter.posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var trail = LaserTrail()
        trail.begin(at: CGPoint(x: 10, y: 10), time: 0)
        presentation.laserDidChange(trail, on: other)
        #expect(presentation.laser.isEmpty)
        presentation.laserDidChange(trail, on: shown)
        #expect(presentation.laser == trail)
        presentation.laserDidChange(trail, on: shown) // unchanged: no post
        #expect(counter.posts == 1)
        presentation.present(other) // a new page starts with no laser
        #expect(presentation.laser.isEmpty)
    }

    @Test func theMirrorFitsThePageToTheDisplay() {
        let page = PageSize.letter.bounds // 612 × 792
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let t = PageMirrorLayout.transform(page: page, in: display)
        let shown = t.toView(page)
        let m = PageMirrorLayout.margin
        #expect(abs(shown.height - (1080 - 2 * m)) < 1e-9) // as tall as fits
        #expect(abs(shown.width / shown.height - 612 / 792) < 1e-9) // keeping its shape
        #expect(abs(shown.midX - 960) < 1e-9 && abs(shown.midY - 540) < 1e-9) // centred
        #expect(PageMirrorLayout.pixelWidth(page: page, transform: t, displayScale: 2) == Int((shown.width * 2).rounded(.up)))
        let huge = ViewTransform(scale: 40, offset: .zero)
        #expect(PageMirrorLayout.pixelWidth(page: page, transform: huge, displayScale: 3) == PageMirrorLayout.maximumPixelWidth)
    }

    @Test func theCanvasLaserGoesToThePresentationAndWritesNothing() throws {
        let presentation = InkPresentation()
        let controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: "PresentationTests.\(UUID())")),
                                              penTray: PenTrayStore(fileURL: nil), pasteboard: .withUniqueName(),
                                              presentation: presentation)
        let document = CanvasDocument(pageSize: .letter)
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
        presentation.present(document)
        controller.select(.laser)
        controller.laserMode = .trail
        canvas.beginToolGesture(at: CGPoint(x: 100, y: 100))
        _ = canvas.updateToolGesture(to: CGPoint(x: 200, y: 150))
        canvas.finishToolGestures(commit: true)
        #expect(presentation.laser.points.map(\.location) == [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)])
        #expect(!presentation.laser.isDrawing)
        #expect(canvas.laserView.trail == presentation.laser)
        #expect(document.strokeCount == 0 && document.objectCount == 0 && !document.canUndo)
    }

    @Test func theMirrorRendersThePresentedPage() async throws {
        let presentation = InkPresentation()
        let document = CanvasDocument(pageSize: .letter)
        document.add(makeStroke(at: CGPoint(x: 100, y: 100)))
        presentation.present(document)
        let mirror = PageMirrorView(presentation: presentation, theme: .standard)
        mirror.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        mirror.layoutIfNeeded()
        #expect(abs(mirror.pageTransform.toView(document.pageBounds).height - (1080 - 2 * PageMirrorLayout.margin)) < 1e-9)
        // The page renders in the background.
        for _ in 0 ..< 200 where mirror.layer.sublayers?.first?.contents == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mirror.layer.sublayers?.first?.contents != nil)
    }
}
