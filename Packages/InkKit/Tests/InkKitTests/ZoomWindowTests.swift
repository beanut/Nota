import CoreGraphics
@testable import InkKit
import Testing

@Suite("ZoomWindow")
struct ZoomWindowTests {
    /// US Letter with a rule every 30 pt from 90 pt, written between 30 and 582.
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    let lines = WritingLines(spacing: 30, firstBaseline: 90, left: 30, right: 582)
    let aspect: CGFloat = 4

    func window(box: CGRect? = nil) -> ZoomWindow {
        ZoomWindow(page: page, lines: lines, aspect: aspect, box: box)
    }

    /// The baseline's height inside the box, as a fraction from the top.
    func baselineFraction(_ w: ZoomWindow) -> CGFloat {
        (lines.baseline(w.line) - w.box.minY) / w.box.height
    }

    /// A stroke written at the box's right edge, up to `fraction` of the way across.
    func stroke(in w: ZoomWindow, to fraction: CGFloat) -> CGRect {
        CGRect(x: w.box.minX + w.box.width * (fraction - 0.1), y: w.box.midY - 5,
               width: w.box.width * 0.1, height: 10)
    }

    @Test func startsOnTheFirstLineAtTheLeftMargin() {
        let w = window()
        #expect(w.line == 0)
        #expect(w.box.minX == 30)
        #expect(abs(w.box.height - 45) < 0.001) // 1.5 lines
        #expect(abs(w.box.width / w.box.height - aspect) < 0.001)
        #expect(abs(baselineFraction(w) - ZoomWindow.baselineFraction) < 0.001)
        #expect(!w.canGoBack)
    }

    @Test func standardLinesFitThePage() {
        let standard = WritingLines.standard(for: CGSize(width: 612, height: 792))
        #expect(abs(standard.spacing - 612 / 19) < 0.001)
        #expect(standard.left == standard.spacing)
        #expect(standard.right == 612 - standard.spacing)
    }

    @Test func strokesShortOfTheAdvanceZoneLeaveTheBoxAlone() {
        var w = window()
        let before = w.box
        let move1 = w.strokeEnded(bounds: stroke(in: w, to: 0.6))
        #expect(move1 == .stayed)
        #expect(w.box == before)
    }

    @Test func strokeInTheAdvanceZoneMovesTheBoxOn() {
        var w = window()
        let ink = stroke(in: w, to: 0.9)
        let move1 = w.strokeEnded(bounds: ink)
        #expect(move1 == .advanced)
        // The stroke's end is now a quarter of the way in, on the same line.
        #expect(abs(w.box.minX - (ink.maxX - ZoomWindow.leadInFraction * w.box.width)) < 0.001)
        #expect(w.line == 0)
        #expect(w.canGoBack)
    }

    @Test func strokesOutsideTheBoxDontMoveIt() {
        var w = window()
        let before = w.box
        let elsewhere = CGRect(x: before.maxX - 10, y: before.maxY + 100, width: 20, height: 10)
        let move1 = w.strokeEnded(bounds: elsewhere)
        #expect(move1 == .stayed)
        #expect(w.box == before)
    }

    @Test func aFullLineIsWrittenWithoutMovingTheBoxByHand() {
        var w = window()
        var advances = 0
        // Keep writing into the advance zone until the box wraps.
        while w.strokeEnded(bounds: stroke(in: w, to: 0.85)) == .advanced {
            advances += 1
            #expect(w.box.maxX <= lines.right + 0.001)
            #expect(advances < 100)
        }
        #expect(advances > 2)
        #expect(w.line == 1)
        #expect(w.box.minX == lines.left)
        #expect(abs(baselineFraction(w) - ZoomWindow.baselineFraction) < 0.001)
    }

    @Test func theBoxStopsAtTheRightMarginBeforeWrapping() {
        var w = window(box: CGRect(x: 400, y: 0, width: 180, height: 45))
        let move1 = w.strokeEnded(bounds: stroke(in: w, to: 0.95))
        #expect(move1 == .advanced)
        #expect(w.box.maxX == lines.right)
        #expect(w.line == 0)
        let move2 = w.strokeEnded(bounds: stroke(in: w, to: 0.95))
        #expect(move2 == .newLine)
        #expect(w.line == 1)
    }

    @Test func noNewLineBelowTheLastOneOnThePage() {
        // The last baseline whose box still fits is the one at 780 (1.5-line box: 0.42 lines below).
        var w = window(box: CGRect(x: 30, y: 780 - 0.72 * 45, width: 180, height: 45))
        let line = w.line
        let move1 = w.newLine()
        #expect(!move1)
        #expect(w.line == line)
        #expect(w.box.maxY <= page.maxY)
    }

    @Test func backGoesAlongTheLineThenToTheEndOfTheLineAbove() {
        var w = window()
        let move1 = w.back()
        #expect(!move1)
        w.newLine()
        #expect(w.line == 1)
        let move2 = w.back()
        #expect(move2)
        #expect(w.line == 0)
        #expect(w.box.maxX == lines.right)
        let move3 = w.back()
        #expect(move3)
        #expect(w.line == 0)
        #expect(w.box.maxX < lines.right)
    }

    @Test func advanceButtonMovesOnThenWraps() {
        var w = window()
        let x = w.box.minX
        let move1 = w.advance()
        #expect(move1 == .advanced)
        #expect(abs(w.box.minX - (x + 0.75 * w.box.width)) < 0.001)
        while w.advance() == .advanced {}
        #expect(w.line == 1)
    }

    @Test func draggingSnapsToTheNearestLine() {
        var w = window()
        w.move(to: CGPoint(x: 200, y: 300))
        #expect(w.box.origin == CGPoint(x: 200, y: 300))
        w.snapToLine()
        #expect(w.box.minX == 200)
        #expect(abs(baselineFraction(w) - ZoomWindow.baselineFraction) < 0.001)
        #expect(w.line == lines.line(nearest: 300 + 0.72 * w.box.height))
    }

    @Test func draggingStaysOnThePage() {
        var w = window()
        w.move(to: CGPoint(x: -100, y: 2000))
        #expect(w.box.minX == 0)
        #expect(w.box.maxY == page.maxY)
    }

    @Test func resizingKeepsTheLineAndAspectWithinLimits() {
        var w = window()
        w.newLine()
        w.resize(toWidth: 300)
        #expect(w.box.width == 300)
        #expect(abs(w.box.width / w.box.height - aspect) < 0.001)
        #expect(w.line == 1)
        #expect(abs(baselineFraction(w) - ZoomWindow.baselineFraction) < 0.001)
        w.resize(toWidth: 10)
        #expect(w.box.width == w.widthRange.lowerBound) // one line tall
        #expect(abs(w.box.height - lines.spacing) < 0.001)
        w.resize(toWidth: 10000)
        #expect(w.box.width == w.widthRange.upperBound)
        #expect(w.box.width <= lines.right - lines.left)
    }

    @Test func refittingKeepsThePlace() {
        var w = window()
        w.newLine()
        w.advance()
        // The panel changed shape (a rotation): same left edge, width and line.
        let refit = ZoomWindow(page: page, lines: lines, aspect: 5, box: w.box)
        #expect(refit.box.minX == w.box.minX)
        #expect(refit.box.width == w.box.width)
        #expect(refit.line == w.line)
        #expect(abs(refit.box.width / refit.box.height - 5) < 0.001)
    }
}
