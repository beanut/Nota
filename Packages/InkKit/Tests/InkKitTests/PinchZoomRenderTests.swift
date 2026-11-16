import CoreGraphics
import Foundation
@_spi(Testing) @testable import InkKit
import Testing
import UIKit

/// While a pinch is under way, what's drawn (the committed ink, the template, the page's objects) is
/// scaled to follow the page, and only drawn again when it would look too soft or leave part of the page
/// in view uncovered. Drawing everything every frame is what made fast pinches over ink stutter.
@Suite("Pinch zoom rendering")
struct ReuseWhileMovingTests {
    private let page = CGRect(x: 0, y: 0, width: 600, height: 800)
    private let view = CGRect(x: 0, y: 0, width: 600, height: 800)

    /// Zoomed by `scale` about the middle of the page, as a pinch there would.
    private func zoomed(_ scale: CGFloat) -> ViewTransform {
        ViewTransform(scale: scale, offset: CGPoint(x: 300 - 300 * scale, y: 400 - 400 * scale))
    }

    @Test func aLayerIsScaledUntilItWouldBeMagnifiedTooFar() {
        let drawn = zoomed(1)
        #expect(zoomed(1.2).canReuse(drawnAt: drawn, over: view, visible: view, page: page))
        #expect(zoomed(1.5).canReuse(drawnAt: drawn, over: view, visible: view, page: page))
        #expect(!zoomed(1.6).canReuse(drawnAt: drawn, over: view, visible: view, page: page))
        // Measured from what was drawn, not from the start of the pinch.
        #expect(zoomed(3).canReuse(drawnAt: zoomed(2.5), over: view, visible: view, page: page))
    }

    @Test func zoomingOutRedrawsOnceThePageInViewIsNoLongerCovered() {
        let drawn = zoomed(2) // covers the middle half of the page
        #expect(!zoomed(1.8).canReuse(drawnAt: drawn, over: view, visible: view, page: page))
        // With only the middle of the view on screen, there's room to zoom out before it runs out.
        let middle = CGRect(x: 150, y: 200, width: 300, height: 400)
        #expect(zoomed(1.8).canReuse(drawnAt: drawn, over: view, visible: middle, page: page))
        #expect(!zoomed(0.9).canReuse(drawnAt: drawn, over: view, visible: middle, page: page))
    }

    @Test func onlyThePageNeedsCovering() {
        // Zoomed out past the page: the desk around it shows, and nothing needs drawing there.
        let drawn = zoomed(1)
        #expect(zoomed(0.8).canReuse(drawnAt: drawn, over: view, visible: view, page: page))
        // Nothing of the page on screen: nothing to redraw for.
        #expect(zoomed(1.2).canReuse(drawnAt: drawn, over: view, visible: .null, page: page))
    }

    @Test func theLayerTransformPutsWhatWasDrawnWhereThePageIsNow() {
        let drawn = ViewTransform(scale: 1.5, offset: CGPoint(x: -40, y: 25))
        let now = ViewTransform(scale: 2.25, offset: CGPoint(x: -310, y: -80))
        let t = now.layerTransform(from: drawn)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 340), CGPoint(x: 600, y: 800)] {
            let moved = drawn.toView(p).applying(t)
            #expect(abs(moved.x - now.toView(p).x) < 1e-9 && abs(moved.y - now.toView(p).y) < 1e-9)
        }
        #expect(now.layerTransform(from: now) == .identity)
    }
}

@MainActor
@Suite("Pinch zoom rendering on a page")
struct PinchZoomCanvasTests {
    let document = CanvasDocument(pageSize: .letter)
    let canvas: CanvasView

    init() {
        let size = document.pageBounds.size
        canvas = CanvasView(frame: CGRect(origin: .zero, size: size), document: document, embedded: true)
        canvas.layoutIfNeeded()
    }

    /// Zoomed by `scale` about the middle of the page.
    private func zoomed(_ scale: CGFloat) -> ViewTransform {
        let c = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        return ViewTransform(scale: scale, offset: CGPoint(x: c.x - c.x * scale, y: c.y - c.y * scale))
    }

    /// Lets the render queue finish and its results land.
    private func waitForRenders() async throws {
        let deadline = Date().addingTimeInterval(5)
        while canvas.fullRenderInFlight || canvas.displayedTransform != canvas.bitmapTransform {
            guard Date() < deadline else {
                Issue.record("The page never finished rendering")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle(at transform: ViewTransform) async throws {
        canvas.place(transform, visible: canvas.bounds, settled: true)
        try await waitForRenders()
        #expect(canvas.displayedTransform == transform)
    }

    @Test func aPinchRendersTheInkOnlyWhenTheBitmapStopsServing() async throws {
        document.drawTestStroke(through: [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 700)])
        try await settle(at: zoomed(1))

        for scale in stride(from: 1.05, through: 1.45, by: 0.1) {
            canvas.place(zoomed(scale), visible: canvas.bounds, settled: false)
            #expect(canvas.bitmapTransform == zoomed(1), "zoom \(scale) should scale the bitmap, not render it again")
        }
        canvas.place(zoomed(1.6), visible: canvas.bounds, settled: false)
        #expect(canvas.bitmapTransform == zoomed(1.6), "past 1.5× the ink is drawn again, sharp")

        try await waitForRenders()
        canvas.place(zoomed(2.3), visible: canvas.bounds, settled: false)
        #expect(canvas.bitmapTransform == zoomed(1.6), "measured from the last render, not the start of the pinch")

        // Letting go draws the ink sharp where the pinch ended.
        try await settle(at: zoomed(2.3))
    }

    @Test func zoomingOutRendersWhenThePageInViewOutgrowsTheBitmap() async throws {
        try await settle(at: zoomed(2))
        canvas.place(zoomed(1.9), visible: canvas.bounds, settled: false)
        #expect(canvas.bitmapTransform == zoomed(1.9))
    }

    @Test func theTemplateIsScaledMidPinchAndDrawnAgainWhenItEnds() async throws {
        document.template = PageTemplate.Preset.smallGrid.template
        try await settle(at: zoomed(1))
        let template = try #require(canvas.subviews.compactMap { $0 as? TemplateView }.first)
        #expect(!template.isHidden)

        canvas.place(zoomed(1.3), visible: canvas.bounds, settled: false)
        #expect(template.drawnTransform == zoomed(1))
        #expect(template.transform != .identity)

        canvas.place(zoomed(1.3), visible: canvas.bounds, settled: true)
        #expect(template.drawnTransform == zoomed(1.3))
        #expect(template.transform == .identity)
    }
}
