import CoreGraphics
import Foundation
@testable import InkKit
import PDFKit
import Testing

private func roundTrip(_ objects: [any PageObject]) throws -> [any PageObject] {
    try PageObjectsFile(data: PageObjectsFile(pageID: UUID(), objects: objects).encoded()).objects
}

private let box = CGRect(x: 100, y: 200, width: 120, height: 30)

/// A URL for a test address that's known to parse.
private func web(_ address: String) -> URL {
    URL(string: address) ?? URL(fileURLWithPath: "/")
}

@MainActor
@Suite("Links: targets, file format and editing")
struct LinkObjectTests {
    @Test func everyKindOfTargetRoundTrips() throws {
        let page = UUID(), note = UUID(), notePage = UUID()
        let targets: [LinkTarget] = [.url(web("https://example.com/a?b=c")), .page(page),
                                     .note(note, page: nil), .note(note, page: notePage)]
        let links = targets.enumerated().map { i, target in
            LinkObject(frame: box, zIndex: i, target: target, title: "Link \(i)", color: PenColor(rgb: 0x12786B))
        }
        let read = try roundTrip(links).compactMap { $0 as? LinkObject }
        #expect(read == links)
    }

    @Test func targetsAreWrittenAsSmallObjects() throws {
        let page = UUID(), note = UUID()
        let json = try #require(String(data: PageObjectsFile(pageID: UUID(), objects: [
            LinkObject(frame: box, target: .page(page)),
            LinkObject(frame: box, target: .note(note, page: nil)),
            LinkObject(frame: box, target: .url(web("https://example.com")))
        ]).encoded(), encoding: .utf8))
        #expect(json.contains("\"kind\" : \"link\""))
        #expect(json.contains("\"page\" : \"\(page.uuidString)\""))
        #expect(json.contains("\"note\" : \"\(note.uuidString)\""))
        #expect(json.contains("\"url\" : \"https://example.com\""))
    }

    @Test func aTargetFromANewerAppIsKeptAsItWasRead() throws {
        let json = """
        { "formatVersion": 1, "pageID": "\(UUID())", "objects": [ { "kind": "link", "id": "\(UUID())",
          "frame": { "x": 0, "y": 0, "width": 50, "height": 20 }, "target": { "heading": "Chapter 2" } } ] }
        """
        let link = try #require(PageObjectsFile(data: Data(json.utf8)).objects.first as? LinkObject)
        #expect(link.target == nil)
        #expect(link.color == LinkObject.defaultColor)
        let written = try #require(String(data: PageObjectsFile(pageID: UUID(), objects: [link]).encoded(), encoding: .utf8))
        #expect(written.contains("\"heading\" : \"Chapter 2\""))
    }

    @Test func webAddressesAreTidiedUp() {
        #expect(LinkTarget.web("example.com") == .url(web("https://example.com")))
        #expect(LinkTarget.web("  http://example.com/x  ") == .url(web("http://example.com/x")))
        #expect(LinkTarget.web("mailto:me@example.com") == .url(web("mailto:me@example.com")))
        #expect(LinkTarget.web("") == nil)
        #expect(LinkTarget.web("not a link") == nil)
        #expect(LinkTarget.web("hello") == nil)
        #expect(LinkTarget.web("javascript:alert(1)") == nil)
        #expect(LinkTarget.web("file:///etc/hosts") == nil)
    }

    @Test func addingAndRetargetingALinkAreUndoable() {
        let doc = CanvasDocument()
        let first = UUID(), second = UUID()
        let link = doc.addLink(to: .page(first), covering: box, title: "Page 2")
        #expect(link.frame == box.insetBy(dx: -LinkObject.padding, dy: -LinkObject.padding))
        #expect(doc.link(at: CGPoint(x: 160, y: 215))?.id == link.id)
        #expect(doc.link(at: CGPoint(x: 400, y: 400)) == nil)

        doc.setLinkTarget(id: link.id, to: .page(second), title: "Page 3")
        #expect(doc.links.first?.target == .page(second))
        #expect(doc.links.first?.title == "Page 3")
        doc.undo()
        #expect(doc.links.first?.target == .page(first))
        doc.undo()
        #expect(doc.links.isEmpty)
    }

    @Test func aLinkMovesWithWhatItCovers() {
        let doc = CanvasDocument()
        let link = doc.addLink(to: .page(UUID()), covering: box)
        doc.transform(PageSelection(objectIDs: [link.id]), by: CGAffineTransform(translationX: 0, y: 100))
        #expect(doc.link(at: CGPoint(x: 160, y: 315)) != nil)
        #expect(doc.link(at: CGPoint(x: 160, y: 215)) == nil)
    }
}

