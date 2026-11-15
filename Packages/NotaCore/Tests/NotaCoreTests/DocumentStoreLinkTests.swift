import CoreGraphics
import Foundation
import InkKit
@testable import NotaCore
import Testing

/// Links, bookmarks and the outline in note packages, and following links between notes (NOT-31): a
/// table-of-contents page links to pages of its own note and of another note, and those links, bookmarks and
/// outline entries are read back after a relaunch.
@Suite("DocumentStore links and outline")
@MainActor
struct DocumentStoreLinkTests {
    private let library = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    @Test func aContentsPageLinkingToThisAndAnotherNoteSurvivesAReopen() async {
        let documents = DocumentStore(library: library)
        let course = Note(title: "Course")
        let lab = Note(title: "Lab")
        documents.create(course, size: .letter, template: .blank)
        documents.create(lab, size: .letter, template: .blank)
        let notebook = await documents.notebook(for: course)
        notebook.addPage()
        notebook.addPage()
        let labPages = documents.pageIDs(of: lab)
        #expect(labPages.count == 1)

        let contents = notebook.pages[0]
        contents.addLink(to: .page(notebook.pages[2].id), covering: CGRect(x: 72, y: 100, width: 200, height: 24),
                         title: "Page 3")
        contents.addLink(to: .note(lab.id, page: labPages[0]), covering: CGRect(x: 72, y: 140, width: 200, height: 24),
                         title: "Lab, page 1")
        notebook.toggleBookmark(notebook.pages[2].id)
        notebook.addOutlineEntry(title: "Results", pageID: notebook.pages[2].id)
        documents.save(course)
        await documents.flush()

        let reopened = await DocumentStore(library: library).notebook(for: course)
        let links = reopened.pages[0].links
        #expect(links.map(\.target) == [.page(notebook.pages[2].id), .note(lab.id, page: labPages[0])])
        #expect(links.map(\.title) == ["Page 3", "Lab, page 1"])
        #expect(reopened.isBookmarked(notebook.pages[2].id))
        #expect(reopened.outline.entries.map(\.title) == ["Results"])
        #expect(reopened.outline.entries.first?.pageID == notebook.pages[2].id)
    }

    @Test func bookmarkingAloneIsSavedAndPrunedWithItsPage() async throws {
        let documents = DocumentStore(library: library, autosaveDelay: .milliseconds(10))
        let note = Note(title: "Bookmarks")
        documents.create(note, size: .letter, template: .blank)
        let notebook = await documents.notebook(for: note)
        notebook.addPage()
        let second = notebook.pages[1].id
        documents.save(note)
        await documents.flush()

        // A bookmark is a change of its own: the autosave picks it up.
        notebook.toggleBookmark(second)
        try await Task.sleep(for: .milliseconds(200))
        await documents.flush()
        let manifest = try #require(NoteManifest.read(from: NotePackage.manifestURL(for: note.id, in: library)))
        #expect(manifest.outline?.bookmarks == [second])

        // Deleting the page drops its bookmark from the file.
        notebook.removePage(at: 1)
        documents.save(note)
        await documents.flush()
        let pruned = try #require(NoteManifest.read(from: NotePackage.manifestURL(for: note.id, in: library)))
        #expect(pruned.outline == nil)
        #expect(try !String(decoding: pruned.encoded(), as: UTF8.self).contains("outline"))
    }

    @Test func aDuplicateKeepsItsOutlineOnItsOwnPages() async {
        let documents = DocumentStore(library: library)
        let note = Note(title: "Original")
        documents.create(note, size: .letter, template: .blank)
        let notebook = await documents.notebook(for: note)
        notebook.toggleBookmark(notebook.pages[0].id)
        notebook.addOutlineEntry(title: "Start", pageID: notebook.pages[0].id)
        let copy = Note(title: "Copy")
        documents.duplicate(note, as: copy)
        await documents.flush()

        let copied = await DocumentStore(library: library).notebook(for: copy)
        let page = copied.pages[0].id
        #expect(page != notebook.pages[0].id)
        #expect(copied.outline.bookmarks == [page])
        #expect(copied.outline.entries.map(\.pageID) == [page])
        #expect(copied.outline.entries.map(\.title) == ["Start"])
    }

    @Test func followingALinkToAPageOpensTheNoteThere() async {
        let documents = DocumentStore(library: library)
        let note = Note(title: "Target")
        documents.create(note, size: .letter, template: .blank)
        let notebook = await documents.notebook(for: note)
        notebook.addPage()
        notebook.addPage()
        let pages = notebook.pages.map(\.id)
        documents.save(note)
        await documents.flush()

        // Loaded: it turns to the page at once.
        documents.showPage(pages[1], ofNote: note.id)
        #expect(notebook.currentPageIndex == 1)

        // Not loaded yet: it opens on that page.
        let fresh = DocumentStore(library: library)
        #expect(fresh.pageIDs(of: note) == pages)
        fresh.showPage(pages[2], ofNote: note.id)
        #expect(await fresh.notebook(for: note).currentPageIndex == 2)

        // A page the note doesn't have is ignored.
        let other = DocumentStore(library: library)
        other.showPage(UUID(), ofNote: note.id)
        #expect(await other.notebook(for: note).currentPageIndex == 0)
    }
}

@Suite("Link trail")
struct LinkTrailTests {
    private let a = UUID(), b = UUID(), c = UUID(), page = UUID()

    @Test func backReturnsAlongTheWayLinksLed() {
        var trail = LinkTrail()
        trail.follow(from: a, page: page, to: b)
        trail.follow(from: b, page: nil, to: c)
        trail.follow(from: c, page: nil, to: c) // a link to itself isn't a step
        #expect(trail.steps.count == 2)
        #expect(trail.back(from: a) == nil)
        #expect(trail.back(from: c)?.fromNote == b)
        #expect(trail.goBack(from: c)?.fromNote == b)
        let step = trail.goBack(from: b)
        #expect(step?.fromNote == a)
        #expect(step?.fromPage == page)
        #expect(trail.steps.isEmpty)
    }

    @Test func stepsBackCanNoLongerReachAreForgotten() {
        var trail = LinkTrail()
        trail.follow(from: a, page: nil, to: b)
        trail.follow(from: b, page: nil, to: c)
        // Only c is open: the whole chain back from it stays.
        trail.keepSteps(reachableFrom: [c])
        #expect(trail.steps.count == 2)
        // c is closed: nothing is reachable.
        trail.keepSteps(reachableFrom: [UUID()])
        #expect(trail.steps.isEmpty)
    }

    @Test func aLinkOpensTheNoteInTheSameSideOfASplit() {
        var workspace = NoteWorkspace(noteIDs: [a, b])
        workspace.replace(b, with: c)
        #expect(workspace.noteIDs == [a, c])
        workspace.replace(c, with: a) // already open beside it: nothing changes
        #expect(workspace.noteIDs == [a, c])
        var single = NoteWorkspace(noteIDs: [a])
        single.replace(a, with: b)
        #expect(single.noteIDs == [b])
        var none = NoteWorkspace()
        none.replace(a, with: b)
        #expect(none.noteIDs == [b])
    }
}
