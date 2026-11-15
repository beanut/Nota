import CoreGraphics
import Foundation
@testable import InkKit
import Testing

private let sand = PenColor(rgb: 0xE8D7A9)

/// A level strip 20 points wide from (100, 200) to (300, 200).
private func strip(revealed: Bool = false) -> TapeObject {
    TapeObject(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 300, y: 200), width: 20, color: sand).revealed(revealed)
}

private func roundTrip(_ objects: [any PageObject]) throws -> [any PageObject] {
    try PageObjectsFile(data: PageObjectsFile(pageID: UUID(), objects: objects).encoded()).objects
}

private struct Pixel {
    var r, g, b, a: Int
}

@Suite("Tape: file format and geometry")
struct TapeObjectTests {
    @Test func tapeRoundTripsWithItsRevealedStateColourAndPattern() throws {
        var tape = TapeObject(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 240, y: 140), width: 32, color: sand,
                              pattern: .striped)
        tape.zIndex = 3
        let hidden = tape
        var revealed = TapeObject(frame: tape.frame, transform: tape.transform, zIndex: 4, color: PenColor(rgb: 0x9EA3B2),
                                  pattern: .striped)
        revealed = revealed.toggled()
        let read = try roundTrip([hidden, revealed])
        let tapes = read.compactMap { $0 as? TapeObject }
        #expect(tapes.count == 2)
        #expect(tapes[0] == hidden)
        #expect(!tapes[0].isRevealed)
        #expect(tapes[1].isRevealed)
        #expect(tapes[1].pattern == .striped)
        #expect(tapes[1].color == PenColor(rgb: 0x9EA3B2))
    }

    @Test func hiddenPlainTapeWritesOnlyWhatItNeeds() throws {
        let data = try PageObjectsFile(pageID: UUID(), objects: [strip()]).encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"kind\" : \"tape\""))
        #expect(!json.contains("revealed"))
        #expect(!json.contains("pattern"))
        let revealedJSON = try #require(String(data: PageObjectsFile(pageID: UUID(), objects: [strip(revealed: true)]).encoded(),
                                               encoding: .utf8))
        #expect(revealedJSON.contains("\"revealed\" : true"))
    }

    @Test func readingIsLenient() throws {
        let id = UUID()
        let json = """
        { "formatVersion": 1, "pageID": "\(UUID())", "objects": [ { "kind": "tape", "id": "\(id)",
          "frame": { "x": -50, "y": -10, "width": 100, "height": 20 }, "color": "nope", "pattern": "plaid",
          "revealed": "maybe" } ] }
        """
        let tape = try #require(PageObjectsFile(data: Data(json.utf8)).objects.first as? TapeObject)
        #expect(tape.id == id)
        #expect(tape.color == TapeObject.defaultColor)
        #expect(tape.pattern == .plain)
        #expect(!tape.isRevealed)
    }

    @Test func aStripRunsFromStartToEndAtItsWidth() {
        let tape = TapeObject(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), width: 20, color: sand)
        #expect(abs(tape.frame.width - hypot(100, 100)) < 1e-9)
        #expect(tape.frame.height == 20)
        #expect(tape.contains(CGPoint(x: 150, y: 150), tolerance: 0))
        #expect(tape.contains(CGPoint(x: 105, y: 105), tolerance: 0))
        // Off the diagonal, beyond half the width.
        #expect(!tape.contains(CGPoint(x: 170, y: 130), tolerance: 0))
        #expect(!tape.contains(CGPoint(x: 230, y: 230), tolerance: 0))
        // A tap is still a short strip, not nothing.
        let tiny = TapeObject(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10), color: sand)
        #expect(tiny.frame.width == TapeObject.minimumLength)
    }

    @Test func onlyTapeIsDrawnOverTheInk() {
        let shape = ShapeObject(.rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                style: ShapeStyle(color: sand, lineWidth: 1))
        let objects: [any PageObject] = [shape, strip()]
        let layers = objects.splitByInkLayer
        #expect(layers.under.map(\.id) == [shape.id])
        #expect(layers.over.map(\.kind) == ["tape"])
    }

    @Test func aTapOnTapeOverInkReachesTheTapeFirst() {
        let ink = SelectionGeometry.StrokeShape(id: UUID(), path: [CGPoint(x: 150, y: 200), CGPoint(x: 250, y: 200)],
                                                bounds: CGRect(x: 148, y: 198, width: 104, height: 4), radius: 2)
        let tape = strip()
        let hit = SelectionGeometry.hitTest(CGPoint(x: 200, y: 200), tolerance: 2, strokes: [ink], objects: [tape])
        #expect(hit?.objectIDs == [tape.id])
    }

    @MainActor @Test func hiddenTapeCoversTheInkInRenderedPagesAndRevealedTapeShowsIt() throws {
        let doc = CanvasDocument(pageSize: PageSize(width: 400, height: 400))
        var ink = makeStroke(at: CGPoint(x: 190, y: 195))
        ink.points = [CGPoint(x: 120, y: 200), CGPoint(x: 280, y: 200)].enumerated().map { i, p in
            StrokePoint(location: p, force: 1, altitude: .pi / 2, azimuth: 0, timestamp: Double(i))
        }
        doc.add(ink)
        let tape = strip()
        doc.addObject(tape)
        let hidden = try #require(PageRenderer.image(of: doc.snapshot(), pixelWidth: 400))
        #expect(isTapeColored(pixel(of: hidden, at: CGPoint(x: 200, y: 200))))
        doc.toggleTape(id: tape.id)
        let shown = try #require(PageRenderer.image(of: doc.snapshot(), pixelWidth: 400))
        #expect(!isTapeColored(pixel(of: shown, at: CGPoint(x: 200, y: 200))))
    }

    private func isTapeColored(_ p: Pixel) -> Bool {
        abs(p.r - 0xE8) < 12 && abs(p.g - 0xD7) < 12 && abs(p.b - 0xA9) < 12 && p.a > 240
    }

    private func pixel(of image: CGImage, at p: CGPoint) -> Pixel {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -p.x, y: -(CGFloat(image.height) - p.y - 1), width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
        return Pixel(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]), a: Int(bytes[3]))
    }
}