// MARK: - Outline and bookmarks

@MainActor
@Suite("Outline and bookmarks")
struct NoteOutlineTests {
    @Test func bookmarksToggleAndListInPageOrder() {
        let notebook = InkNotebook(pageCount: 4)
        let ids = notebook.pages.map(\.id)
        notebook.toggleBookmark(ids[3])
        notebook.toggleBookmark(ids[1])
        #expect(notebook.isBookmarked(ids[3]))
        #expect(notebook.outline.bookmarkedPages(in: ids).map(\.pageIndex) == [1, 3])
        notebook.toggleBookmark(ids[3])
        #expect(!notebook.isBookmarked(ids[3]))
        notebook.toggleBookmark(UUID()) // not a page here: ignored
        #expect(notebook.outline.bookmarks == [ids[1]])
    }

    @Test func entriesAreAddedRenamedReorderedAndRemoved() throws {
        let notebook = InkNotebook(pageCount: 3)
        let ids = notebook.pages.map(\.id)
        let intro = try #require(notebook.addOutlineEntry(title: "  Introduction ", pageID: ids[0]))
        let blank = try #require(notebook.addOutlineEntry(title: "", pageID: ids[2]))
        #expect(intro.title == "Introduction")
        #expect(blank.title == "Page 3")
        #expect(notebook.addOutlineEntry(title: "Gone", pageID: UUID()) == nil)

        notebook.renameOutlineEntry(blank.id, to: "Summary")
        notebook.renameOutlineEntry(intro.id, to: "   ") // blank names are ignored
        #expect(notebook.outline.entries.map(\.title) == ["Introduction", "Summary"])

        notebook.moveCustomOutlineEntries(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(notebook.outline.entries.map(\.title) == ["Summary", "Introduction"])

        notebook.removeOutlineEntry(blank.id)
        #expect(notebook.outline.entries.map(\.title) == ["Introduction"])
    }

    @Test func reorderingLeavesPDFEntriesInPlace() {
        let a = UUID(), b = UUID()
        let notebook = InkNotebook()
        notebook.outline = NoteOutline(entries: [
            .init(title: "One", pageID: a), .init(title: "PDF", pageID: a, source: .pdf), .init(title: "Two", pageID: b)
        ])
        notebook.moveCustomOutlineEntries(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(notebook.outline.entries.map(\.title) == ["Two", "PDF", "One"])
    }

    @Test func entriesForDeletedPagesDropOut() {
        let notebook = InkNotebook(pageCount: 3)
        let ids = notebook.pages.map(\.id)
        notebook.toggleBookmark(ids[1])
        notebook.addOutlineEntry(title: "Middle", pageID: ids[1])
        notebook.addOutlineEntry(title: "End", pageID: ids[2])
        notebook.removePage(at: 1)
        let pages = notebook.pages.map(\.id)
        #expect(notebook.outline.bookmarkedPages(in: pages).isEmpty)
        #expect(notebook.outline.resolved(notebook.outline.customEntries, in: pages).map(\.value.title) == ["End"])
        #expect(notebook.outline.resolved(notebook.outline.customEntries, in: pages).first?.pageIndex == 1)
        let pruned = notebook.outline.pruned(keeping: pages)
        #expect(pruned.bookmarks.isEmpty)
        #expect(pruned.entries.map(\.title) == ["End"])
    }

    @Test func remappingFollowsCopiedPages() {
        let old = UUID(), new = UUID(), dropped = UUID()
        let outline = NoteOutline(bookmarks: [old, dropped],
                                  entries: [.init(title: "A", pageID: old, level: 1, source: .pdf),
                                            .init(title: "B", pageID: dropped)])
        let copy = outline.remapped([old: new])
        #expect(copy.bookmarks == [new])
        #expect(copy.entries.count == 1)
        #expect(copy.entries[0].pageID == new)
        #expect(copy.entries[0].level == 1)
        #expect(copy.entries[0].source == .pdf)
        #expect(copy.entries[0].id != outline.entries[0].id)
    }

    @Test func theOutlineRoundTripsAndReadsLeniently() throws {
        let page = UUID()
        let outline = NoteOutline(bookmarks: [page, page],
                                  entries: [.init(title: "Chapter", pageID: page, level: 2, source: .pdf)])
        #expect(outline.bookmarks == [page]) // no duplicates
        let read = try JSONDecoder().decode(NoteOutline.self, from: JSONEncoder().encode(outline))
        #expect(read == outline)

        let json = """
        { "entries": [ { "id": "\(UUID())", "page": "\(page)", "source": "heading", "level": -3 } ] }
        """
        let lenient = try JSONDecoder().decode(NoteOutline.self, from: Data(json.utf8))
        #expect(lenient.bookmarks.isEmpty)
        #expect(lenient.entries.first?.source == .custom)
        #expect(lenient.entries.first?.level == 0)
        #expect(lenient.entries.first?.title == "")
    }

    @Test func aPDFsOutlineBecomesNestedEntries() {
        let pdf = PDFDocument()
        for i in 0 ..< 3 {
            pdf.insert(PDFPage(), at: i)
        }
        let root = PDFOutline()
        func item(_ label: String, page: Int) -> PDFOutline {
            let outline = PDFOutline()
            outline.label = label
            outline.destination = PDFDestination(page: pdf.page(at: page)!, at: .zero)
            return outline
        }
        let chapter = item("Chapter 1", page: 0)
        chapter.insertChild(item("Section 1.1", page: 1), at: 0)
        root.insertChild(chapter, at: 0)
        let heading = PDFOutline() // no destination: its child moves up a level
        heading.label = "Appendices"
        heading.insertChild(item("Appendix", page: 2), at: 0)
        root.insertChild(heading, at: 1)
        pdf.outlineRoot = root

        let notebook = InkNotebook(pageCount: 3)
        let ids = notebook.pages.map(\.id)
        notebook.addOutlineEntry(title: "Mine", pageID: ids[0])
        notebook.importPDFOutline(from: pdf, pageIDs: ids)
        let entries = notebook.outline.pdfEntries
        #expect(entries.map(\.title) == ["Chapter 1", "Section 1.1", "Appendix"])
        #expect(entries.map(\.level) == [0, 1, 0])
        #expect(entries.map(\.pageID) == [ids[0], ids[1], ids[2]])
        #expect(notebook.outline.customEntries.map(\.title) == ["Mine"])

        // Importing again replaces the PDF's entries, not the user's.
        notebook.importPDFOutline(from: pdf, pageIDs: Array(ids.prefix(1)))
        #expect(notebook.outline.pdfEntries.map(\.title) == ["Chapter 1"])
        #expect(notebook.outline.customEntries.count == 1)
    }

    @Test func historySkipsPagesThatAreGone() {
        var history = LinkHistory()
        let a = UUID(), b = UUID(), c = UUID()
        history.push(a)
        history.push(b)
        history.push(c)
        let exists: (UUID) -> Bool = { $0 != c }
        #expect(history.peek(where: exists) == b)
        #expect(history.pop(where: exists) == b)
        #expect(history.pop(where: exists) == a)
        #expect(history.pop(where: exists) == nil)
        #expect(history.isEmpty)

        for _ in 0 ..< LinkHistory.limit + 5 {
            history.push(UUID())
        }
        #expect(history.pageIDs.count == LinkHistory.limit)
    }
}

// MARK: - On the canvas

@MainActor
@Suite("Links on the canvas")
struct CanvasLinkTests {
    let controller: CanvasController
    let document = CanvasDocument(pageSize: .letter)
    let canvas: CanvasView

    init() throws {
        controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: "CanvasLinkTests.\(UUID())")),
                                          penTray: PenTrayStore(fileURL: nil),
                                          stickers: StickerStore(folderURL: FileManager.default.temporaryDirectory
                                              .appending(path: UUID().uuidString)),
                                          pasteboard: .withUniqueName(), presentation: InkPresentation())
        canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
    }

    private func tap(at p: CGPoint) -> LiveStroke {
        let live = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA(r: 0, g: 0, b: 0), brush: .pen, points: []))
        _ = live.append(StrokePoint(location: p, force: 0.5, altitude: .pi / 2, azimuth: 0, timestamp: 0), minSpacing: 0)
        return live
    }

    @Test func aPenTapOnALinkFollowsIt() {
        let target = LinkTarget.page(UUID())
        document.addLink(to: target, covering: box)
        canvas.refreshObjects()
        var followed: [(LinkTarget, UUID)] = []
        controller.onFollowLink = { followed.append(($0, $1)) }
        controller.select(.pen)
        #expect(canvas.tapObjectIfTapped(tap(at: CGPoint(x: 150, y: 215))))
        #expect(followed.count == 1)
        #expect(followed.first?.0 == target)
        #expect(followed.first?.1 == document.id)

        // Off the link, a tap is a dot.
        #expect(!canvas.tapObjectIfTapped(tap(at: CGPoint(x: 500, y: 600))))
        // The text tool's taps are its own, and the lasso selects links.
        #expect(!Tool.text.followsLinks)
        #expect(!Tool.lasso.followsLinks)
        #expect(followed.count == 1)
    }

    @Test func tapeOverALinkIsRevealedBeforeTheLinkIsFollowed() {
        document.addLink(to: .page(UUID()), covering: box)
        let tape = TapeObject(from: CGPoint(x: 90, y: 215), to: CGPoint(x: 240, y: 215), color: PenColor(rgb: 0xE8D7A9))
        document.addObject(tape)
        canvas.refreshObjects()
        var followed = 0
        controller.onFollowLink = { _, _ in followed += 1 }
        controller.select(.pen)
        #expect(canvas.tapObjectIfTapped(tap(at: CGPoint(x: 150, y: 215))))
        #expect(document.tapes.first?.isRevealed == true)
        #expect(followed == 0)
    }

    @Test func addLinkPutsALinkOverTheSelectionInTheThemesColour() throws {
        let text = TextObject(origin: CGPoint(x: 100, y: 100), width: 200, text: RichText("Chapter 2"))
        document.addObject(text)
        controller.theme.link = InkColor(name: "Teal", hex: 0x12786B)
        controller.select(.lasso)
        canvas.select(PageSelection(objectIDs: [text.id]))
        let titles = canvas.linkMenuElements().compactMap { ($0 as? UIAction)?.title }
        #expect(titles == ["Add Link…"])

        canvas.requestLink(editing: nil)
        let request = try #require(controller.linkRequest)
        #expect(request.linkID == nil)
        let destination = UUID()
        controller.applyLink(.page(destination), title: "Page 2")
        #expect(controller.linkRequest == nil)
        let link = try #require(document.links.first)
        #expect(link.target == .page(destination))
        #expect(link.color == PenColor(rgb: 0x12786B))
        #expect(link.bounds.contains(text.bounds))

        // Selected, a link offers Open, Edit and Remove.
        canvas.select(PageSelection(objectIDs: [link.id]))
        let linkTitles = canvas.linkMenuElements().compactMap { ($0 as? UIAction)?.title }
        #expect(linkTitles == ["Open Link", "Edit Link…", "Remove Link"])
        canvas.requestLink(editing: link)
        #expect(controller.linkRequest?.linkID == link.id)
        controller.applyLink(.url(web("https://example.com")), title: "example.com")
        #expect(document.links.first?.target == .url(web("https://example.com")))

        canvas.select(PageSelection(objectIDs: [link.id]))
        canvas.removeSelectedLinks()
        #expect(document.links.isEmpty)
        #expect(document.objects.count == 1) // the text it covered stays
        document.undo()
        #expect(document.links.count == 1)
    }
}
