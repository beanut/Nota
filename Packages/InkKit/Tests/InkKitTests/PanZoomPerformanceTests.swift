import Combine
import CoreGraphics
import Foundation
import ImageIO
@testable import InkKit
import Testing
import UIKit

/// What keeps panning and zooming smooth: layers that put off dear redraws while the page moves, a zoom
/// readout that isn't published every frame, and pictures cached as decoded pixels.
@MainActor
@Suite("Pan and zoom performance")
struct PanZoomPerformanceTests {
    private final class Layer: TransformFollowingView {
        var draws: [ViewTransform] = []

        override func drawContents(at transform: ViewTransform, in _: CGRect, context _: CGContext) {
            draws.append(transform)
        }
    }

    private func layer() -> Layer {
        let layer = Layer()
        layer.isHidden = false
        layer.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        return layer
    }

    private let zoomed = ViewTransform(scale: 2, offset: CGPoint(x: -30, y: 40))

    @Test func aCheapLayerRedrawsOnEveryMove() {
        let layer = layer()
        layer.rest(afterDrawTaking: TransformFollowingView.cheapDraw / 2)
        layer.follow(zoomed, moving: true)
        #expect(layer.drawnTransform == zoomed)
        #expect(layer.layer.affineTransform() == .identity)
    }

    @Test func aDearLayerMovesItsLastDrawingWhileThePageMoves() {
        let layer = layer()
        layer.rest(afterDrawTaking: 10) // rests for the length of the test
        layer.follow(zoomed, moving: true)
        #expect(layer.drawnTransform == ViewTransform()) // not drawn again…
        // …but what was drawn at the identity is now shown at `zoomed`: a point keeps its place on the page.
        let shown = CGPoint(x: 10, y: 20).applying(layer.layer.affineTransform())
        #expect(shown == zoomed.toView(CGPoint(x: 10, y: 20)))

        // The movement ends: drawn sharp where the page stopped.
        layer.follow(zoomed)
        #expect(layer.drawnTransform == zoomed)
        #expect(layer.layer.affineTransform() == .identity)
    }

    @Test func aDearLayerCatchesUpWhenItsRestIsOverEvenIfThePageStopsChanging() async throws {
        let layer = layer()
        layer.rest(afterDrawTaking: 0.005) // 45 ms
        layer.follow(zoomed, moving: true)
        #expect(layer.drawnTransform == ViewTransform())
        try await Task.sleep(for: .milliseconds(200))
        #expect(layer.drawnTransform == zoomed)
        #expect(layer.layer.affineTransform() == .identity)
    }

    @Test func aDearLayerResizedMidMoveIsDrawnAgainWhenTheMovementEnds() {
        let layer = layer()
        layer.rest(afterDrawTaking: 10)
        layer.follow(zoomed, moving: true)
        layer.follow(zoomed) // drawn at `zoomed`
        layer.layer.displayIfNeeded()
        layer.rest(afterDrawTaking: 10)
        layer.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) // wider, mid-pinch: not drawn yet
        #expect(layer.layer.needsDisplay() == false)
        layer.follow(zoomed) // the same transform, but the new part needs drawing
        #expect(layer.layer.needsDisplay())
    }

    @Test func aHiddenLayerJustKeepsUp() {
        let layer = layer()
        layer.isHidden = true
        layer.rest(afterDrawTaking: 10)
        layer.follow(zoomed, moving: true)
        #expect(layer.drawnTransform == zoomed)
        #expect(layer.layer.affineTransform() == .identity)
    }

    @Test func zoomIsPublishedOnceItStopsChanging() async throws {
        let store = try #require(UserDefaults(suiteName: "PanZoomPerformanceTests.\(UUID())"))
        let controller = CanvasController(settingsStore: store, penTray: PenTrayStore(fileURL: nil))
        var published = 0
        let observation = controller.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        for step in 1 ... 20 {
            controller.zoomDidChange(1 + CGFloat(step) / 10) // a pinch: a new zoom every frame
        }
        #expect(controller.zoom == 1)
        #expect(published == 0)
        try await Task.sleep(for: .seconds(CanvasController.zoomPublicationDelay + 0.3))
        #expect(controller.zoom == 3)
        #expect(published == 1)
    }

    @Test func aZoomBackToThePublishedValueCancelsThePublication() async throws {
        let store = try #require(UserDefaults(suiteName: "PanZoomPerformanceTests.\(UUID())"))
        let controller = CanvasController(settingsStore: store, penTray: PenTrayStore(fileURL: nil))
        controller.zoomDidChange(2)
        controller.zoomDidChange(1)
        var published = 0
        let observation = controller.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        try await Task.sleep(for: .seconds(CanvasController.zoomPublicationDelay + 0.3))
        #expect(controller.zoom == 1)
        #expect(published == 0)
    }

    @Test func decodedImagesAreBitmapsOfTheSamePixels() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        // Through a PNG, so ImageIO hands back an image backed by encoded bytes.
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(data, nil))
        let lazy = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let decoded = ImageAssets.decoded(lazy)
        #expect(decoded.width == 8 && decoded.height == 6)
        #expect(decoded.alphaInfo == .premultipliedFirst) // the PNG has alpha
        let bytes = try #require(decoded.dataProvider?.data as Data?)
        let row = decoded.bytesPerRow
        // BGRA: the left half red, the right half clear.
        #expect(Array(bytes[0 ..< 4]) == [0, 0, 255, 255])
        #expect(Array(bytes[(row * 5 + 7 * 4) ..< (row * 5 + 8 * 4)]) == [0, 0, 0, 0])
    }
}

