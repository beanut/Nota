import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@MainActor
@Suite("CanvasDocument page")
struct CanvasDocumentPageTests {
    @Test func defaultsToLetter() {
        let doc = CanvasDocument()
        #expect(doc.pageSize == .letter)
        #expect(doc.pageBounds == CGRect(x: 0, y: 0, width: 612, height: 792))
    }

    @Test func customSizeAndIdentity() {
        let size = PageSize.inches(width: 5, height: 7)
        let doc = CanvasDocument(pageSize: size)
        #expect(doc.pageSize == size)
        #expect(doc.id != CanvasDocument().id)
    }

    @Test func containsOnlyPointsOnThePage() {
        let doc = CanvasDocument(pageSize: PageSize(width: 100, height: 200))
        #expect(doc.contains(CGPoint(x: 0, y: 0)))
        #expect(doc.contains(CGPoint(x: 99, y: 199)))
        #expect(!doc.contains(CGPoint(x: -1, y: 10)))
        #expect(!doc.contains(CGPoint(x: 10, y: 200)))
        #expect(!doc.contains(CGPoint(x: 100, y: 10)))
    }

    @Test func resizingNotifiesOnlyOnRealChange() {
        let doc = CanvasDocument()
        var calls = 0
        let owner = NSObject()
        doc.addObserver(owner, onChange: { _ in }, onPageSizeChange: { calls += 1 })
        doc.pageSize = .letter
        #expect(calls == 0)
        doc.pageSize = .a4
        #expect(calls == 1)
        #expect(doc.pageBounds.size == PageSize.a4.size)
    }

    @Test func resizingKeepsInkAndUndoHistory() {
        let doc = CanvasDocument()
        doc.add(makeStroke(at: CGPoint(x: 600, y: 780)))
        doc.pageSize = .a5 // smaller: the stroke is now off the page but must survive
        #expect(doc.strokeCount == 1)
        #expect(doc.canUndo)
        doc.pageSize = .letter
        #expect(doc.strokes.first?.points.first?.location == CGPoint(x: 600, y: 780))
    }
}

@MainActor
@Suite("InkNotebook")
struct InkNotebookTests {
    @Test func startsWithOneLetterPage() {
        let notebook = InkNotebook()
        #expect(notebook.pageCount == 1)
        #expect(notebook.currentPageIndex == 0)
        #expect(notebook.currentPage.pageSize == .letter)
        #expect(notebook.defaultPageSize == .letter)
        #expect(!notebook.canRemovePage)
        #expect(!notebook.canGoToNextPage)
        #expect(!notebook.canGoToPreviousPage)
    }

    @Test func initWithPageCountAndSize() {
        let notebook = InkNotebook(pageSize: .a4, pageCount: 3)
        #expect(notebook.pageCount == 3)
        #expect(notebook.pages.allSatisfy { $0.pageSize == .a4 })
        #expect(Set(notebook.pages.map(\.id)).count == 3)
        #expect(InkNotebook(pageCount: 0).pageCount == 1)
        #expect(InkNotebook(pageCount: -4).pageCount == 1)
    }

    @Test func initWithExistingPages() {
        let pages = [CanvasDocument(pageSize: .a5), CanvasDocument()]
        let notebook = InkNotebook(pages: pages)
        #expect(notebook.pages.map(\.id) == pages.map(\.id))

        let empty = InkNotebook(pages: [], defaultPageSize: .legal)
        #expect(empty.pageCount == 1)
        #expect(empty.currentPage.pageSize == .legal)
    }

    @Test func addPageInsertsAfterCurrentAndShowsIt() {
        let notebook = InkNotebook(pageCount: 3)
        notebook.goToPage(1)
        let added = notebook.addPage()
        #expect(notebook.pageCount == 4)
        #expect(notebook.currentPageIndex == 2)
        #expect(notebook.currentPage === added)
    }

    @Test func addPageCopiesCurrentSizeUnlessGiven() {
        let notebook = InkNotebook(pageSize: .a4)
        #expect(notebook.addPage().pageSize == .a4)
        let custom = PageSize.inches(width: 4, height: 6)
        #expect(notebook.addPage(size: custom).pageSize == custom)
        // The next page follows the custom page it was added after.
        #expect(notebook.addPage().pageSize == custom)
    }

