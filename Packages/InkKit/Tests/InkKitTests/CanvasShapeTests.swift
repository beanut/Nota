import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// The shape tool, hold-to-snap and reshaping shapes on a real `CanvasView`. Strokes are built as live
/// strokes in canvas space and handed to the canvas as its touch handling would at lift or on hold.
@MainActor
@Suite("Canvas shapes")
struct CanvasShapeTests {
    let document = CanvasDocument(pageSize: .letter)
    let controller: CanvasController
    let canvas: CanvasView

    init() throws {
        let suite = "CanvasShapeTests.\(UUID().uuidString)"
        controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: suite)),
                                          penTray: PenTrayStore(fileURL: nil))
        canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
    }

    /// A live stroke through `path` (canvas space), sampled every couple of points, in the current tool.
    private func liveStroke(_ path: [CGPoint]) -> LiveStroke {
        let template = controller.strokeTemplate(viewScale: canvas.viewTransform.scale)
        let live = LiveStroke(stroke: Stroke(id: UUID(), color: template.color, brush: template.brush, points: []))
        let dense = ShapeRecognizer.resample(path, count: max(Int(ShapeRecognizer.pathLength(path) / 2), 4))
        for (i, p) in dense.enumerated() {
            _ = live.append(StrokePoint(location: p, force: 0.5, altitude: .pi / 2, azimuth: 0,
                                        timestamp: TimeInterval(i) / 240), minSpacing: 0.1)
        }
        return live
    }

    private var shapes: [ShapeObject] {
        document.objects.compactMap { $0 as? ShapeObject }
    }

    private func square(_ origin: CGPoint, side: CGFloat) -> [CGPoint] {
        [origin, CGPoint(x: origin.x + side, y: origin.y), CGPoint(x: origin.x + side, y: origin.y + side),
         CGPoint(x: origin.x, y: origin.y + side), origin]
    }

    /// One lasso gesture through `points` (canvas space).
    private func drag(_ points: [CGPoint]) {
        canvas.lassoPending = true
        for point in points {
            canvas.handleLassoSample(point)
        }
        canvas.finishLasso(commit: true)
    }

    // MARK: Shape tool

    @Test func theShapeToolTurnsEveryStrokeIntoAShape() throws {
        controller.select(.shape)
        controller.shapeLineStyle = .dashed
        controller.shapeFill = PenColor(rgb: 0xFFD60A)
        #expect(canvas.convertToShape(liveStroke(square(CGPoint(x: 100, y: 100), side: 200))))
        let rect = try #require(shapes.first)
        #expect(rect.shape == .rectangle)
        #expect(rect.style == controller.newShapeStyle)
        #expect(abs(rect.bounds.width - 200) < 4)
        #expect(document.strokeCount == 0) // no ink left behind

        // A zigzag isn't a shape, but the shape tool makes a curve through it rather than leaving ink.
        let zigzag = [CGPoint(x: 100, y: 500), CGPoint(x: 140, y: 600), CGPoint(x: 180, y: 520), CGPoint(x: 220, y: 600)]
        #expect(canvas.convertToShape(liveStroke(zigzag)))
        #expect(shapes.last?.shape == .curve)

        canvas.undo()
        canvas.undo()
        #expect(document.objectCount == 0)
    }

    @Test func otherToolsLeaveTheirInkAlone() {
        controller.select(.pen)
        #expect(!canvas.convertToShape(liveStroke(square(CGPoint(x: 100, y: 100), side: 200))))
        #expect(document.objectCount == 0)
    }

    // MARK: Hold to snap

    @Test func holdingAPenStrokeSnapsItAndThePencilCanStretchIt() throws {
        controller.select(.pen)
        let start = CGPoint(x: 100, y: 300), end = CGPoint(x: 400, y: 306)
        canvas.snapToShape(liveStroke([start, end]), holdingAt: end)
        let snap = try #require(canvas.shapeSnap)
        #expect(snap.shape.shape == .line)
        #expect(snap.shape.strokeColor == controller.color(for: .pen))
        #expect(document.objectCount == 0) // shown, not on the page until the Pencil lifts

        // A small wobble while holding doesn't move it; moving on drags the end, kept horizontal.
        canvas.updateShapeSnap(to: CGPoint(x: end.x + 0.5, y: end.y))
        #expect(canvas.shapeSnap?.shape == snap.shape)
        canvas.updateShapeSnap(to: CGPoint(x: end.x + 100, y: end.y + 3))
        let stretched = try #require(canvas.shapeSnap?.shape)
        #expect(abs(stretched.handles[1].x - 500) < 1)
        #expect(stretched.handles[1].y == stretched.handles[0].y)

        canvas.finishShapeSnap(commit: true)
        #expect(canvas.shapeSnap == nil)
        #expect(shapes.first?.handles == stretched.handles)
        canvas.undo()
        #expect(document.objectCount == 0)
    }

    @Test func holdingHandwritingLeavesItAsInk() {
        controller.select(.pen)
        let w = [CGPoint(x: 100, y: 100), CGPoint(x: 130, y: 200), CGPoint(x: 160, y: 120), CGPoint(x: 190, y: 200),
                 CGPoint(x: 220, y: 100)]
        canvas.snapToShape(liveStroke(w), holdingAt: w[4])
        #expect(canvas.shapeSnap == nil)
        // Too small to be a shape, however straight.
        canvas.snapToShape(liveStroke([CGPoint(x: 100, y: 100), CGPoint(x: 110, y: 100)]), holdingAt: CGPoint(x: 110, y: 100))
        #expect(canvas.shapeSnap == nil)
    }

    @Test func holdToSnapCanBeTurnedOffAndNeverAppliesToTheHighlighter() {
        controller.select(.pen)
        #expect(canvas.snapsShapesOnHold(controller))
        controller.pencilSettings.holdToSnapShapes = false
        #expect(!canvas.snapsShapesOnHold(controller))
        controller.select(.shape)
        #expect(canvas.snapsShapesOnHold(controller))
        controller.select(.highlighter)
        controller.pencilSettings.holdToSnapShapes = true
        #expect(!canvas.snapsShapesOnHold(controller))
    }

    @Test func aCancelledSnapLeavesNothing() {
        controller.select(.pencil)
        canvas.snapToShape(liveStroke([CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 300)]), holdingAt: CGPoint(x: 400, y: 300))
        #expect(canvas.shapeSnap != nil)
        canvas.finishShapeSnap(commit: false)
        #expect(document.objectCount == 0)
    }

    // MARK: Handles

    @Test func aLinesEndIsDraggedSnappedAndUndone() throws {
        let style = ShapeStyle(color: PenColor(rgb: 0), lineWidth: 2)
        let box = ShapeObject(.rectangle, frame: CGRect(x: 500, y: 500, width: 100, height: 100), style: style)
        document.addObject(box)
        document.addObject(ShapeObject(.line, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)], style: style))
        let line = try #require(shapes.last)
        controller.select(.lasso)
        canvas.select(PageSelection(objectIDs: [line.id]))
        #expect(controller.selectedShapeStyle == style)

        // Drag the end (grabbed a little off it) to near the box's corner: it lands on the corner.
        drag([CGPoint(x: 302, y: 101), CGPoint(x: 400, y: 300), CGPoint(x: 505, y: 497)])
        let reshaped = try #require(shapes.last)
        #expect(reshaped.handles[1] == CGPoint(x: 500, y: 500))
        #expect(reshaped.handles[0] == CGPoint(x: 100, y: 100))
        #expect(canvas.selection == PageSelection(objectIDs: [line.id])) // still selected

        canvas.undo()
        #expect(shapes.last?.handles == line.handles)
    }

    @Test func aLineIsMovedByDraggingAlongItNotItsBox() throws {
        let style = ShapeStyle(color: PenColor(rgb: 0), lineWidth: 2)
        document.addObject(ShapeObject(.arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)], style: style))
        let arrow = try #require(shapes.first)
        controller.select(.lasso)
        canvas.select(PageSelection(objectIDs: [arrow.id]))
        drag([CGPoint(x: 200, y: 102), CGPoint(x: 220, y: 132), CGPoint(x: 240, y: 162)])
        let moved = try #require(shapes.first)
        #expect(moved.handles[0].distance(to: CGPoint(x: 140, y: 160)) < 1e-6)
    }

    @Test func selectedShapesAreRestyledInOneStep() {
        let style = ShapeStyle(color: PenColor(rgb: 0), lineWidth: 2)
        document.addObject(ShapeObject(.ellipse, frame: CGRect(x: 0, y: 0, width: 50, height: 50), style: style))
        document.addObject(ShapeObject(.rectangle, frame: CGRect(x: 100, y: 0, width: 50, height: 50), style: style))
        controller.select(.lasso)
        canvas.select(PageSelection(objectIDs: Set(shapes.map(\.id))))
        let yellow = PenColor(rgb: 0xFFD60A)
        controller.restyleSelectedShapes { $0.fill = yellow }
        #expect(shapes.allSatisfy { $0.fill == yellow })
        #expect(controller.selectedShapeStyle?.fill == yellow)
        canvas.undo()
        #expect(shapes.allSatisfy { $0.fill == nil })
    }
}
