import CoreGraphics
import Foundation
@testable import InkKit
import Testing

private let blue = PenColor(rgb: 0x2563EB)

private func placeholder(_ frame: CGRect = CGRect(x: 100, y: 100, width: 200, height: 100)) -> PlaceholderObject {
    PlaceholderObject(frame: frame, color: blue)
}

private func rotation(_ angle: CGFloat, about c: CGPoint) -> CGAffineTransform {
    CGAffineTransform(translationX: -c.x, y: -c.y)
        .concatenating(CGAffineTransform(rotationAngle: angle))
        .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
}

private func close(_ a: CGPoint, _ b: CGPoint, within e: CGFloat = 1e-6) -> Bool {
    abs(a.x - b.x) <= e && abs(a.y - b.y) <= e
}

private func close(_ a: CGAffineTransform, _ b: CGAffineTransform, within e: CGFloat = 1e-9) -> Bool {
    [a.a - b.a, a.b - b.b, a.c - b.c, a.d - b.d, a.tx - b.tx, a.ty - b.ty].allSatisfy { abs($0) <= e }
}

@MainActor
@Suite("Page objects: undo and transforms")
struct PageObjectCommandTests {
    @Test func addingAnObjectIsUndoableAndStacksItOnTop() {
        let doc = CanvasDocument()
        doc.addObject(placeholder())
        doc.addObject(placeholder(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(doc.objects.map(\.zIndex) == [0, 1])
        #expect(doc.objectsRevision == 2)
        #expect(doc.revision == 0) // the ink didn't change, so its committed layer stays valid
        #expect(doc.canUndo)

        doc.undo()
        #expect(doc.objectCount == 1)
        doc.redo()
        #expect(doc.objects.map(\.zIndex) == [0, 1])
        #expect(doc.objectsRevision == 4)
        #expect(doc.revision == 0)
    }

    @Test func objectEditsAreReportedAsObjectEdits() {
        let doc = CanvasDocument()
        let recorder = CanvasDocumentObserverTests.Recorder()
        recorder.observe(doc)
        doc.addObject(placeholder())
        doc.undo()
        doc.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        #expect(recorder.changes == [.objectsEdited, .objectsEdited, .edited])
    }

    @Test func moveResizeAndRotateAreEachOneUndoStep() throws {
        let doc = CanvasDocument()
        let object = placeholder()
        doc.addObject(object)
        let move = CGAffineTransform(translationX: 30, y: -20)
        let resize = CGAffineTransform(scaleX: 2, y: 0.5)
        let rotate = rotation(.pi / 6, about: CGPoint(x: 200, y: 150))
        for t in [move, resize, rotate] {
            doc.transform(PageSelection(objectIDs: [object.id]), by: t)
        }
        let expected = move.concatenating(resize).concatenating(rotate)
        #expect(try close(#require(doc.object(id: object.id)).transform, expected))
        #expect(doc.object(id: object.id)?.frame == object.frame) // the frame is the object's own space

        doc.undo()
        #expect(try close(#require(doc.object(id: object.id)).transform, move.concatenating(resize)))
        doc.undo()
        doc.undo()
        // Exactly where it began: undo restores saved values, it doesn't apply an inverse.
        #expect(doc.object(id: object.id)?.transform == .identity)
        doc.redo()
        doc.redo()
        doc.redo()
        #expect(try close(#require(doc.object(id: object.id)).transform, expected))
    }

    @Test func inkAndObjectsTransformTogetherInOneStep() {
        let doc = CanvasDocument()
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        doc.add(stroke)
        let object = placeholder()
        doc.addObject(object)
        let inkRevision = doc.revision, objectsRevision = doc.objectsRevision

        let t = CGAffineTransform(translationX: 5, y: 7)
        doc.transform(PageSelection(strokeIDs: [stroke.id], objectIDs: [object.id]), by: t)
        #expect(doc.strokes[0].points.map(\.location) == stroke.points.map { $0.location.applying(t) })
        #expect(doc.object(id: object.id)?.transform == t)
        #expect(doc.revision == inkRevision + 1)
        #expect(doc.objectsRevision == objectsRevision + 1)
        #expect(doc.lastReshapedIDs == [stroke.id])

        doc.undo()
        #expect(doc.strokes[0] == stroke)
        #expect(doc.object(id: object.id)?.transform == .identity)
        #expect(doc.lastReshapedIDs == [stroke.id])
    }

    @Test func aDragPreviewsWithoutRecordingAndCanBeCancelled() {
        let doc = CanvasDocument()
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        doc.add(stroke)
        let object = placeholder()
        doc.addObject(object)
        let revision = doc.revision, objectsRevision = doc.objectsRevision
        let session = doc.beginTransform(PageSelection(strokeIDs: [stroke.id], objectIDs: [object.id]))

        doc.previewTransform(session, by: CGAffineTransform(translationX: 1, y: 1))
        doc.previewTransform(session, by: CGAffineTransform(translationX: 50, y: 0)) // from the start, not cumulative
        #expect(doc.strokes[0].points[0].location == CGPoint(x: 60, y: 10))
        #expect(doc.object(id: object.id)?.transform == CGAffineTransform(translationX: 50, y: 0))
        #expect(doc.revision == revision && doc.objectsRevision == objectsRevision)

        doc.cancelTransform(session)
        #expect(doc.strokes[0] == stroke)
        #expect(doc.object(id: object.id)?.transform == .identity)
    }

    @Test func anIdentityDragRecordsNothing() {
        let doc = CanvasDocument()
        let object = placeholder()
        doc.addObject(object)
        let session = doc.beginTransform(PageSelection(objectIDs: [object.id]))
        doc.previewTransform(session, by: CGAffineTransform(translationX: 3, y: 0))
        doc.commitTransform(session, by: .identity)
        doc.undo() // undoes the add, not a transform
        #expect(doc.objectCount == 0)
    }

    @Test func deletingASelectionRemovesInkAndObjectsInOneStep() {
        let doc = CanvasDocument()
        let a = placeholder(), b = placeholder(CGRect(x: 0, y: 0, width: 5, height: 5))
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        doc.addObject(a)
        doc.add(stroke)
        doc.addObject(b)
        doc.delete(PageSelection(strokeIDs: [stroke.id], objectIDs: [a.id]))
        #expect(doc.strokeCount == 0)
        #expect(doc.objects.map(\.id) == [b.id])
        doc.undo()
        #expect(doc.strokeCount == 1)
        #expect(doc.objects.map(\.id) == [a.id, b.id]) // back in its place in the stack
        doc.redo()
        #expect(doc.objects.map(\.id) == [b.id])
    }

    @Test func clearingThePageRemovesObjectsToo() {
        let doc = CanvasDocument()
        doc.addObject(placeholder())
        doc.clear()
        #expect(doc.objectCount == 0)
        doc.undo()
        #expect(doc.objectCount == 1)
    }

    @Test func pixelEraserStrokesAreNeverTransformed() {
        let doc = CanvasDocument()
        let eraser = Stroke(id: UUID(), color: RGBA.swatches[0], brush: TestBrush.pixelEraser.brush(width: 10),
                            points: makeStroke(at: .zero).points)
        doc.add(eraser)
        let session = doc.beginTransform(PageSelection(strokeIDs: [eraser.id]))
        #expect(session.strokes.isEmpty)
    }
}

@Suite("Transforming ink")
struct StrokeTransformTests {
    @Test func aRigidMoveKeepsTheBrushExactly() {
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        let moved = stroke.applying(CGAffineTransform(translationX: 3, y: 4))
        #expect(moved.brush == stroke.brush)
        #expect(moved.points.map(\.azimuth) == stroke.points.map(\.azimuth))
        #expect(moved.points[0].location == CGPoint(x: 13, y: 14))
    }

    @Test func scalingScalesTheWidth() {
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        let doubled = stroke.applying(CGAffineTransform(scaleX: 2, y: 2))
        #expect(abs(doubled.brush.size.upperBound - stroke.brush.size.upperBound * 2) < 1e-9)
        #expect(abs(doubled.brush.size.lowerBound - stroke.brush.size.lowerBound * 2) < 1e-9)
        #expect(doubled.points[1].location == CGPoint(x: 30, y: 30))
    }

    @Test func rotatingTurnsTheAzimuthAndAFlatNib() {
        var stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        stroke.brush.tip = .ellipse(aspect: 0.3, angle: 0.2)
        let turned = stroke.applying(rotation(.pi / 2, about: .zero))
        #expect(abs(turned.points[0].azimuth - .pi / 2) < 1e-9)
        if case let .ellipse(_, angle) = turned.brush.tip {
            #expect(abs(angle - (0.2 + .pi / 2)) < 1e-9)
        } else {
            Issue.record("tip changed shape")
        }
        #expect(abs(turned.brush.size.upperBound - stroke.brush.size.upperBound) < 1e-9)
        #expect(close(turned.points[0].location, CGPoint(x: -10, y: 10)))
    }
}

@Suite("Selection geometry")
struct SelectionGeometryTests {
    private func shape(_ stroke: Stroke) -> SelectionGeometry.StrokeShape {
        let path = stroke.points.map(\.location)
        return .init(id: stroke.id, path: path, bounds: LassoGeometry.bounds(of: path).insetBy(dx: -2, dy: -2),
                     radius: 2)
    }

    @Test func aTapPrefersInkThenTheTopObject() {
        let below = placeholder(CGRect(x: 0, y: 0, width: 100, height: 100))
        var above = placeholder(CGRect(x: 50, y: 50, width: 100, height: 100))
        above.zIndex = 1
        let ink = makeStroke(at: CGPoint(x: 60, y: 60)) // (60,60) → (65,65)
        let strokes = [shape(ink)]
        let objects: [any PageObject] = [below, above]

        #expect(SelectionGeometry.hitTest(CGPoint(x: 62, y: 62), tolerance: 1, strokes: strokes, objects: objects)
            == PageSelection(strokeIDs: [ink.id]))
        #expect(SelectionGeometry.hitTest(CGPoint(x: 90, y: 60), tolerance: 1, strokes: strokes, objects: objects)
            == PageSelection(objectIDs: [above.id]))
        #expect(SelectionGeometry.hitTest(CGPoint(x: 10, y: 10), tolerance: 1, strokes: strokes, objects: objects)
            == PageSelection(objectIDs: [below.id]))
        #expect(SelectionGeometry.hitTest(CGPoint(x: 300, y: 300), tolerance: 1, strokes: strokes, objects: objects) == nil)
    }

    @Test func aTapFollowsAnObjectsRotation() {
        let object = placeholder(CGRect(x: 0, y: 0, width: 100, height: 10))
            .applying(rotation(.pi / 2, about: CGPoint(x: 50, y: 5)))
        // Turned upright about its centre: now 10 wide and 100 tall.
        #expect(SelectionGeometry.hitTest(CGPoint(x: 50, y: 40), tolerance: 0, strokes: [], objects: [object]) != nil)
        #expect(SelectionGeometry.hitTest(CGPoint(x: 90, y: 5), tolerance: 0, strokes: [], objects: [object]) == nil)
    }

    @Test func theLassoSelectsObjectsItTouchesOrIsInside() {
        let touched = placeholder(CGRect(x: 0, y: 0, width: 50, height: 50))
        let missed = placeholder(CGRect(x: 200, y: 200, width: 50, height: 50))
        let big = placeholder(CGRect(x: 400, y: 0, width: 500, height: 500))
        let ink = makeStroke(at: CGPoint(x: 30, y: 60))
        let square: [CGPoint] = [CGPoint(x: 25, y: 25), CGPoint(x: 100, y: 25), CGPoint(x: 100, y: 100),
                                 CGPoint(x: 25, y: 100)]
        let selection = SelectionGeometry.select(in: square, strokes: [shape(ink)], objects: [touched, missed, big])
        #expect(selection == PageSelection(strokeIDs: [ink.id], objectIDs: [touched.id]))

        let inside = square.map { CGPoint(x: $0.x + 500, y: $0.y + 100) }
        #expect(SelectionGeometry.select(in: inside, strokes: [], objects: [big]).objectIDs == [big.id])
    }

    @Test func aSingleObjectGetsItsOwnRotatedBox() throws {
        let t = rotation(.pi / 4, about: CGPoint(x: 50, y: 50))
        let object = placeholder(CGRect(x: 0, y: 0, width: 100, height: 100)).applying(t)
        let box = try #require(SelectionGeometry.box(strokeBounds: [], objects: [object]))
        #expect(box.rect == object.frame)
        #expect(box.transform == t)
        let several = try #require(SelectionGeometry.box(strokeBounds: [CGRect(x: 500, y: 500, width: 1, height: 1)],
                                                         objects: [object]))
        #expect(several.transform == .identity)
        #expect(several.rect.contains(CGPoint(x: 500, y: 500)))
    }

    @Test func handlesAreFoundRotateKnobFirstThenCornersThenInside() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        func handle(_ p: CGPoint) -> SelectionHandle? {
            SelectionGeometry.handle(at: p, box: box, reach: 10, rotateDistance: 30)
        }
        #expect(handle(CGPoint(x: 50, y: -30)) == .rotate)
        #expect(handle(CGPoint(x: 98, y: 52)) == .corner(.bottomRight))
        #expect(handle(CGPoint(x: 2, y: 1)) == .corner(.topLeft))
        #expect(handle(CGPoint(x: 50, y: 25)) == .move)
        #expect(handle(CGPoint(x: 300, y: 300)) == nil)
    }

    @Test func resizingKeepsTheOppositeCornerAndNeverFlips() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let t = SelectionGeometry.transform(for: .corner(.bottomRight), box: box, from: CGPoint(x: 100, y: 50),
                                            to: CGPoint(x: 200, y: 75))
        #expect(close(CGPoint.zero.applying(t), .zero))
        #expect(close(CGPoint(x: 100, y: 50).applying(t), CGPoint(x: 200, y: 75)))

        // Dragged past the anchor: held at the minimum size instead of turning inside out.
        let squashed = SelectionGeometry.transform(for: .corner(.bottomRight), box: box, from: CGPoint(x: 100, y: 50),
                                                   to: CGPoint(x: -100, y: -100), minimumSize: 4)
        let corner = CGPoint(x: 100, y: 50).applying(squashed)
        #expect(close(corner, CGPoint(x: 4, y: 4)))
    }

    @Test func resizingARotatedBoxWorksInItsOwnAxes() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50),
                               transform: rotation(.pi / 2, about: .zero))
        let grabbed = box.point(for: .bottomRight), anchor = box.point(for: .topLeft)
        // Pull the corner 50 points further along the box's own x axis (the page's y axis after the turn).
        let t = SelectionGeometry.transform(for: .corner(.bottomRight), box: box, from: grabbed,
                                            to: CGPoint(x: grabbed.x, y: grabbed.y + 50))
        #expect(close(anchor.applying(t), anchor))
        #expect(close(grabbed.applying(t), CGPoint(x: grabbed.x, y: grabbed.y + 50)))
        let resized = box.applying(t)
        #expect(close(resized.point(for: .topRight), CGPoint(x: 0, y: 150)))
    }

    @Test func rotatingTurnsAboutTheCentre() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let t = SelectionGeometry.transform(for: .rotate, box: box, from: CGPoint(x: 50, y: -30),
                                            to: CGPoint(x: 130, y: 50))
        #expect(close(CGPoint(x: 50, y: 50).applying(t), CGPoint(x: 50, y: 50)))
        #expect(abs(atan2(t.b, t.a) - .pi / 2) < 1e-9)
    }
}

