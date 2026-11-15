import Combine
import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("ContinuousPageLayout")
struct ContinuousPageLayoutTests {
    private let insets = ContinuousPageLayout.Insets(top: 20, side: 10, bottom: 30, gap: 8)

    @Test func fitsTheWidestPageToTheWidthAndStacksPagesWithGaps() {
        let layout = ContinuousPageLayout(pageSizes: [CGSize(width: 100, height: 200), CGSize(width: 200, height: 100)],
                                          width: 420, insets: insets)
        #expect(layout.scale == 2) // (420 - 2 × 10) / 200
        #expect(layout.frames == [
            CGRect(x: 110, y: 20, width: 200, height: 400), // narrower page centred
            CGRect(x: 10, y: 428, width: 400, height: 200)
        ])
        #expect(layout.contentSize == CGSize(width: 420, height: 20 + 400 + 8 + 200 + 30))
    }

    @Test func emptyOrTooNarrowGivesNoFrames() {
        #expect(ContinuousPageLayout(pageSizes: [], width: 400, insets: insets).frames.isEmpty)
        #expect(ContinuousPageLayout(pageSizes: [CGSize(width: 100, height: 100)], width: 15, insets: insets).frames.isEmpty)
    }

    @Test func findsThePagesInView() {
        // Pages 100 tall from y = 20, every 108.
        let layout = ContinuousPageLayout(pageSizes: Array(repeating: CGSize(width: 100, height: 100), count: 300),
                                          width: 120, insets: insets)
        #expect(layout.visiblePages(in: CGRect(x: 0, y: 0, width: 120, height: 50)) == 0 ..< 1)
        #expect(layout.visiblePages(in: CGRect(x: 0, y: 110, width: 120, height: 120)) == 0 ..< 2)
        // In the gap between pages 1 and 2, and ending in the next gap.
        #expect(layout.visiblePages(in: CGRect(x: 0, y: 230, width: 120, height: 100)) == 2 ..< 3)
        #expect(layout.visiblePages(in: CGRect(x: 0, y: 1_000_000, width: 120, height: 100)).isEmpty)
        #expect(layout.visiblePages(in: CGRect(x: 0, y: 0, width: 120, height: 0)).isEmpty)
    }

    @Test func theCurrentPageIsTheOneAtTheMiddleOrTheNearestToIt() {
        let layout = ContinuousPageLayout(pageSizes: Array(repeating: CGSize(width: 100, height: 100), count: 3),
                                          width: 120, insets: insets)
        // Page 1 spans 128–228, page 2 236–336.
        #expect(layout.currentPage(in: CGRect(x: 0, y: 130, width: 120, height: 100)) == 1) // middle 180
        #expect(layout.currentPage(in: CGRect(x: 0, y: 179, width: 120, height: 100)) == 1) // 229: just under page 1
        #expect(layout.currentPage(in: CGRect(x: 0, y: 185, width: 120, height: 100)) == 2) // 235: just above page 2
        #expect(layout.currentPage(in: CGRect(x: 0, y: -100, width: 120, height: 100)) == 0)
        #expect(layout.currentPage(in: CGRect(x: 0, y: 5000, width: 120, height: 100)) == 2)
        #expect(ContinuousPageLayout(pageSizes: [], width: 120).currentPage(in: .zero) == nil)
    }

    @Test func scrollsToAPageTopClampedToTheContent() {
        let layout = ContinuousPageLayout(pageSizes: Array(repeating: CGSize(width: 100, height: 100), count: 3),
                                          width: 120, insets: insets)
        #expect(layout.offset(showingPage: 0, viewportHeight: 100, topInset: 20) == 0)
        #expect(layout.offset(showingPage: 1, viewportHeight: 100, topInset: 20) == 108)
        // The last page can only scroll as far as the end of the content (366 - 100).
        #expect(layout.offset(showingPage: 2, viewportHeight: 100, topInset: 0) == 236)
        #expect(layout.offset(showingPage: 2, viewportHeight: 300, topInset: 0) == 66)
        #expect(layout.offset(showingPage: 7, viewportHeight: 100, topInset: 0) == 0)
    }

    @Test func aPageThatFitsTheOverscanIsRenderedWholeAndNeverMovesWhileScrolling() {
        let page = CGRect(x: 24, y: 24, width: 984, height: 1392)
        let window = ContinuousPageLayout.renderWindow(forPage: page, viewport: CGRect(x: 0, y: 0, width: 1032, height: 1376),
                                                       current: nil)
        #expect(window == page)
        for y in stride(from: -1400, through: 1400, by: 100) {
            let viewport = CGRect(x: 0, y: CGFloat(y), width: 1032, height: 1376)
            #expect(ContinuousPageLayout.renderWindow(forPage: page, viewport: viewport, current: window) == window)
        }
    }

    @Test func aZoomedPageGetsTheViewportPlusOverscanAndMovesOnlyNearItsEdge() {
        let page = CGRect(x: 0, y: 0, width: 4000, height: 6000)
        // 1000 × 1000 viewport: half a viewport above and below, a quarter to each side, centred on it.
        let window = ContinuousPageLayout.renderWindow(forPage: page, viewport: CGRect(x: 1000, y: 2000, width: 1000, height: 1000),
                                                       current: nil)
        #expect(window == CGRect(x: 750, y: 1500, width: 1500, height: 2000))
        // Still a quarter viewport of rendered ink below the view: stays put.
        #expect(ContinuousPageLayout.renderWindow(forPage: page, viewport: CGRect(x: 1000, y: 2200, width: 1000, height: 1000),
                                                  current: window) == window)
        // Closer than that: centres on the view again.
        #expect(ContinuousPageLayout.renderWindow(forPage: page, viewport: CGRect(x: 1000, y: 2400, width: 1000, height: 1000),
                                                  current: window) == CGRect(x: 750, y: 1900, width: 1500, height: 2000))
    }

    @Test func theRenderWindowStaysOnItsPage() {
        let page = CGRect(x: 0, y: 3000, width: 4000, height: 6000)
        // A page below the view, given its canvas early: the window starts at its top.
        #expect(ContinuousPageLayout.renderWindow(forPage: page, viewport: CGRect(x: 1000, y: 0, width: 1000, height: 1000),
                                                  current: nil) == CGRect(x: 750, y: 3000, width: 1500, height: 2000))
        // At the page's bottom-right corner.
        #expect(ContinuousPageLayout.renderWindow(forPage: page, viewport: CGRect(x: 3500, y: 8800, width: 1000, height: 1000),
                                                  current: nil) == CGRect(x: 2500, y: 7000, width: 1500, height: 2000))
    }

    @Test func midPinchTheRenderWindowKeepsItsSize() {
        let current = CGRect(x: 750, y: 1500, width: 1500, height: 2000)
        let page = CGRect(x: 0, y: 0, width: 1200, height: 1600) // zoomed out until the page is smaller
        let viewport = CGRect(x: 100, y: 300, width: 1000, height: 1000)
        #expect(ContinuousPageLayout.renderWindow(forPage: page, viewport: viewport, current: current) == page)
        #expect(ContinuousPageLayout.renderWindow(forPage: page, viewport: viewport, current: current, keepingSize: true)
            == CGRect(x: -150, y: -200, width: 1500, height: 2000))
    }

    @Test func laysOutAndFindsPagesOfALongNoteQuickly() {
        let sizes = Array(repeating: PageSize.letter.size, count: 300)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for step in 0 ..< 100 {
                let layout = ContinuousPageLayout(pageSizes: sizes, width: 1024)
                let viewport = CGRect(x: 0, y: CGFloat(step) * 3000, width: 1024, height: 1366)
                _ = layout.visiblePages(in: viewport)
                _ = layout.currentPage(in: viewport)
            }
        }
        // 100 relayouts of 300 pages: well under a frame each, even on a slow simulator.
        #expect(elapsed < .milliseconds(200))
    }

    @Test func layoutModeIsSavedAndDefaultsToContinuous() throws {
        let defaults = try #require(UserDefaults(suiteName: "ContinuousPageLayoutTests-\(UUID().uuidString)"))
        #expect(PageLayoutMode.load(from: defaults) == .continuous)
        PageLayoutMode.paged.save(to: defaults)
        #expect(PageLayoutMode.load(from: defaults) == .paged)
        defaults.set("sideways", forKey: PageLayoutMode.defaultsKey)
        #expect(PageLayoutMode.load(from: defaults) == .continuous)
    }
}

