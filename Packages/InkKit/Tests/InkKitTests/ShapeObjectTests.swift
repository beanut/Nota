import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

private let blue = PenColor(rgb: 0x0A5BD6)
private let style = ShapeStyle(color: blue, lineWidth: 3)

private func close(_ a: CGPoint, _ b: CGPoint, within e: CGFloat = 1e-6) -> Bool {
    a.distance(to: b) <= e
}

@Suite("Shape objects")
struct ShapeObjectTests {
    @Test func pointShapesAreTheirPointsAndFrameFollowsThem() {
        let line = ShapeObject(.line, points: [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20)], style: style)
        #expect(line.frame == CGRect(x: 10, y: 20, width: 100, height: 0))
        #expect(line.handles == [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20)])

        let moved = line.movingHandle(1, to: CGPoint(x: 60, y: 80))
        #expect(moved.points[1] == CGPoint(x: 60, y: 80))
        #expect(moved.frame == CGRect(x: 10, y: 20, width: 50, height: 60))
        #expect(moved.id == line.id)
    }

    @Test func handlesFollowTheTransform() {
        let triangle = ShapeObject(.triangle, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 80)],
                                   style: style)
            .applying(CGAffineTransform(translationX: 40, y: 10))
        #expect(triangle.handles[1] == CGPoint(x: 140, y: 10))
        // Dragging a handle on the page puts that corner exactly there.
        let reshaped = triangle.movingHandle(2, to: CGPoint(x: 90, y: 200))
        #expect(close(reshaped.handles[2], CGPoint(x: 90, y: 200)))
        #expect(close(reshaped.handles[0], CGPoint(x: 40, y: 10)))
    }

    @Test func framedShapesHaveNoHandlesOfTheirOwn() {
        let rect = ShapeObject(.rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), style: style)
        #expect(rect.handles.isEmpty)
        #expect(rect.snapAnchors.count == 9)
        #expect(rect.snapAnchors.contains(CGPoint(x: 40, y: 20)))
    }

    @Test func theLineKeepsOneWidthAndScalesWithArea() {
        let rect = ShapeObject(.rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), style: style)
        #expect(rect.drawnLineWidth == 3)
        #expect(abs(rect.applying(CGAffineTransform(scaleX: 2, y: 2)).drawnLineWidth - 6) < 1e-9)
        #expect(abs(rect.applying(CGAffineTransform(rotationAngle: 1)).drawnLineWidth - 3) < 1e-9)
    }

    @Test func anArrowHasAHeadAtItsEnd() throws {
        let arrow = ShapeObject(.arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)], style: style)
        let head = try #require(arrow.arrowHead(width: 3))
        #expect(head[1] == CGPoint(x: 200, y: 0))
        #expect(head[0].x < 200 && head[2].x < 200)
        #expect(head[0].y * head[2].y < 0) // one barb each side
    }

    @Test func everyKindDrawsWithoutCrashing() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var filled = style
        filled.fill = blue
        for lineStyle in ShapeObject.LineStyle.allCases {
            filled.lineStyle = lineStyle
            let shapes = [
                ShapeObject(.ellipse, frame: CGRect(x: 4, y: 4, width: 50, height: 30), style: filled),
                ShapeObject(.polygon, points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 5), CGPoint(x: 40, y: 40),
                                               CGPoint(x: 5, y: 30)], style: filled),
                ShapeObject(.curve, points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 50), CGPoint(x: 60, y: 10)],
                            style: filled),
                ShapeObject(.arrow, points: [CGPoint(x: 0, y: 60), CGPoint(x: 60, y: 0)], style: filled)
            ]
            for shape in shapes {
                shape.draw(in: ctx)
            }
        }
    }

    // MARK: Coding

    @Test func shapesRoundTripThroughThePageFile() throws {
        var filled = style
        filled.fill = PenColor(rgb: 0xFFD60A)
        filled.lineStyle = .dashed
        let shapes: [any PageObject] = [
            ShapeObject(.rectangle, frame: CGRect(x: 10, y: 10, width: 100, height: 50),
                        transform: CGAffineTransform(rotationAngle: 0.3), style: filled),
            ShapeObject(.arrow, points: [CGPoint(x: 1, y: 2), CGPoint(x: 300, y: 4.5)], zIndex: 1, style: style),
            ShapeObject(.curve, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 5)], zIndex: 2,
                        style: style)
        ]
        let file = PageObjectsFile(pageID: UUID(), objects: shapes)
        let read = try PageObjectsFile(data: file.encoded())
        let back = read.objects.compactMap { $0 as? ShapeObject }
        #expect(back == shapes.compactMap { $0 as? ShapeObject })
    }

    @Test func readingIsLenient() throws {
        let id = UUID()
        let json = """
        { "formatVersion": 1, "pageID": "\(UUID().uuidString)", "objects": [
          { "kind": "shape", "id": "\(id.uuidString)", "frame": { "x": 5, "y": 6, "width": 70, "height": 40 },
            "shape": "star", "points": [[0, 0], [1, 1]], "strokeColor": "nope", "lineWidth": -4, "lineStyle": "wavy" }
        ] }
        """
        let file = try PageObjectsFile(data: Data(json.utf8))
        let shape = try #require(file.objects.first as? ShapeObject)
        #expect(shape.id == id)
        #expect(shape.shape == .rectangle) // an unknown kind keeps its frame
        #expect(shape.frame == CGRect(x: 5, y: 6, width: 70, height: 40))
        #expect(shape.strokeColor == ShapeObject.defaultColor)
        #expect(shape.lineWidth == 0.1)
        #expect(shape.lineStyle == .solid)
        #expect(shape.fill == nil)
    }

    @Test func pointsThatDontFitTheKindKeepTheFrame() throws {
        let json = """
        { "kind": "shape", "id": "\(UUID().uuidString)", "frame": { "x": 0, "y": 0, "width": 10, "height": 10 },
          "shape": "triangle", "points": [[0, 0], [5, 5]] }
        """
        let shape = try JSONDecoder().decode(ShapeObject.self, from: Data(json.utf8))
        #expect(shape.shape == .rectangle)
        #expect(shape.points.isEmpty)
    }
}

@MainActor
@Suite("Shape objects: undoable reshape")
struct ShapeCommandTests {
    @Test func replacingObjectsIsOneUndoableEdit() throws {
        let doc = CanvasDocument()
        let line = ShapeObject(.line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], style: style)
        doc.addObject(line)
        let stacked = try #require(doc.objects.first as? ShapeObject)
        let moved = stacked.movingHandle(1, to: CGPoint(x: 100, y: 100))

        doc.previewObjects([moved])
        #expect((doc.objects.first as? ShapeObject) == moved)
        let revision = doc.objectsRevision
        doc.previewObjects([stacked]) // a preview records nothing
        #expect(doc.objectsRevision == revision)

        doc.replaceObjects(before: [stacked], after: [moved])
        #expect((doc.objects.first as? ShapeObject) == moved)
        #expect(doc.revision == 0) // the ink's committed layer is still good
        doc.undo()
        #expect((doc.objects.first as? ShapeObject) == stacked)
        doc.redo()
        #expect((doc.objects.first as? ShapeObject) == moved)
    }
}