@Suite("Page objects file")
struct PageObjectsFileTests {
    private let pageID = UUID()

    @Test func roundTripsInStackingOrder() throws {
        var low = placeholder(CGRect(x: 1, y: 2, width: 3, height: 4))
        low.zIndex = 0
        var high = placeholder().applying(rotation(0.3, about: CGPoint(x: 5, y: 5)))
        high.zIndex = 7
        let file = PageObjectsFile(pageID: pageID, objects: [high, low])
        #expect(file.objects.map(\.id) == [low.id, high.id])

        let data = try file.encoded()
        let read = try PageObjectsFile(data: data)
        #expect(read.pageID == pageID)
        #expect(read.formatVersion == 1)
        #expect(read.objects.compactMap { $0 as? PlaceholderObject } == [low, high])
        #expect(try read.encoded() == data) // the same page always writes the same bytes
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"kind\" : \"placeholder\""))
        #expect(json.contains("\"formatVersion\" : 1"))
    }

    @Test func objectsOfUnknownKindsAreKeptAsTheyWere() throws {
        let json = """
        {"formatVersion": 1, "pageID": "\(pageID.uuidString)", "objects": [
          {"kind": "hologram", "id": "\(UUID().uuidString)", "frame": {"x": 1, "y": 2, "width": 3, "height": 4},
           "zIndex": 2, "glow": {"colors": ["#FF0000", null], "strength": 0.5, "on": true}},
          {"kind": "placeholder", "id": "\(UUID().uuidString)", "frame": {"x": 0, "y": 0, "width": 9, "height": 9},
           "transform": [1, 0, 0, 1, 0, 0], "zIndex": 1, "color": "#00FF00"}
        ]}
        """
        let file = try PageObjectsFile(data: Data(json.utf8))
        #expect(file.objects.count == 2)
        #expect(file.objects[0] is PlaceholderObject) // zIndex 1 under zIndex 2
        let unknown = try #require(file.objects[1] as? UnknownPageObject)
        #expect(!PageObjectKinds.isSelectable(unknown))

        let reread = try PageObjectsFile(data: file.encoded())
        let kept = try #require(reread.objects[1] as? UnknownPageObject)
        #expect(kept.json == unknown.json)
        guard case let .object(fields) = kept.json else { Issue.record("not an object"); return }
        #expect(fields["kind"] == .string("hologram"))
        #expect(fields["glow"] != nil)
    }

    @Test func aNewerFormatIsRefused() {
        let json = #"{"formatVersion": 2, "pageID": "\#(pageID.uuidString)", "objects": []}"#
        #expect(throws: PageObjectsFileError.unsupportedVersion(2)) { try PageObjectsFile(data: Data(json.utf8)) }
    }

    @Test func damagedFilesThrow() {
        #expect(throws: PageObjectsFileError.notAnObjectsFile) { try PageObjectsFile(data: Data("not json".utf8)) }
        #expect(throws: PageObjectsFileError.notAnObjectsFile) { try PageObjectsFile(data: Data("{}".utf8)) }
        let id = UUID().uuidString
        func file(_ object: String) -> Data {
            Data(#"{"formatVersion": 1, "pageID": "\#(pageID.uuidString)", "objects": [\#(object)]}"#.utf8)
        }
        let unit = #""frame": {"x": 0, "y": 0, "width": 1, "height": 1}"#
        let flat = #"{"kind": "placeholder", "id": "\#(id)", \#(unit), "transform": [0, 0, 0, 0, 0, 0]}"#
        let negative = #"{"kind": "placeholder", "id": "\#(id)", "frame": {"x": 0, "y": 0, "width": -1, "height": 1}}"#
        let noFrame = #"{"kind": "placeholder", "id": "\#(id)"}"#
        let short = #"{"kind": "placeholder", "id": "\#(id)", \#(unit), "transform": [1, 0]}"#
        let twice = #"{"kind": "placeholder", "id": "\#(id)", \#(unit)}"#
        for bad in [flat, negative, noFrame, short, "\(twice), \(twice)"] {
            #expect(throws: PageObjectsFileError.self) { try PageObjectsFile(data: file(bad)) }
        }
    }

    @Test func missingOptionalKeysTakeDefaults() throws {
        let object = #"{"kind": "placeholder", "id": "\#(UUID().uuidString)", "#
            + #""frame": {"x": 0, "y": 0, "width": 1, "height": 1}, "color": "nonsense"}"#
        let json = #"{"formatVersion": 1, "pageID": "\#(pageID.uuidString)", "objects": [\#(object)]}"#
        let read = try #require(PageObjectsFile(data: Data(json.utf8)).objects.first as? PlaceholderObject)
        #expect(read.transform == .identity)
        #expect(read.zIndex == 0)
    }

    @MainActor
    @Test func aPageOpensWithItsObjectsAndSavesThemBack() throws {
        let object = placeholder()
        let file = PageObjectsFile(pageID: pageID, objects: [object])
        let page = CanvasDocument(file: InkPageFile(pageID: pageID), objects: file, pageSize: .letter)
        #expect(page.objectCount == 1)
        #expect(!page.canUndo)
        #expect(try page.objectsFile.encoded() == file.encoded())
        #expect(CanvasDocument(file: InkPageFile(pageID: pageID), pageSize: .letter).objectsFile.isEmpty)
    }
}

