import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

private func approximately(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat = 0.01) -> Bool {
    a.distance(to: b) <= tolerance
}

// MARK: - Clips

@Suite("Selection clips")
struct SelectionClipTests {
    @Test func aClipRoundTripsInkAndObjectsButNotErasers() throws {
        let page = UUID()
        let ink = makeStroke(at: CGPoint(x: 40, y: 50))
        var eraser = makeStroke(at: CGPoint(x: 10, y: 10))
        eraser.brush = TestBrush.pixelEraser.brush(width: 10)
        let object = PlaceholderObject(frame: CGRect(x: 100, y: 100, width: 80, height: 40), color: PenColor(rgb: 0x2563EB))
        let clip = SelectionClip(sourcePageID: page, strokes: [ink, eraser], objects: [object])
        #expect(clip.strokes.map(\.id) == [ink.id])

        let read = try SelectionClip(data: clip.encoded())
        #expect(read.id == clip.id)
        #expect(read.sourcePageID == page)
        #expect(read.strokes.map(\.id) == [ink.id])
        #expect(approximately(read.strokes[0].points[0].location, ink.points[0].location))
        #expect(read.objects.first as? PlaceholderObject == object)
        #expect(read.originalIDs == [ink.id, object.id])
        #expect(read.bounds.contains(object.bounds))
    }

    @Test func clipsFromANewerVersionOrNotClipsAreRefused() throws {
        #expect(throws: SelectionClipError.notAClip) { try SelectionClip(data: Data("nope".utf8)) }
        let newer = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 99, "id": UUID().uuidString, "sourcePageID": UUID().uuidString, "ink": ""
        ])
        #expect(throws: SelectionClipError.unsupportedVersion(99)) { try SelectionClip(data: newer) }
    }

    @Test func copiesGetNewIDsAndMoveByTheOffset() throws {
        let ink = makeStroke(at: CGPoint(x: 40, y: 50))
        let object = PlaceholderObject(frame: CGRect(x: 100, y: 100, width: 80, height: 40), color: PenColor(rgb: 0))
        let clip = SelectionClip(sourcePageID: UUID(), strokes: [ink], objects: [object])
        let copies = try clip.copies(offsetBy: CGPoint(x: 10, y: -5))
        #expect(copies.strokes.count == 1 && copies.objects.count == 1)
        #expect(copies.strokes[0].id != ink.id)
        #expect(copies.objects[0].id != object.id)
        #expect(copies.strokes[0].points[0].location == CGPoint(x: 50, y: 45))
        #expect(copies.strokes[0].brush == ink.brush) // a move doesn't restyle
        #expect(copies.objects[0].bounds == object.bounds.offsetBy(dx: 10, dy: -5))
        #expect((copies.objects[0] as? PlaceholderObject)?.color == object.color)
        // Two lots of copies never share ids.
        let again = try clip.copies(offsetBy: .zero)
        #expect(again.objects[0].id != copies.objects[0].id)
    }

    @Test func pastesKeepTheirPlaceStepAlongOrCentreInView() {
        let visible = CGRect(x: 0, y: 0, width: 600, height: 800)
        let bounds = CGRect(x: 100, y: 100, width: 50, height: 50)
        // On another page (or after a cut): in its own place.
        #expect(PastePlacement.offset(for: bounds, visible: visible, copiesInPlace: 0) == .zero)
        // Beside the originals, and a step further for each earlier paste.
        #expect(PastePlacement.offset(for: bounds, visible: visible, copiesInPlace: 1) == CGPoint(x: 24, y: 24))
        #expect(PastePlacement.offset(for: bounds, visible: visible, copiesInPlace: 2) == CGPoint(x: 48, y: 48))
        // Out of view: centred in what's visible.
        let offscreen = CGRect(x: 100, y: 900, width: 50, height: 50)
        #expect(PastePlacement.offset(for: offscreen, visible: visible, copiesInPlace: 0) == CGPoint(x: 175, y: -525))
        // At a tapped point: centred on it.
        #expect(PastePlacement.offset(for: bounds, visible: visible, copiesInPlace: 3, at: CGPoint(x: 300, y: 300))
            == CGPoint(x: 175, y: 175))
    }
}

// MARK: - Document edits

@MainActor
@Suite("Selection edits")
struct SelectionEditTests {
    let document = CanvasDocument(pageSize: .letter)