    @Test func insertPageAtFrontTakesSizeOfFollowingPage() {
        let notebook = InkNotebook(pageSize: .tabloid)
        let page = notebook.insertPage(at: 0)
        #expect(notebook.pages.first === page)
        #expect(page.pageSize == .tabloid)
        #expect(notebook.currentPageIndex == 0)
    }

    @Test func insertPageClampsIndex() {
        let notebook = InkNotebook(pageCount: 2)
        let end = notebook.insertPage(at: 99)
        #expect(notebook.pages.last === end)
        let start = notebook.insertPage(at: -5)
        #expect(notebook.pages.first === start)
    }

    @Test func insertExistingPageOnlyOnce() {
        let notebook = InkNotebook()
        let page = CanvasDocument(pageSize: .a3)
        notebook.insert(page, at: 1)
        notebook.insert(page, at: 0)
        #expect(notebook.pageCount == 2)
        #expect(notebook.index(of: page.id) == 1)
        #expect(notebook.currentPage === page)
    }

    @Test func navigationClamps() {
        let notebook = InkNotebook(pageCount: 3)
        notebook.goToPreviousPage()
        #expect(notebook.currentPageIndex == 0)
        notebook.goToNextPage()
        notebook.goToNextPage()
        notebook.goToNextPage()
        #expect(notebook.currentPageIndex == 2)
        #expect(!notebook.canGoToNextPage)
        #expect(notebook.canGoToPreviousPage)
        notebook.goToPage(-10)
        #expect(notebook.currentPageIndex == 0)
        notebook.goToPage(10)
        #expect(notebook.currentPageIndex == 2)
    }

    @Test func cannotRemoveLastPage() {
        let notebook = InkNotebook()
        #expect(notebook.removePage(at: 0) == nil)
        #expect(notebook.pageCount == 1)
    }

    @Test func removeOutOfRangeDoesNothing() {
        let notebook = InkNotebook(pageCount: 2)
        #expect(notebook.removePage(at: 5) == nil)
        #expect(notebook.removePage(at: -1) == nil)
        #expect(notebook.pageCount == 2)
    }

    @Test func removingPageBeforeCurrentKeepsCurrentPage() {
        let notebook = InkNotebook(pageCount: 3)
        notebook.goToPage(2)
        let current = notebook.currentPage
        notebook.removePage(at: 0)
        #expect(notebook.currentPage === current)
        #expect(notebook.currentPageIndex == 1)
    }

    @Test func removingPageAfterCurrentKeepsCurrentPage() {
        let notebook = InkNotebook(pageCount: 3)
        let current = notebook.currentPage
        notebook.removePage(at: 2)
        #expect(notebook.currentPage === current)
        #expect(notebook.currentPageIndex == 0)
    }

    @Test func removingCurrentPageShowsTheOneThatTookItsPlace() {
        let notebook = InkNotebook(pageCount: 3)
        notebook.goToPage(1)
        let next = notebook.pages[2]
        let removed = notebook.removePage(at: 1)
        #expect(removed != nil)
        #expect(notebook.currentPage === next)
    }

    @Test func removingCurrentLastPageShowsThePreviousOne() {
        let notebook = InkNotebook(pageCount: 3)
        notebook.goToPage(2)
        let previous = notebook.pages[1]
        notebook.removePage(at: 2)
        #expect(notebook.currentPageIndex == 1)
        #expect(notebook.currentPage === previous)
    }

    @Test func movePageKeepsCurrentPageCurrent() {
        let notebook = InkNotebook(pageCount: 4)
        let ids = notebook.pages.map(\.id)
        notebook.goToPage(1)
        notebook.movePage(from: 0, to: 3)
        #expect(notebook.pages.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(notebook.currentPage.id == ids[1])
        #expect(notebook.currentPageIndex == 0)

        notebook.movePage(from: 0, to: 99) // clamped to the end
        #expect(notebook.pages.last?.id == ids[1])
        #expect(notebook.currentPageIndex == 3)

        notebook.movePage(from: 9, to: 0) // invalid source: no change
        #expect(notebook.pages.last?.id == ids[1])
    }