@MainActor
@Suite("Tape: revealing, hiding and undo")
struct TapeDocumentTests {
    @Test func togglingIsOneUndoableEdit() throws {
        let doc = CanvasDocument()
        let tape = strip()
        doc.addObject(tape)
        let toggled = try #require(doc.toggleTape(id: tape.id))
        #expect(toggled.isRevealed)
        #expect((doc.object(id: tape.id) as? TapeObject)?.isRevealed == true)
        #expect(doc.revision == 0) // the ink's committed layer stays valid
        doc.undo()
        #expect((doc.object(id: tape.id) as? TapeObject)?.isRevealed == false)
        doc.redo()
        #expect((doc.object(id: tape.id) as? TapeObject)?.isRevealed == true)
        doc.undo()
        doc.undo()
        #expect(doc.tapes.isEmpty) // and adding it was a step of its own
        #expect(doc.toggleTape(id: UUID()) == nil)
    }

    @Test func revealAllAndHideAllAreSingleSteps() {
        let doc = CanvasDocument()
        for x in [0, 50, 100] as [CGFloat] {
            doc.addObject(TapeObject(from: CGPoint(x: x, y: 10), to: CGPoint(x: x + 40, y: 10), color: sand))
        }
        doc.toggleTape(id: doc.tapes[0].id)
        #expect(doc.setAllTape(revealed: true) == 2)
        #expect(!doc.tapes.contains { !$0.isRevealed })
        #expect(doc.setAllTape(revealed: true) == 0)
        #expect(doc.setAllTape(revealed: false) == 3)
        doc.undo()
        #expect(!doc.tapes.contains { !$0.isRevealed })
        doc.undo()
        #expect(doc.tapes.filter(\.isRevealed).count == 1)
    }

    @Test func tapeMovesAndDeletesLikeAnyObject() throws {
        let doc = CanvasDocument()
        let tape = strip()
        doc.addObject(tape)
        let selection = PageSelection(objectIDs: [tape.id])
        doc.transform(selection, by: CGAffineTransform(translationX: 0, y: 100))
        let moved = try #require(doc.tapes.first)
        #expect(moved.contains(CGPoint(x: 200, y: 300), tolerance: 0))
        doc.delete(selection)
        #expect(doc.tapes.isEmpty)
        doc.undo()
        #expect(doc.tapes.count == 1)
    }
}

@MainActor
@Suite("Tape on the canvas")
struct CanvasTapeTests {
    let controller: CanvasController
    let document = CanvasDocument(pageSize: .letter)
    let canvas: CanvasView

    init() throws {
        controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: "CanvasTapeTests.\(UUID())")),
                                          penTray: PenTrayStore(fileURL: nil),
                                          stickers: StickerStore(folderURL: FileManager.default.temporaryDirectory
                                              .appending(path: UUID().uuidString)),
                                          pasteboard: .withUniqueName(), presentation: InkPresentation())
        canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
    }

    @Test func theTapeToolDrawsAStripAndATapTogglesIt() throws {
        controller.select(.tape)
        controller.tapePattern = .grid
        canvas.beginToolGesture(at: CGPoint(x: 100, y: 100))
        #expect(canvas.updateToolGesture(to: CGPoint(x: 200, y: 101)))
        #expect(canvas.toolGesturePreview.count == 1) // shown while dragging
        canvas.finishToolGestures(commit: true)
        let tape = try #require(document.tapes.first)
        #expect(tape.pattern == .grid)
        #expect(!tape.isRevealed)
        #expect(abs(tape.transform.b) < 1e-9) // a nearly level drag snaps level
        #expect(canvas.tapeLayer.objects.count == 1)
        #expect(canvas.objectLayer.objects.isEmpty) // tape is drawn over the ink, not under it

        // A tap with the tape tool reveals it.
        canvas.beginToolGesture(at: CGPoint(x: 150, y: 100))
        canvas.finishToolGestures(commit: true)
        #expect(document.tapes.first?.isRevealed == true)
        #expect(document.tapes.count == 1)
    }

    @Test func aPenTapOnTapeTogglesItInsteadOfLeavingADot() {
        let tape = TapeObject(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 300, y: 300), color: sand)
        document.addObject(tape)
        canvas.refreshObjects()
        controller.select(.pen)
        let live = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA(r: 0, g: 0, b: 0), brush: .pen, points: []))
        _ = live.append(StrokePoint(location: CGPoint(x: 200, y: 300), force: 0.5, altitude: .pi / 2, azimuth: 0,
                                    timestamp: 0), minSpacing: 0)
        #expect(canvas.tapObjectIfTapped(live))
        #expect(document.tapes.first?.isRevealed == true)

        // A stroke across the tape is ink, not a tap.
        _ = live.append(StrokePoint(location: CGPoint(x: 260, y: 320), force: 0.5, altitude: .pi / 2, azimuth: 0,
                                    timestamp: 0.1), minSpacing: 0)
        #expect(!canvas.tapObjectIfTapped(live))
        // The lasso selects tape instead of toggling it.
        controller.select(.lasso)
        #expect(!Tool.lasso.togglesTape)
        canvas.setAllTape(revealed: false)
        #expect(document.tapes.first?.isRevealed == false)
    }
}
