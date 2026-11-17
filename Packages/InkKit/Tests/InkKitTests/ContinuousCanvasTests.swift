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

/// A page with a few wavy strokes down it.
@MainActor
private func inkedPage() -> CanvasDocument {
    let page = CanvasDocument()
    for row in 0 ..< 6 {
        let y = 80 + CGFloat(row) * 120
        let points = (0 ..< 40).map { i in
            StrokePoint(location: CGPoint(x: 60 + CGFloat(i) * 10, y: y + sin(CGFloat(i) / 3) * 14), force: 0.6,
                        altitude: .pi / 3, azimuth: 0.4, timestamp: Double(i) / 240)
        }
        page.add(Stroke(id: UUID(), color: RGBA.swatches[0], brush: .pen, points: points))
    }
    return page
}

/// Continuous scrolling on the tile cache (NOT-107): pooled page canvases, prefetch ahead of a scroll,
/// geometry shared by every canvas on a page, and canvases staying where the host puts them.
@MainActor
@Suite("Continuous canvases")
struct ContinuousCanvasTests {
    private let screen = CGRect(x: 0, y: 0, width: 1032, height: 1376)

    /// A continuous view of `count` inked pages, in a window (which keeps it), as the app shows it.
    private func continuousView(pages count: Int) throws -> (view: ContinuousCanvasView, notebook: InkNotebook) {
        let notebook = InkNotebook(pages: (0 ..< count).map { _ in inkedPage() }, defaultPageSize: .default)
        let controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: "ContinuousCanvasTests.\(UUID())")),
                                              penTray: PenTrayStore(fileURL: nil))
        let view = ContinuousCanvasView(notebook: notebook, controller: controller, telemetry: PencilTelemetry())
        view.frame = screen
        let window = UIWindow(frame: screen)
        window.addSubview(view)
        window.isHidden = false
        windows.append(window)
        view.layoutIfNeeded()
        return (view, notebook)
    }

    /// Keeps the test's windows (and so its views) for as long as the test runs.
    private final class Windows {
        var all: [UIWindow] = []
        func append(_ window: UIWindow) {
            all.append(window)
        }
    }

    private let windows = Windows()

    @Test func prefetchReachesFurtherAheadOfAFasterScroll() {
        let viewport = CGRect(x: 0, y: 1000, width: 1000, height: 1000)
        let still = ContinuousPageLayout.prefetchRect(around: viewport, velocity: 0)
        #expect(still == CGRect(x: 0, y: 500, width: 1000, height: 2000))
        let down = ContinuousPageLayout.prefetchRect(around: viewport, velocity: 2000)
        #expect(down.minY == 500)
        #expect(down.maxY == 2500 + 2000 * ContinuousPageLayout.prefetchLookahead)
        let up = ContinuousPageLayout.prefetchRect(around: viewport, velocity: -2000)
        #expect(up.minY == 500 - 2000 * ContinuousPageLayout.prefetchLookahead)
        #expect(up.maxY == 2500)
        // A fling reaches no further than a couple of screens ahead.
        let fling = ContinuousPageLayout.prefetchRect(around: viewport, velocity: 100_000)
        #expect(fling.maxY == 2500 + 1000 * ContinuousPageLayout.maxPrefetchScreens)
    }

    @Test func scrollingReusesCanvasesInsteadOfMakingThem() throws {
        let (view, notebook) = try continuousView(pages: 12)
        // Down and back up once: the pool grows to what the view needs.
        for index in notebook.pages.indices {
            view.scroll(toPage: index, animated: false)
            view.layoutIfNeeded()
        }
        for index in notebook.pages.indices.reversed() {
            view.scroll(toPage: index, animated: false)
            view.layoutIfNeeded()
        }
        let made = view.canvasesMade
        #expect(made <= ContinuousCanvasView.maxLiveCanvases)
        for index in notebook.pages.indices {
            view.scroll(toPage: index, animated: false)
            view.layoutIfNeeded()
            // Every page in view has a canvas showing that page, placed where the layout puts it.
            for i in view.pagesInView {
                let page = notebook.pages[i]
                let canvas = try #require(view.canvas(showing: page.id))
                #expect(canvas.document === page)
                #expect(canvas.coordinator.document === page)
                #expect(!canvas.isHidden)
                #expect(canvas.placement == canvas.viewTransform)
            }
        }
        #expect(view.canvasesMade == made)
        // Spare canvases are hidden and hold no page on screen.
        for spare in view.spareCanvases {
            #expect(spare.isHidden)
            #expect(spare.hasLeftPage)
        }
    }

    @Test func aPageHandedAPooledCanvasShowsItsOwnInk() async throws {
        let (view, notebook) = try continuousView(pages: 8)
        for index in notebook.pages.indices {
            view.scroll(toPage: index, animated: false)
            view.layoutIfNeeded()
        }
        let last = notebook.pages[notebook.pages.count - 1]
        let canvas = try #require(view.canvas(showing: last.id))
        try await waitUntil { canvas.rendersSettled }
        // No tile in view is missing, and every one shows this page's ink version.
        #expect(canvas.coordinator.blankTiles(in: last.pageBounds) == 0)
        let keys = canvas.coordinator.visibleKeys(at: canvas.viewTransform, level: canvas.coordinator.level(for: canvas.viewTransform))
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { $0.page == last.cacheID })
    }

    @Test func aPageLeavingViewLeavesItsTilesAndLetsGoOfTheScreen() async throws {
        let (view, notebook) = try continuousView(pages: 6)
        let first = notebook.pages[0]
        let canvas = try #require(view.canvas(showing: first.id))
        try await waitUntil { canvas.rendersSettled && !canvas.coordinator.isFilling }
        view.scroll(toPage: 5, animated: false)
        view.layoutIfNeeded()
        #expect(view.canvas(showing: first.id) == nil)
        try await waitUntil { first.committedTiles != nil }
    }

    @Test func pagesAheadOfTheViewFillBehindThoseOnScreen() throws {
        let (view, notebook) = try continuousView(pages: 6)
        view.scroll(toPage: 2, animated: false)
        view.layoutIfNeeded()
        let inView = Set(view.pagesInView)
        for (i, page) in notebook.pages.enumerated() {
            guard let canvas = view.canvas(showing: page.id) else { continue }
            #expect(canvas.isAhead == !inView.contains(i))
        }
    }

    @Test func aPageOnlyScrolledPastKeepsNoGeometry() async throws {
        let page = inkedPage()
        let embedded = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000), document: page, embedded: true)
        embedded.place(ViewTransform(scale: 1, offset: .zero), settled: true)
        embedded.layoutIfNeeded()
        try await waitUntil { embedded.rendersSettled && !embedded.coordinator.isFilling }
        #expect(embedded.coordinator.fillStats.tilesFilled > 0)
        #expect(!page.strokes.contains { page.geometry.isKept($0.id) })
    }

    @Test func twoCanvasesOnOnePageShareItsGeometry() async throws {
        let page = inkedPage()
        let paged = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000), document: page)
        paged.layoutIfNeeded()
        try await waitUntil { paged.rendersSettled && !paged.coordinator.isFilling }
        #expect(paged.coordinator.fillStats.tilesFilled > 0)
        let built = page.geometry.builtCount
        #expect(built > 0)
        #expect(page.strokes.allSatisfy { page.geometry.isKept($0.id) })

        // Another canvas on the page, at another scale (so it fills tiles of its own), builds none again.
        let embedded = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000), document: page, embedded: true)
        embedded.place(ViewTransform(scale: 0.6, offset: .zero), settled: true)
        embedded.layoutIfNeeded()
        try await waitUntil { embedded.rendersSettled && !embedded.coordinator.isFilling }
        #expect(embedded.coordinator.fillStats.tilesFilled > 0)
        #expect(page.geometry.builtCount == built)
        withExtendedLifetime(paged) {}
    }

    /// The glitch NOT-105 found: a canvas resized while embedded (mid-pinch past the smallest zoom, or made
    /// for a page entering view) drew its page fitted to its new size, over the pages around it.
    @Test func anEmbeddedCanvasStaysWhereTheHostPutsItWhenResized() {
        let page = inkedPage()
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000), document: page, embedded: true)
        let placed = ViewTransform(scale: 0.7, offset: CGPoint(x: 120, y: -40))
        canvas.place(placed, settled: false)
        canvas.layoutIfNeeded()
        #expect(canvas.viewTransform == placed)
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        canvas.layoutIfNeeded()
        #expect(canvas.viewTransform == placed)
        #expect(canvas.pageFrameInView == placed.toView(page.pageBounds))
    }
}
