import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// The lasso on a real `CanvasView`: adding the test object, dragging the selection box's handles, lasso
/// and tap selection of ink and objects together, undo and redo. Samples are fed in canvas space, as the
/// canvas's touch handling does after mapping a touch.
@MainActor
@Suite("Canvas selection")
struct CanvasSelectionTests {
    let document = CanvasDocument(pageSize: .letter)
    let controller: CanvasController
    let canvas: CanvasView

    init() throws {
        let suite = "CanvasSelectionTests.\(UUID().uuidString)"
        controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: suite)),
                                          penTray: PenTrayStore(fileURL: nil))
        canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
    }

    /// One lasso gesture through `points` (canvas space).
    private func drag(_ points: [CGPoint]) {
        canvas.lassoPending = true
        for point in points {
            canvas.handleLassoSample(point)
        }
        canvas.finishLasso(commit: true)
    }

    private func drag(from start: CGPoint, to end: CGPoint) {
        drag([start, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), end])
    }

    private func placeholder() throws -> PlaceholderObject {
        try #require(document.objects.first as? PlaceholderObject)
    }

    @Test func theTestObjectIsAddedMovedResizedRotatedAndUndone() throws {
        controller.insertPlaceholderObject()
        #expect(controller.tool == .lasso)
        #expect(controller.hasSelection)
        let added = try placeholder()
        #expect(document.pageBounds.contains(added.bounds))

        // Move: drag from inside the box.
        let center = try #require(canvas.selectionBox).center
        drag(from: center, to: CGPoint(x: center.x + 50, y: center.y + 20))
        #expect(try placeholder().transform == CGAffineTransform(translationX: 50, y: 20))

        // Resize: the bottom-right knob, keeping the top-left corner.
        let box = try #require(canvas.selectionBox)
        let topLeft = box.point(for: .topLeft), corner = box.point(for: .bottomRight)
        drag(from: corner, to: CGPoint(x: corner.x + 40, y: corner.y + 30))
        let resized = try placeholder()
        #expect(resized.corners[0].distance(to: topLeft) < 1e-6)
        #expect(resized.corners[2].distance(to: CGPoint(x: corner.x + 40, y: corner.y + 30)) < 1e-6)

        // Rotate: the knob above the box, a quarter turn about the centre.
        let turned = try #require(canvas.selectionBox)
        let knob = SelectionGeometry.rotateHandle(of: turned, distance: CanvasView.rotateHandleDistance / canvas.viewTransform.scale)
        let c = turned.center, r = knob.distance(to: c)
        drag([knob, CGPoint(x: c.x + r * 0.7, y: c.y - r * 0.7), CGPoint(x: c.x + r, y: c.y)])
        let rotated = try placeholder()
        let angle = atan2(rotated.transform.b, rotated.transform.a)
        #expect(abs(angle - .pi / 2) < 1e-6)
        // The box turned with it, so the next drag works in the object's own axes.
        #expect(try abs(atan2(#require(canvas.selectionBox).transform.b, #require(canvas.selectionBox).transform.a) - .pi / 2) < 1e-6)

        canvas.undo() // rotation
        #expect(try placeholder().transform == resized.transform)
        canvas.undo() // resize
        canvas.undo() // move
        #expect(try placeholder().transform == .identity)
        canvas.undo() // add
        #expect(document.objectCount == 0)
        #expect(!controller.hasSelection)
        canvas.redo()
        canvas.redo()
        #expect(try placeholder().transform == CGAffineTransform(translationX: 50, y: 20))
    }

    @Test func inkAndObjectsAreSelectedAndTransformedTogether() throws {
        let stroke = makeStroke(at: CGPoint(x: 100, y: 100))
        document.add(stroke)
        controller.insertPlaceholderObject()
        canvas.clearSelection()
        controller.lassoMode = .square
        drag([CGPoint(x: 20, y: 20), CGPoint(x: 600, y: 760)])
        #expect(try canvas.selection == PageSelection(strokeIDs: [stroke.id], objectIDs: [placeholder().id]))

        let center = try #require(canvas.selectionBox).center
        drag(from: center, to: CGPoint(x: center.x - 10, y: center.y + 15))
        #expect(document.strokes[0].points[0].location == CGPoint(x: 90, y: 115))
        #expect(try placeholder().transform == CGAffineTransform(translationX: -10, y: 15))

        canvas.undo() // one step for both
        #expect(document.strokes[0] == stroke)
        #expect(try placeholder().transform == .identity)
    }

    @Test func aTapSelectsTheTopmostThingUnderIt() throws {
        controller.insertPlaceholderObject()
        let object = try placeholder()
        let stroke = makeStroke(at: CGPoint(x: object.frame.midX, y: object.frame.midY))
        document.add(stroke)
        canvas.clearSelection()

        drag([stroke.points[0].location]) // the ink, drawn over the object
        #expect(canvas.selection == PageSelection(strokeIDs: [stroke.id]))
        drag([CGPoint(x: object.frame.minX + 5, y: object.frame.minY + 5)])
        #expect(canvas.selection == PageSelection(objectIDs: [object.id]))
        drag([CGPoint(x: 5, y: 5)]) // blank paper
        #expect(canvas.selection.isEmpty)
    }

    @Test func deletingTheSelectionRemovesObjectsAndUndoBringsThemBack() {
        controller.insertPlaceholderObject()
        controller.deleteSelection()
        #expect(document.objectCount == 0)
        #expect(!controller.hasSelection)
        canvas.undo()
        #expect(document.objectCount == 1)
    }

    @Test func aCancelledDragPutsEverythingBack() throws {
        controller.insertPlaceholderObject()
        let center = try #require(canvas.selectionBox).center
        canvas.lassoPending = true
        canvas.handleLassoSample(center)
        canvas.handleLassoSample(CGPoint(x: center.x + 80, y: center.y))
        #expect(try placeholder().transform != .identity)
        canvas.finishLasso(commit: false)
        #expect(try placeholder().transform == .identity)
        #expect(canvas.selectionBox?.center == center)
    }
}