@MainActor
@Suite("Page sidebar operations")
struct PageOperationsTests {
    private func stroke(through points: [CGPoint], azimuth: CGFloat = 0) -> Stroke {
        Stroke(id: UUID(), color: RGBA.swatches[0], brush: .pen,
               points: points.enumerated().map { i, p in
                   StrokePoint(location: p, force: 0.5, altitude: .pi / 2, azimuth: azimuth, timestamp: Double(i))
               })
    }

    private func notebook(_ count: Int) -> (InkNotebook, [UUID]) {
        let notebook = InkNotebook(pageCount: count)
        return (notebook, notebook.pages.map(\.id))
    }

    @Test func copyingAPageKeepsItsInkAndLooksButNotItsIdentityOrHistory() {
        let page = CanvasDocument(pageSize: .a5, template: .preset(.dots))
        page.add(stroke(through: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)]))
        page.addObject(PlaceholderObject(frame: CGRect(x: 5, y: 5, width: 30, height: 20), color: PenColor(rgb: 0x2563EB)))
        let copy = page.copy()
        #expect(copy.id != page.id)
        #expect(copy.pageSize == .a5)
        #expect(copy.template == .preset(.dots))
        #expect(copy.strokes == page.strokes)
        #expect(copy.objectCount == 1)
        #expect(!copy.canUndo)
        // Independent from then on.
        copy.clear()
        #expect(page.strokeCount == 1)
        #expect(page.objectCount == 1)
    }

    @Test func rotatingTurnsTheInkWithThePage() {
        let page = CanvasDocument(pageSize: PageSize(width: 100, height: 200))
        page.add(stroke(through: [CGPoint(x: 10, y: 20)], azimuth: 0))
        page.addObject(PlaceholderObject(frame: CGRect(x: 10, y: 20, width: 30, height: 40), color: PenColor(rgb: 0x2563EB)))
        let before = page.revision
        let objectsBefore = page.objectsRevision
        var sizeChanges = 0, edits = 0
        let owner = NSObject()
        page.addObserver(owner, onChange: { _ in edits += 1 }, onPageSizeChange: { sizeChanges += 1 })

        page.rotate()
        #expect(page.pageSize.size == CGSize(width: 200, height: 100))
        #expect(page.strokes[0].points[0].location == CGPoint(x: 180, y: 10)) // (height − y, x)
        #expect(abs(page.strokes[0].points[0].azimuth - .pi / 2) < 1e-9)
        #expect(page.objects[0].bounds == CGRect(x: 140, y: 10, width: 40, height: 30))
        #expect(page.revision > before)
        #expect(page.objectsRevision > objectsBefore)
        #expect(!page.canUndo) // history described the old orientation
        #expect(page.lastReshapedIDs == Set(page.strokes.map(\.id)))
        #expect(sizeChanges == 1 && edits == 1)

        page.rotate(clockwise: false)
        #expect(page.pageSize.size == CGSize(width: 100, height: 200))
        #expect(page.strokes[0].points[0].location == CGPoint(x: 10, y: 20))
        #expect(page.objects[0].bounds.integral == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @Test func movingSeveralPagesKeepsTheirOrderAndTheCurrentPage() {
        let (notebook, ids) = notebook(5)
        notebook.goToPage(2)
        notebook.movePages(fromOffsets: [0, 3], toOffset: 5)
        #expect(notebook.pages.map(\.id) == [ids[1], ids[2], ids[4], ids[0], ids[3]])
        #expect(notebook.currentPage.id == ids[2])
        notebook.movePages(fromOffsets: [4], toOffset: 0)
        #expect(notebook.pages.map(\.id).first == ids[3])
        #expect(notebook.currentPage.id == ids[2])
    }

    @Test func duplicatingPutsEachCopyAfterItsPage() {
        let (notebook, ids) = notebook(3)
        notebook.pages[2].add(stroke(through: [CGPoint(x: 5, y: 5)]))
        notebook.goToPage(1)
        let copies = notebook.duplicatePages(at: [0, 2])
        #expect(copies.count == 2)
        #expect(notebook.pages.map(\.id) == [ids[0], copies[0].id, ids[1], ids[2], copies[1].id])
        #expect(copies[1].strokeCount == 1)
        #expect(notebook.currentPage.id == ids[1])
    }

    @Test func removingPagesKeepsAtLeastOne() {
        let (notebook, ids) = notebook(4)
        notebook.goToPage(3)
        #expect(!notebook.canRemovePages(at: [0, 1, 2, 3]))
        #expect(notebook.removePages(at: [0, 1, 2, 3]).isEmpty)
        #expect(notebook.pageCount == 4)

        let removed = notebook.removePages(at: [1, 3])
        #expect(removed.map(\.id) == [ids[1], ids[3]])
        #expect(notebook.pages.map(\.id) == [ids[0], ids[2]])
        // The current page went; the one that took its place (the last) is shown.
        #expect(notebook.currentPageIndex == 1)
    }

    @Test func removingPagesBeforeTheCurrentOneKeepsItCurrent() {
        let (notebook, ids) = notebook(4)
        notebook.goToPage(2)
        notebook.removePages(at: [0, 1])
        #expect(notebook.currentPage.id == ids[2])
    }

    @Test func rotatingPagesTurnsOnlyThoseAndAnnouncesIt() {
        let notebook = InkNotebook(pageSize: .letter, pageCount: 3)
        var announcements = 0
        let observation = notebook.objectWillChange.sink { announcements += 1 }
        notebook.rotatePages(at: [1])
        #expect(notebook.pages.map(\.pageSize.isLandscape) == [false, true, false])
        #expect(announcements == 1)
        observation.cancel()
    }

    @Test func appendingPagesLeavesTheCurrentPageAndSkipsPagesAlreadyThere() {
        let (notebook, ids) = notebook(2)
        let incoming = [CanvasDocument(), CanvasDocument()]
        notebook.appendPages(incoming + [notebook.pages[0]])
        #expect(notebook.pages.map(\.id) == ids + incoming.map(\.id))
        #expect(notebook.currentPageIndex == 0)
    }

    @Test func writingNearTheBottomOfTheLastPageAddsOne() {
        let notebook = InkNotebook(pageSize: PageSize(width: 100, height: 100), pageCount: 2,
                                   template: .preset(.dots))
        let first = notebook.pages[0], last = notebook.pages[1]
        // Not the last page, or not far enough down: nothing.
        #expect(notebook.addPageIfWritingReachedEnd(of: first, inkBounds: CGRect(x: 0, y: 90, width: 10, height: 9)) == nil)
        #expect(notebook.addPageIfWritingReachedEnd(of: last, inkBounds: CGRect(x: 0, y: 10, width: 10, height: 70)) == nil)
        #expect(notebook.addPageIfWritingReachedEnd(of: last, inkBounds: .null) == nil)

        let added = notebook.addPageIfWritingReachedEnd(of: last, inkBounds: CGRect(x: 0, y: 80, width: 10, height: 6))
        #expect(added != nil)
        #expect(notebook.pageCount == 3)
        #expect(notebook.pages.last?.template == .preset(.dots))
        #expect(notebook.pages.last?.pageSize == last.pageSize)
        #expect(notebook.currentPageIndex == 0) // still writing where you were
        // The old last page isn't last any more.
        #expect(notebook.addPageIfWritingReachedEnd(of: last, inkBounds: CGRect(x: 0, y: 95, width: 1, height: 1)) == nil)
    }
}
