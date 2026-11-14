import CoreGraphics
import Foundation
@testable import InkKit
import Testing

/// A page can be on screen in several views at once (a note open in two windows). Every view showing it
/// must hear each change, whichever view made it.
@MainActor
@Suite("CanvasDocument observers")
struct CanvasDocumentObserverTests {
    /// Records what one observer was told.
    @MainActor
    final class Recorder {
        var changes: [CanvasDocument.Change] = []
        var resizes = 0

        func observe(_ doc: CanvasDocument) {
            doc.addObserver(self, onChange: { [unowned self] in changes.append($0) },
                            onPageSizeChange: { [unowned self] in resizes += 1 })
        }
    }

    @Test func everyObserverHearsEveryEdit() {
        let doc = CanvasDocument()
        let first = Recorder(), second = Recorder()
        first.observe(doc)
        second.observe(doc)

        doc.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        doc.undo()
        doc.redo()
        doc.clear()

        #expect(first.changes == [.edited, .edited, .edited, .edited])
        #expect(second.changes == first.changes)
    }

    @Test func everyObserverHearsResizes() {
        let doc = CanvasDocument()
        let first = Recorder(), second = Recorder()
        first.observe(doc)
        second.observe(doc)
        doc.pageSize = .a4
        #expect(first.resizes == 1)
        #expect(second.resizes == 1)
    }

    @Test func refinementsReportTheStrokeTheyReshaped() throws {
        let doc = CanvasDocument()
        let recorder = Recorder()
        recorder.observe(doc)
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        doc.add(stroke)
        #expect(doc.lastReshapedIDs.isEmpty)

        let updated = doc.updatePoint(strokeID: stroke.id, index: 0) { $0.force = 0.9 }

        #expect(updated)
        #expect(recorder.changes == [.edited, .refined])
        #expect(doc.lastReshapedIDs == [stroke.id])
        #expect(try #require(doc.strokes.first).points[0].force == 0.9)
    }

    @Test func transformsReportTheStrokesTheyMoved() {
        let doc = CanvasDocument()
        let stroke = makeStroke(at: CGPoint(x: 10, y: 10))
        doc.add(stroke)
        let session = doc.beginTransform(PageSelection(strokeIDs: [stroke.id]))
        doc.previewTransform(session, by: CGAffineTransform(translationX: 5, y: 0))
        doc.commitTransform(session, by: CGAffineTransform(translationX: 5, y: 0))
        #expect(doc.lastReshapedIDs == [stroke.id])

        // A later edit that moves nothing clears them, so another view doesn't redo work for them.
        doc.add(makeStroke(at: CGPoint(x: 50, y: 50)))
        #expect(doc.lastReshapedIDs.isEmpty)

        doc.undo() // the added stroke
        doc.undo() // the transform
        #expect(doc.lastReshapedIDs == [stroke.id])
    }

    @Test func releasedObserversAreDropped() {
        let doc = CanvasDocument()
        let kept = Recorder()
        kept.observe(doc)
        do {
            let released = Recorder()
            released.observe(doc)
            #expect(doc.observerCount == 2)
        }
        doc.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        #expect(doc.observerCount == 1)
        #expect(kept.changes == [.edited])
    }

    @Test func observingAgainReplacesTheHandlers() {
        let doc = CanvasDocument()
        let recorder = Recorder()
        recorder.observe(doc)
        recorder.observe(doc)
        #expect(doc.observerCount == 1)
        doc.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        #expect(recorder.changes == [.edited])

        doc.removeObserver(recorder)
        doc.undo()
        #expect(recorder.changes == [.edited])
        #expect(doc.observerCount == 0)
    }
}