    @Test func setPageSizeForOnePage() {
        let notebook = InkNotebook(pageCount: 2)
        notebook.setPageSize(.a4.landscape, forPageAt: 1)
        #expect(notebook.pages[0].pageSize == .letter)
        #expect(notebook.pages[1].pageSize == .a4.landscape)
        notebook.setPageSize(.a3, forPageAt: 7) // ignored
        #expect(notebook.pages.map(\.pageSize) == [.letter, .a4.landscape])
    }

    @Test func setPageSizeForAllPagesUpdatesDefault() {
        let notebook = InkNotebook(pageCount: 3)
        let size = PageSize.millimeters(width: 100, height: 150)
        notebook.setPageSizeForAllPages(size)
        #expect(notebook.pages.allSatisfy { $0.pageSize == size })
        #expect(notebook.defaultPageSize == size)
    }

    @Test func pagesKeepTheirOwnInk() {
        let notebook = InkNotebook(pageCount: 2)
        notebook.pages[0].add(makeStroke(at: CGPoint(x: 10, y: 10)))
        #expect(notebook.pages[0].strokeCount == 1)
        #expect(notebook.pages[1].strokeCount == 0)
        #expect(!notebook.pages[1].canUndo)
    }
}

func makeStroke(at point: CGPoint) -> Stroke {
    let style = BrushStyle(width: 4, minWidthRatio: 0.25, pressureGamma: 0.6, opacity: 1, tiltEnabled: false)
    let points = [point, CGPoint(x: point.x + 5, y: point.y + 5)].enumerated().map { i, p in
        StrokePoint(location: p, force: 0.5, altitude: .pi / 2, azimuth: 0, timestamp: Double(i))
    }
    return Stroke(id: UUID(), tool: .pen, color: RGBA.swatches[0], style: style, points: points)
}

@MainActor
@Suite("Notebook templates")
struct NotebookTemplateTests {
    @Test func newPagesTakeTheirNeighboursTemplate() {
        let notebook = InkNotebook(pageCount: 1, template: .preset(.cornell))
        notebook.addPage()
        #expect(notebook.currentPage.template == .preset(.cornell))
        notebook.setTemplate(.preset(.dots), forPageAt: 1)
        notebook.insertPage(at: 0)
        #expect(notebook.pages.map(\.template) == [.preset(.cornell), .preset(.cornell), .preset(.dots)])
    }

    @Test func templateChangesLeaveInkAndRevisionAlone() {
        let notebook = InkNotebook()
        let page = notebook.currentPage
        page.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        let revision = page.revision
        notebook.setTemplate(PageTemplate.preset(.wideRuled).on(.cream), forPageAt: 0)
        #expect(page.template == PageTemplate.preset(.wideRuled).on(.cream))
        #expect(page.revision == revision)
        #expect(page.strokeCount == 1)
        #expect(page.canUndo)
    }

    @Test func useForAllPagesSetsTheDefaultToo() {
        let notebook = InkNotebook(pageCount: 3)
        notebook.setTemplateForAllPages(.preset(.musicStaff))
        #expect(notebook.pages.allSatisfy { $0.template == .preset(.musicStaff) })
        #expect(notebook.defaultTemplate == .preset(.musicStaff))
    }

    @Test func artworkIsDroppedWithItsBackground() throws {
        let page = CanvasDocument()
        let pdf = try #require(PageRenderer.pdf(of: [page.snapshot()]) { .standard($0) })
        let artwork = try #require(TemplateArtwork(data: pdf))
        var custom = PageTemplate.blank
        custom.background = artwork.background
        page.setTemplate(custom, artwork: artwork)
        #expect(page.snapshot().templateArtwork === artwork)
        page.setTemplate(.preset(.dots), artwork: artwork)
        #expect(page.templateArtwork == nil)
    }

    @Test func templateChangesNotifyTheCanvasOnce() {
        let page = CanvasDocument()
        var calls = 0
        let owner = NSObject()
        page.addObserver(owner, onChange: { _ in }, onTemplateChange: { calls += 1 })
        page.setTemplate(.preset(.smallGrid), artwork: nil)
        #expect(calls == 1)
    }
}
