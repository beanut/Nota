import CoreGraphics
import Foundation
@testable import InkKit
import Testing

/// A horizontal stroke from (0, y) to (length, y), one point every 10 units.
private func line(_ kind: InkKind = .pen, y: CGFloat = 50, length: CGFloat = 100) -> Stroke {
    let style = BrushStyle(width: 4, minWidthRatio: 1, pressureGamma: 1, opacity: 1, tiltEnabled: false)
    let points = stride(from: CGFloat(0), through: length, by: 10).enumerated().map { i, x in
        StrokePoint(location: CGPoint(x: x, y: y), force: 1, altitude: .pi / 2, azimuth: 0, timestamp: Double(i))
    }
    return Stroke(id: UUID(), tool: kind, color: RGBA.swatches[0], style: style, points: points)
}

@Suite("Eraser targets")
struct EraserTargetTests {
    @Test func allInkErasesEveryInkButNotPixelErasers() {
        #expect(EraserTarget.all.erases(.pen))
        #expect(EraserTarget.all.erases(.pencil))
        #expect(EraserTarget.all.erases(.highlighter))
        #expect(!EraserTarget.all.erases(.pixelEraser))
    }

    @Test func highlighterOnlyLeavesHandwritingAlone() {
        #expect(EraserTarget.highlighter.erases(.highlighter))
        #expect(!EraserTarget.highlighter.erases(.pen))
        #expect(!EraserTarget.highlighter.erases(.pencil))
        #expect(!EraserTarget.highlighter.erases(.pixelEraser))
    }

    @Test func pencilOnlyLeavesPenAndHighlighterAlone() {
        #expect(EraserTarget.pencil.erases(.pencil))
        #expect(!EraserTarget.pencil.erases(.pen))
        #expect(!EraserTarget.pencil.erases(.highlighter))
    }

    @Test func onlyPrecisionCantTarget() {
        #expect(!EraserMode.precision.canTarget)
        #expect(EraserMode.standard.canTarget)
        #expect(EraserMode.stroke.canTarget)
    }
}

@Suite("Standard erase")
struct StandardEraseTests {
    @Test func cuttingThroughTheMiddleLeavesTwoPieces() throws {
        let stroke = line()
        let pieces = try #require(StrokeSplitter.remainder(of: stroke, erasedFrom: CGPoint(x: 50, y: 0),
                                                           to: CGPoint(x: 50, y: 100), radius: 8))
        #expect(pieces.count == 2)
        let left = try #require(pieces.first?.points.map(\.location.x))
        let right = try #require(pieces.last?.points.map(\.location.x))
        #expect(left.first == 0)
        #expect(try #require(left.last) < 42)
        #expect(try #require(right.first) > 58)
        #expect(right.last == 100)
        for piece in pieces {
            #expect(piece.id != stroke.id)
            #expect(piece.tool == stroke.tool)
            #expect(piece.style == stroke.style)
            #expect(piece.createdAt == stroke.createdAt)
        }
    }

    @Test func erasingAnEndShortensTheStroke() throws {
        let pieces = try #require(StrokeSplitter.remainder(of: line(), erasedFrom: CGPoint(x: 100, y: 0),
                                                           to: CGPoint(x: 100, y: 100), radius: 15))
        #expect(pieces.count == 1)
        #expect(try #require(pieces[0].points.last?.location.x) < 86)
        #expect(pieces[0].points.first?.location.x == 0)
    }

    @Test func missingTheCentreLineLeavesTheStrokeAlone() {
        #expect(StrokeSplitter.remainder(of: line(), erasedFrom: CGPoint(x: 0, y: 70),
                                         to: CGPoint(x: 100, y: 70), radius: 8) == nil)
    }

    @Test func erasingAllOfItLeavesNothing() {
        #expect(StrokeSplitter.remainder(of: line(), erasedFrom: CGPoint(x: 0, y: 50),
                                         to: CGPoint(x: 100, y: 50), radius: 8) == [])
    }

    @Test func aDotIsErasedWhole() {
        var dot = line()
        dot.points = [dot.points[0]]
        #expect(StrokeSplitter.remainder(of: dot, erasedFrom: .zero, to: CGPoint(x: 0, y: 60), radius: 4) == [])
        #expect(StrokeSplitter.remainder(of: dot, erasedFrom: CGPoint(x: 30, y: 0), to: CGPoint(x: 30, y: 100),
                                         radius: 4) == nil)
    }
}

@MainActor
@Suite("Standard erase undo")
struct StandardEraseUndoTests {
    /// Highlighting over handwriting: the done-when of NOT-25.
    @Test func erasingHighlighterOverHandwritingIsOneUndoableStep() throws {
        let doc = CanvasDocument()
        let writing = line(.pen), highlight = line(.highlighter, y: 52)
        doc.add(writing)
        doc.add(highlight)
        let before = doc.strokes

        for stroke in doc.strokes where EraserTarget.highlighter.erases(stroke.tool) {
            let pieces = try #require(StrokeSplitter.remainder(of: stroke, erasedFrom: CGPoint(x: 0, y: 52),
                                                               to: CGPoint(x: 100, y: 52), radius: 10))
            doc.replace(id: stroke.id, with: pieces)
        }
        doc.recordReplace(before: before)
        #expect(doc.strokes == [writing])

        #expect(doc.undo())
        #expect(doc.strokes == [writing, highlight])
        #expect(doc.redo())
        #expect(doc.strokes == [writing])
    }

    @Test func piecesKeepTheStrokesPlaceInTheStack() throws {
        let doc = CanvasDocument()
        let below = line(y: 10), cut = line(y: 50), above = line(y: 90)
        for s in [below, cut, above] {
            doc.add(s)
        }
        let before = doc.strokes
        let pieces = try #require(StrokeSplitter.remainder(of: cut, erasedFrom: CGPoint(x: 50, y: 0),
                                                           to: CGPoint(x: 50, y: 100), radius: 2))
        doc.replace(id: cut.id, with: pieces)
        doc.recordReplace(before: before)
        #expect(doc.strokes.map(\.id) == [below.id] + pieces.map(\.id) + [above.id])
    }

    @Test func anEraseThatChangedNothingIsntRecorded() {
        let doc = CanvasDocument()
        doc.add(line())
        doc.recordReplace(before: doc.strokes)
        #expect(doc.undo())
        #expect(doc.strokes.isEmpty)
        #expect(!doc.canUndo) // only the add was on the stack
    }
}

@MainActor
@Suite("Eraser switch-back")
struct EraserSwitchBackTests {
    @Test func switchesBackToThePreviousToolWhenOn() {
        let controller = CanvasController()
        controller.select(.highlighter)
        controller.select(.eraser)
        controller.switchBackAfterErasing = true
        controller.eraserStrokeDidEnd()
        #expect(controller.tool == .highlighter)
    }

    @Test func staysOnTheEraserWhenOff() {
        let controller = CanvasController()
        controller.select(.eraser)
        controller.eraserStrokeDidEnd()
        #expect(controller.tool == .eraser)
    }

    @Test func precisionAlwaysErasesAllInk() {
        let controller = CanvasController()
        controller.eraserTarget = .highlighter
        controller.eraserMode = .precision
        #expect(controller.effectiveEraserTarget == .all)
        controller.eraserMode = .standard
        #expect(controller.effectiveEraserTarget == .highlighter)
    }
}
