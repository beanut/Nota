import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@MainActor
@Suite("Page snapshots and rendering")
struct PageRendererTests {
    @Test func revisionCountsEditsUndoAndRedo() {
        let doc = CanvasDocument()
        #expect(doc.revision == 0)
        doc.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        #expect(doc.revision == 1)
        doc.undo()
        #expect(doc.revision == 2)
        doc.redo()
        #expect(doc.revision == 3)
        doc.pageSize = .a4
        #expect(doc.revision == 4)
    }

    @Test func snapshotIsFrozen() {
        let doc = CanvasDocument()
        let blank = doc.snapshot()
        doc.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        #expect(blank.isBlank)
        #expect(!doc.snapshot().isBlank)
        #expect(doc.snapshot().pageID == doc.id)
        #expect(doc.snapshot().revision != blank.revision)
    }

    @Test func imageFollowsThePageAspectRatio() throws {
        let doc = CanvasDocument(pageSize: .letter)
        let image = try #require(PageRenderer.image(of: doc.snapshot(), pixelWidth: 306))
        #expect(image.width == 306)
        #expect(image.height == 396)
    }

    @Test func inkIsDrawnOverTheBackground() throws {
        let doc = CanvasDocument(pageSize: PageSize(width: 100, height: 100))
        var stroke = makeStroke(at: CGPoint(x: 20, y: 50))
        stroke.style.width = 20
        stroke.points.append(StrokePoint(location: CGPoint(x: 80, y: 50), force: 1, altitude: .pi / 2,
                                         azimuth: 0, timestamp: 2))
        doc.add(stroke)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let image = try #require(PageRenderer.image(of: doc.snapshot(), pixelWidth: 100) { ctx, size in
            ctx.setFillColor(white)
            ctx.fill(CGRect(origin: .zero, size: size))
        })
        #expect(pixel(image, x: 50, y: 50).red < 128) // inked
        #expect(pixel(image, x: 50, y: 5).red == 255) // paper
    }

    @Test func pixelEraserRemovesInkButNotPaper() throws {
        let doc = CanvasDocument(pageSize: PageSize(width: 100, height: 100))
        var ink = makeStroke(at: CGPoint(x: 20, y: 50))
        ink.style.width = 20
        ink.points.append(StrokePoint(location: CGPoint(x: 80, y: 50), force: 1, altitude: .pi / 2,
                                      azimuth: 0, timestamp: 2))
        doc.add(ink)
        var eraser = Stroke(id: UUID(), tool: .pixelEraser, color: ink.color, style: ink.style, points: ink.points)
        eraser.style.width = 40
        doc.add(eraser)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let image = try #require(PageRenderer.image(of: doc.snapshot(), pixelWidth: 100) { ctx, size in
            ctx.setFillColor(white)
            ctx.fill(CGRect(origin: .zero, size: size))
        })
        let erased = pixel(image, x: 50, y: 50)
        #expect(erased.red == 255 && erased.alpha == 255)
    }
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> (red: UInt8, alpha: UInt8) {
    var data = [UInt8](repeating: 0, count: 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Bitmap rows run bottom-up in CG space, so row `y` from the top sits at height - 1 - y.
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (data[0], data[3])
}