/// While the page moves, the ink is drawn again only when the last render falls short.
@Suite("Ink renders while moving")
struct MovingInkRenderTests {
    private let page = CGRect(x: 0, y: 0, width: 600, height: 800)
    private let view = CGRect(x: 0, y: 0, width: 1000, height: 1300)
    private let drawn = ViewTransform(scale: 1.5, offset: CGPoint(x: 50, y: 40))

    private func fallsShort(at transform: ViewTransform, size: CGSize? = nil) -> Bool {
        CanvasView.inkFallsShort(shownAt: drawn, size: size ?? view.size, viewTransform: transform,
                                 page: page, in: view)
    }

    @Test func whatWasDrawnIsGoodEnoughAsItIs() {
        #expect(!fallsShort(at: drawn))
    }

    @Test func zoomingInALittleScalesTheLastRender() {
        // About the view's centre, 1.3×: the page in view is still all inside the scaled image.
        let k: CGFloat = 1.3, c = CGPoint(x: 500, y: 650)
        let zoomed = ViewTransform(scale: drawn.scale * k,
                                   offset: CGPoint(x: c.x - (c.x - drawn.offset.x) * k, y: c.y - (c.y - drawn.offset.y) * k))
        #expect(!fallsShort(at: zoomed))
    }

    @Test func zoomingInFurtherDrawsItSharpAgain() {
        let k: CGFloat = 1.6, c = CGPoint(x: 500, y: 650)
        let zoomed = ViewTransform(scale: drawn.scale * k,
                                   offset: CGPoint(x: c.x - (c.x - drawn.offset.x) * k, y: c.y - (c.y - drawn.offset.y) * k))
        #expect(fallsShort(at: zoomed))
    }

    @Test func zoomingOutUncoversPageAndDrawsAgain() {
        // A render of only part of the page (zoomed in), then zoomed out a little: page shows past it.
        let partial = CGSize(width: 400, height: 500)
        let out = ViewTransform(scale: drawn.scale / 1.2, offset: drawn.offset)
        #expect(fallsShort(at: out, size: partial))
    }

    @Test func panningWithinWhatWasDrawnDoesNotDrawAgain() {
        // The image covers the whole view; the page moves 30 pt but stays inside it.
        #expect(!fallsShort(at: ViewTransform(scale: drawn.scale, offset: CGPoint(x: 80, y: 40))))
    }

    @Test func panningPastWhatWasDrawnDrawsAgain() {
        // Zoomed in: the page is larger than the view, and moving it brings in page the image never had.
        let big = ViewTransform(scale: 4, offset: CGPoint(x: -400, y: -400))
        let shown = CanvasView.inkFallsShort(shownAt: big, size: view.size,
                                             viewTransform: ViewTransform(scale: 4, offset: CGPoint(x: -300, y: -400)),
                                             page: page, in: view)
        #expect(shown)
    }

    @Test func nothingShownYetIsShort() {
        #expect(fallsShort(at: drawn, size: .zero))
    }
}