    @Test func insertingIsOneUndoStepAndStacksObjectsOnTop() {
        let existing = PlaceholderObject(frame: CGRect(x: 0, y: 0, width: 10, height: 10), color: PenColor(rgb: 0))
        document.addObject(existing)
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        let object = PlaceholderObject(frame: CGRect(x: 50, y: 50, width: 10, height: 10), color: PenColor(rgb: 0))
        let inkRevision = document.revision
        document.insert(strokes: [stroke], objects: [object])
        #expect(document.strokes.map(\.id) == [stroke.id])
        #expect(document.objects.map(\.id) == [existing.id, object.id])
        #expect(document.objects.last?.zIndex == 1)
        #expect(document.revision > inkRevision)

        document.undo()
        #expect(document.strokes.isEmpty)
        #expect(document.objects.map(\.id) == [existing.id])
        document.redo()
        #expect(document.strokes.map(\.id) == [stroke.id])
        #expect(document.objects.count == 2)
    }

    @Test func recolouringAndThickeningAreOneStepEach() {
        var highlight = makeStroke(at: CGPoint(x: 10, y: 10))
        highlight.color.a = 0.4
        let other = makeStroke(at: CGPoint(x: 200, y: 200))
        let object = PlaceholderObject(frame: CGRect(x: 50, y: 50, width: 10, height: 10), color: PenColor(rgb: 0))
        document.add(highlight)
        document.add(other)
        document.addObject(object)
        let selection = PageSelection(strokeIDs: [highlight.id], objectIDs: [object.id])
        let red = PenColor(rgb: 0xFF0000)

        document.restyle(selection, strokes: { s in
            var c = s
            c.color = RGBA(r: 1, g: 0, b: 0, a: s.color.a)
            return c
        }, objects: { $0.recolored(red) })
        #expect(document.strokes[0].color == RGBA(r: 1, g: 0, b: 0, a: 0.4))
        #expect(document.strokes[1] == other) // not selected
        #expect((document.objects[0] as? PlaceholderObject)?.color == red)
        #expect(document.lastReshapedIDs.isEmpty) // a colour doesn't change the outline

        document.restyle(selection, strokes: { s in
            var c = s
            c.brush = s.brush.scaled(by: 2)
            return c
        }, objects: { $0 })
        #expect(document.strokes[0].brush.maxWidth == highlight.brush.maxWidth * 2)
        #expect(document.lastReshapedIDs == [highlight.id])

        document.undo() // thickness
        #expect(document.strokes[0].brush == highlight.brush)
        #expect(document.strokes[0].color.r == 1)
        document.undo() // colour, ink and object together
        #expect(document.strokes[0] == highlight)
        #expect((document.objects[0] as? PlaceholderObject)?.color == object.color)
    }

    @Test func bringingToFrontAndSendingToBackKeepTheSelectionsOwnOrder() {
        let strokes = (0 ..< 4).map { makeStroke(at: CGPoint(x: 10 * $0, y: 10)) }
        for stroke in strokes {
            document.add(stroke)
        }
        let objects = (0 ..< 3).map { _ in
            PlaceholderObject(frame: CGRect(x: 0, y: 0, width: 10, height: 10), color: PenColor(rgb: 0))
        }
        for object in objects {
            document.addObject(object)
        }
        let selection = PageSelection(strokeIDs: [strokes[0].id, strokes[2].id], objectIDs: [objects[0].id])

        document.arrange(selection, .bringToFront)
        #expect(document.strokes.map(\.id) == [strokes[1], strokes[3], strokes[0], strokes[2]].map(\.id))
        #expect(document.objects.map(\.id) == [objects[1], objects[2], objects[0]].map(\.id))
        #expect(document.objects.map(\.zIndex) == [0, 1, 2])

        document.arrange(selection, .sendToBack)
        #expect(document.strokes.map(\.id) == [strokes[0], strokes[2], strokes[1], strokes[3]].map(\.id))
        #expect(document.objects.map(\.id) == objects.map(\.id))

        document.undo()
        document.undo()
        #expect(document.strokes.map(\.id) == strokes.map(\.id))
        // Already at the back: nothing is recorded, so undo takes back the last object added instead.
        document.arrange(PageSelection(strokeIDs: [strokes[0].id]), .sendToBack)
        #expect(document.strokes.map(\.id) == strokes.map(\.id))
        document.undo()
        #expect(document.strokes.count == 4 && document.objects.count == 2)
    }
}

// MARK: - On the canvas