@MainActor
@Suite("Page objects: rendering")
struct PageObjectRenderingTests {
    @Test func objectsCountAsContent() {
        let doc = CanvasDocument()
        #expect(doc.snapshot().isBlank)
        doc.addObject(placeholder())
        #expect(!doc.snapshot().isBlank)
        #expect(doc.snapshot().objectsRevision == 1)
    }

    @Test func objectsAreDrawnUnderTheInk() throws {
        let doc = CanvasDocument(pageSize: PageSize(width: 100, height: 100))
        doc.addObject(PlaceholderObject(frame: CGRect(x: 0, y: 0, width: 100, height: 100), color: PenColor(rgb: 0x0000FF)))
        var stroke = makeStroke(at: CGPoint(x: 20, y: 50))
        stroke.brush = stroke.brush.sized(20, minimumRatio: 1)
        stroke.color = RGBA(r: 1, g: 0, b: 0)
        stroke.points.append(StrokePoint(location: CGPoint(x: 80, y: 50), force: 1, altitude: .pi / 2,
                                         azimuth: 0, timestamp: 2))
        doc.add(stroke)
        let image = try #require(PageRenderer.image(of: doc.snapshot(), pixelWidth: 100) { ctx, size in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        })
        let ink = rgba(image, x: 50, y: 50), object = rgba(image, x: 70, y: 20)
        #expect(ink.r > 200 && ink.b < 60) // red ink over the blue tint
        #expect(object.b > object.r) // the object's tint
    }
}

private struct Pixel {
    let r, g, b, a: UInt8
}

private func rgba(_ image: CGImage, x: Int, y: Int) -> Pixel {
    var data = [UInt8](repeating: 0, count: 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return Pixel(r: data[0], g: data[1], b: data[2], a: data[3])
}