/// The lasso's actions on real `CanvasView`s sharing one controller and a private pasteboard: copy on one
/// page and paste on another (or in another note: it's the same pasteboard), duplicate, recolour and
/// thicken, the filter, the screenshot, the menu and the app's own actions.
@MainActor
@Suite("Lasso actions")
struct LassoActionsTests {
    let pasteboard = UIPasteboard.withUniqueName()
    let controller: CanvasController
    let first = CanvasDocument(pageSize: .letter)
    let second = CanvasDocument(pageSize: .letter)
    let canvas: CanvasView

    init() throws {
        let suite = "LassoActionsTests.\(UUID().uuidString)"
        controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: suite)),
                                          penTray: PenTrayStore(fileURL: nil), pasteboard: pasteboard)
        canvas = Self.canvas(for: first, controller: controller)
        controller.select(.lasso)
    }

    private static func canvas(for document: CanvasDocument, controller: CanvasController) -> CanvasView {
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
        return canvas
    }

    private func lasso(_ canvas: CanvasView, _ points: [CGPoint]) {
        canvas.lassoPending = true
        for point in points {
            canvas.handleLassoSample(point)
        }
        canvas.finishLasso(commit: true)
    }

    /// A stroke and the test object, both selected.
    private func selectInkAndObject() -> (Stroke, PlaceholderObject) {
        let stroke = makeStroke(at: CGPoint(x: 100, y: 100))
        first.add(stroke)
        let object = PlaceholderObject(frame: CGRect(x: 200, y: 200, width: 80, height: 50), color: PenColor(rgb: 0x111827))
        first.addObject(object)
        canvas.refreshObjects()
        canvas.select(PageSelection(strokeIDs: [stroke.id], objectIDs: [object.id]))
        return (stroke, object)
    }

    @Test func aSelectionCopiedOnOnePageIsPastedInPlaceOnAnother() {
        let (stroke, object) = selectInkAndObject()
        #expect(!controller.canPaste)
        controller.copySelection()
        #expect(controller.canPaste)
        #expect(pasteboard.contains(pasteboardTypes: [SelectionClip.pasteboardType]))
        #expect(pasteboard.contains(pasteboardTypes: ["public.png"])) // for other apps

        let other = Self.canvas(for: second, controller: controller)
        controller.paste()
        #expect(second.strokeCount == 1 && second.objectCount == 1)
        #expect(second.strokes[0].id != stroke.id)
        #expect(approximately(second.strokes[0].points[0].location, stroke.points[0].location))
        #expect(second.objects[0].bounds == object.bounds)
        // The copies are selected, ready to move.
        #expect(other.selection == PageSelection(strokeIDs: [second.strokes[0].id], objectIDs: [second.objects[0].id]))
        #expect(controller.hasSelection)

        other.undo() // the paste is one step
        #expect(second.strokeCount == 0 && second.objectCount == 0)
    }

    @Test func pastingBesideTheOriginalsStepsAlongEachTime() {
        let (stroke, _) = selectInkAndObject()
        controller.copySelection()
        controller.paste()
        controller.paste()
        #expect(first.strokeCount == 3)
        #expect(approximately(first.strokes[1].points[0].location, stroke.points[0].location + CGPoint(x: 24, y: 24)))
        #expect(approximately(first.strokes[2].points[0].location, stroke.points[0].location + CGPoint(x: 48, y: 48)))
    }

    @Test func cutThenPasteOnTheSamePagePutsItBack() {
        let (stroke, object) = selectInkAndObject()
        controller.cutSelection()
        #expect(first.strokeCount == 0 && first.objectCount == 0)
        #expect(!controller.hasSelection)
        controller.paste()
        #expect(approximately(first.strokes[0].points[0].location, stroke.points[0].location))
        #expect(first.objects[0].bounds == object.bounds)
    }

    @Test func duplicateCopiesBesideTheSelectionAndSelectsTheCopies() {
        let (stroke, object) = selectInkAndObject()
        controller.duplicateSelection()
        #expect(first.strokeCount == 2 && first.objectCount == 2)
        #expect(approximately(first.strokes[1].points[0].location, stroke.points[0].location + CGPoint(x: 24, y: 24)))
        #expect(first.objects[1].bounds == object.bounds.offsetBy(dx: 24, dy: 24))
        #expect(canvas.selection.strokeIDs == [first.strokes[1].id])
        #expect(!pasteboard.contains(pasteboardTypes: [SelectionClip.pasteboardType])) // the pasteboard is untouched
        canvas.undo()
        #expect(first.strokeCount == 1 && first.objectCount == 1)
    }

    @Test func recolouringAndThickeningTheSelectionAreUndoneStepByStep() throws {
        let (stroke, object) = selectInkAndObject()
        let blue = PenColor(rgb: 0x2563EB)
        controller.recolorSelection(blue)
        #expect(first.strokes[0].color == blue.rgba)
        #expect((first.objects[0] as? PlaceholderObject)?.color == blue)
        let box = try #require(canvas.selectionBox)
        canvas.scaleSelectionThickness(by: CanvasView.thicknessStep)
        #expect(abs(first.strokes[0].brush.maxWidth - stroke.brush.maxWidth * CanvasView.thicknessStep) < 1e-6)
        #expect(try #require(canvas.selectionBox).rect.width > box.rect.width) // the box fits the thicker ink
        canvas.undo()
        #expect(first.strokes[0].brush == stroke.brush)
        canvas.undo()
        #expect(first.strokes[0] == stroke)
        #expect((first.objects[0] as? PlaceholderObject)?.color == object.color)
    }

    @Test func theFilterLimitsWhatTheLassoPicksUp() {
        let (stroke, object) = selectInkAndObject()
        canvas.clearSelection()
        controller.lassoMode = .square
        let region = [CGPoint(x: 20, y: 20), CGPoint(x: 600, y: 700)]

        controller.setLassoFilter(.objects, included: false)
        lasso(canvas, region)
        #expect(canvas.selection == PageSelection(strokeIDs: [stroke.id]))

        controller.setLassoFilter(.objects, included: true)
        controller.setLassoFilter(.ink, included: false)
        lasso(canvas, region)
        #expect(canvas.selection == PageSelection(objectIDs: [object.id]))
        // Taps follow the filter too.
        lasso(canvas, [stroke.points[0].location])
        #expect(canvas.selection.isEmpty)

        controller.setLassoFilter(.objects, included: false) // the last kind left stays on
        #expect(controller.lassoFilter == .objects)
    }

    @Test func theMenuOffersTheActionsAndTheAppsOwn() throws {
        var performed: LassoSelection?
        controller.selectionActions = [
            SelectionAction(id: "convert", title: "Convert to Text") { performed = $0 },
            SelectionAction(id: "never", title: "Never", isAvailable: { _ in false }, perform: { _ in })
        ]
        let (stroke, object) = selectInkAndObject()
        let titles = canvas.editMenuElements().flatMap { ($0 as? UIMenu)?.children ?? [$0] }.map(\.title)
        #expect(titles == ["Cut", "Copy", "Duplicate", "Delete", "Color", "Thickness", "Arrange", "Save as Sticker", "Add Link…",
                           "Take Screenshot", "Convert to Text"])

        let selection = try #require(canvas.lassoSelection)
        #expect(selection.pageID == first.id)
        #expect(selection.strokeCount == 1)
        #expect(selection.objects.map(\.id) == [object.id])
        #expect(selection.ink.strokes.map(\.id) == [stroke.id])
        let image = try #require(selection.image(scale: 1))
        #expect(image.width >= Int(object.bounds.maxX - stroke.points[0].location.x))
        controller.selectionActions[0].perform(selection)
        #expect(performed?.pageID == first.id)

        // Nothing selected and something to paste: a tap offers Paste alone.
        controller.copySelection()
        canvas.clearSelection()
        canvas.pendingPastePoint = CGPoint(x: 400, y: 400)
        #expect(canvas.editMenuElements().map(\.title) == ["Paste"])
    }

    @Test func aScreenshotShowsThePageUnderTheSelection() throws {
        _ = selectInkAndObject()
        let box = try #require(canvas.selectionBox)
        let image = try #require(canvas.screenshotImage(of: box))
        let region = LassoGeometry.bounds(of: box.corners)
        #expect(abs(image.size.width - region.width) <= 1)
        #expect(abs(image.size.height - region.height) <= 1)
    }

    @Test func bringingToFrontRedrawsAndIsOneStep() {
        let (stroke, _) = selectInkAndObject()
        let top = makeStroke(at: CGPoint(x: 102, y: 102))
        first.add(top)
        canvas.select(PageSelection(strokeIDs: [stroke.id]))
        canvas.arrangeSelection(.bringToFront)
        #expect(first.strokes.map(\.id) == [top.id, stroke.id])
        canvas.undo()
        #expect(first.strokes.map(\.id) == [stroke.id, top.id])
    }
}
