import CoreGraphics
import Foundation
import ImageIO
@_spi(Testing) import InkKit
@testable import NotaCore
import os
import SwiftData
import Testing

/// Every test gets its own library folder. "Relaunching" is a fresh `DocumentStore` on the same folder.
@Suite("DocumentStore")
@MainActor
struct DocumentStoreTests {
    private let library = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    private func relaunch() -> DocumentStore {
        DocumentStore(library: library)
    }

    private func draw(on page: CanvasDocument, at x: CGFloat = 20) {
        page.drawTestStroke(through: [CGPoint(x: x, y: 20), CGPoint(x: x + 30, y: 60), CGPoint(x: x + 60, y: 40)])
    }

    private func packageFiles(of note: Note) -> [String] {
        let enumerator = FileManager.default.enumerator(at: NotePackage.url(for: note.id, in: library),
                                                        includingPropertiesForKeys: nil, options: [])
        return (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent)
    }

    // MARK: Layout

    @Test func newNoteMirrorsItsManifest() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test", pageCount: 5)
        store.create(note, size: .a4, template: .preset(.dots))
        #expect(note.pageCount == 1)
        #expect(note.template == .preset(.dots))
        let page = await store.notebook(for: note).pages.first
        #expect(page?.pageSize == .a4)
        #expect(page?.template == .preset(.dots))
    }

    @Test func savingAddedPagesUpdatesThePageCount() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .preset(.dots))
        let notebook = await store.notebook(for: note)
        notebook.addPage()
        store.save(note)
        #expect(note.pageCount == 2)
        await store.flush()

        let reopened = await relaunch().notebook(for: note)
        #expect(reopened.pageCount == 2)
        #expect(reopened.pages.map(\.id) == notebook.pages.map(\.id))
        #expect(reopened.pages.map(\.template) == [.preset(.dots), .preset(.dots)])
    }

    @Test func pagesAddedFromAnotherNoteAreSavedWithTheirInk() async {
        let store = DocumentStore(library: library)
        let source = Note(title: "Source"), target = Note(title: "Target")
        store.create(source, size: .a5, template: .preset(.dots))
        store.create(target, size: .letter, template: .preset(.collegeRuled))
        let sourceNotebook = await store.notebook(for: source)
        draw(on: sourceNotebook.pages[0])
        await store.flush()

        // The target isn't open in an editor: it's loaded, given the pages and saved.
        let copies = sourceNotebook.pages.map { $0.copy() }
        await store.addPages(copies, to: target)
        #expect(target.pageCount == 2)
        await store.flush()

        let reopened = await relaunch().notebook(for: target)
        #expect(reopened.pageCount == 2)
        #expect(reopened.pages[1].id == copies[0].id)
        #expect(reopened.pages[1].pageSize == .a5)
        #expect(reopened.pages[1].template == .preset(.dots))
        #expect(reopened.pages[1].strokeCount == 1)
        // The source keeps its page: moving is the editor taking it out afterwards.
        #expect(sourceNotebook.pageCount == 1)
    }

    @Test func templateChangedInTheEditorIsSavedPerPage() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .preset(.collegeRuled))
        let notebook = await store.notebook(for: note)
        notebook.addPage()
        notebook.setTemplate(PageTemplate.preset(.monthlyPlanner).on(.cream), forPageAt: 1)
        store.save(note)
        await store.flush()

        let reopened = await relaunch().notebook(for: note)
        #expect(reopened.pages.map(\.template) == [.preset(.collegeRuled), PageTemplate.preset(.monthlyPlanner).on(.cream)])
    }

    @Test func settingTheTemplateFromTheLibraryUpdatesAnOpenNotebook() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .preset(.collegeRuled))
        let notebook = await store.notebook(for: note)
        notebook.addPage()
        store.setTemplate(.preset(.isometric), of: note)
        #expect(notebook.pages.allSatisfy { $0.template == .preset(.isometric) })
        #expect(note.template == .preset(.isometric))
        store.save(note)
        await store.flush()
        #expect(await relaunch().notebook(for: note).pages.allSatisfy { $0.template == .preset(.isometric) })
    }

    @Test func customBackgroundIsStoredInThePackageAndReloaded() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .blank)
        let artwork = try #require(try TemplateArtwork(data: makePNG()))
        var template = PageTemplate.blank
        template.background = artwork.background
        await store.notebook(for: note).setTemplate(template, artwork: artwork, forPageAt: 0)
        store.save(note)
        await store.flush()

        let file = NotePackage.templateURL(for: artwork.background, noteID: note.id, in: library)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let page = try #require(await relaunch().notebook(for: note).pages.first)
        #expect(page.template.background == artwork.background)
        #expect(page.templateArtwork?.id == artwork.id)
        #expect(page.templateArtwork?.data == artwork.data)

        // Back on a built-in: the file goes.
        store.setTemplate(.preset(.dots), of: note)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Ink

    /// NOT-6's "draw, force-quit, relaunch": ink, page count and page order are intact.
    @Test func inkPageCountAndOrderSurviveARelaunch() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Lecture")
        store.create(note, size: .letter, template: .noteDefault)
        let notebook = await store.notebook(for: note)
        draw(on: notebook.pages[0])
        notebook.addPage()
        notebook.addPage()
        draw(on: notebook.pages[2], at: 80)
        draw(on: notebook.pages[2], at: 140)
        notebook.movePage(from: 2, to: 0)
        store.saveAll()
        await store.flush()

        let reopened = await relaunch().notebook(for: note)
        #expect(reopened.pages.map(\.id) == notebook.pages.map(\.id))
        #expect(reopened.pages.map(\.strokeCount) == [2, 1, 0])
        #expect(reopened.pages.map { $0.inkFile.encoded() } == notebook.pages.map { $0.inkFile.encoded() })
        // Pages without ink have no file.
        #expect(packageFiles(of: note).filter { $0.hasSuffix(".ink") }.count == 2)
    }

    @Test func erasingEverythingIsSavedToo() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.notebook(for: note).pages[0]
        draw(on: page)
        store.save(note)
        page.undoForTesting()
        store.save(note)
        await store.flush()
        #expect(await relaunch().notebook(for: note).pages[0].strokeCount == 0)
    }

    @Test func autosavesOnceTheNoteIsQuiet() async throws {
        let store = DocumentStore(library: library, autosaveDelay: .milliseconds(50))
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.beginEditing(note)
        let url = NotePackage.pageURL(for: page.pages[0].id, noteID: note.id, in: library)
        draw(on: page.pages[0])
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await store.flush()
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await relaunch().notebook(for: note).pages[0].strokeCount == 1)
    }

    @Test func onlyChangedPagesAreRewritten() async {
        let writes = StepLog()
        let store = DocumentStore(library: library, files: PackageFiles { writes.record($0) })
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let notebook = await store.notebook(for: note)
        notebook.addPage()
        draw(on: notebook.pages[0])
        draw(on: notebook.pages[1])
        store.save(note)
        await store.flush()

        writes.reset()
        draw(on: notebook.pages[1], at: 100)
        store.save(note)
        await store.flush()
        let pageWrites = writes.steps.compactMap { step -> String? in
            guard case let .replace(url) = step, url.pathExtension == "ink" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        #expect(pageWrites == [notebook.pages[1].id.uuidString])

        // Nothing changed: nothing written.
        writes.reset()
        store.save(note)
        await store.flush()
        #expect(writes.steps.isEmpty)
    }

    @Test func titleIsKeptInTheManifest() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Before")
        store.create(note, size: .letter, template: .noteDefault)
        _ = await store.beginEditing(note)
        note.title = "After"
        store.endEditing(note)
        await store.flush()
        let manifest = try #require(NoteManifest.read(from: NotePackage.manifestURL(for: note.id, in: library)))
        #expect(manifest.title == "After")
        #expect(manifest.formatVersion == NoteManifest.currentFormatVersion)
    }

    // MARK: Crash safety

    /// The state a note is saved in, then the edit whose save gets cut short.
    private func prepareInterruptedSave(_ store: DocumentStore, note: Note) async -> (old: NoteState, new: NoteState) {
        store.create(note, size: .letter, template: .noteDefault)
        let notebook = await store.notebook(for: note)
        draw(on: notebook.pages[0])
        notebook.addPage()
        draw(on: notebook.pages[1])
        store.save(note)
        await store.flush()
        let old = NoteState(notebook)

        draw(on: notebook.pages[0], at: 120)
        _ = notebook.removePage(at: 1)
        notebook.addPage()
        draw(on: notebook.pages[1], at: 60)
        notebook.addPage()
        notebook.movePage(from: 2, to: 0)
        return (old, NoteState(notebook))
    }

    /// NOT-6's "killing the app during a save never leaves an unreadable note": stops the save at every
    /// step in turn and relaunches. The note always opens, in its old layout or its new one, and each page
    /// holds the ink it had before or after the save.
    @Test func aSaveCutShortAtAnyStepLeavesAReadableNote() async {
        // How many steps a full save takes.
        let log = StepLog()
        let probe = DocumentStore(library: library, files: PackageFiles { log.record($0) })
        let probeNote = Note(title: "Probe")
        _ = await prepareInterruptedSave(probe, note: probeNote)
        log.reset()
        probe.save(probeNote)
        await probe.flush()
        let stepCount = log.steps.count
        #expect(stepCount >= 5)

        for failingStep in 0 ..< stepCount {
            let library = library.appending(path: "kill-\(failingStep)", directoryHint: .isDirectory)
            let killSwitch = KillSwitch()
            let store = DocumentStore(library: library, files: PackageFiles { try killSwitch.step($0) })
            let note = Note(title: "Test")
            let (old, new) = await prepareInterruptedSave(store, note: note)
            killSwitch.arm(failingAt: failingStep)
            store.save(note)
            await store.flush()
            #expect(killSwitch.fired, "step \(failingStep)")

            let reopened = await NoteState(DocumentStore(library: library).notebook(for: note))
            #expect(reopened.pageIDs == old.pageIDs || reopened.pageIDs == new.pageIDs, "step \(failingStep)")
            for (id, ink) in reopened.ink {
                #expect(ink == old.ink[id] || ink == new.ink[id],
                        "step \(failingStep), page \(id)")
            }
        }
    }

    @Test func theSaveAfterAFailedOneWritesEverything() async {
        let killSwitch = KillSwitch()
        let store = DocumentStore(library: library, files: PackageFiles { try killSwitch.step($0) })
        let note = Note(title: "Test")
        let (_, new) = await prepareInterruptedSave(store, note: note)
        killSwitch.arm(failingAt: 0)
        store.save(note)
        await store.flush()
        #expect(killSwitch.fired)

        // No further edit, but the failed save is redone in full.
        store.save(note)
        await store.flush()
        let reopened = await NoteState(relaunch().notebook(for: note))
        #expect(reopened == new)
    }

    @Test func leftoversOfAKilledSaveAreCleanedUp() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let notebook = await store.notebook(for: note)
        draw(on: notebook.pages[0])
        store.save(note)
        await store.flush()

        let pages = NotePackage.pagesURL(for: note.id, in: library)
        let torn = pages.appending(path: ".\(UUID().uuidString).ink.\(UUID().uuidString)\(PackageFiles.temporarySuffix)")
        let orphan = NotePackage.pageURL(for: UUID(), noteID: note.id, in: library)
        try Data([1, 2, 3]).write(to: torn)
        try Data([4, 5, 6]).write(to: orphan)

        draw(on: notebook.pages[0], at: 90)
        store.save(note)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: torn.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(await relaunch().notebook(for: note).pages[0].strokeCount == 2)
    }

    @Test func anUnreadablePageIsSetAsideNotOverwritten() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let notebook = await store.notebook(for: note)
        notebook.addPage()
        draw(on: notebook.pages[0])
        draw(on: notebook.pages[1])
        store.save(note)
        await store.flush()

        let damaged = NotePackage.pageURL(for: notebook.pages[0].id, noteID: note.id, in: library)
        try Data("not ink".utf8).write(to: damaged)
        let reopenedStore = relaunch()
        let reopened = await reopenedStore.notebook(for: note)
        #expect(reopened.pageCount == 2)
        #expect(reopened.pages.map(\.strokeCount) == [0, 1])
        #expect(!FileManager.default.fileExists(atPath: damaged.path))
        #expect(packageFiles(of: note).contains { $0.hasPrefix(damaged.lastPathComponent + ".damaged-") })

        // Drawing on the page again writes a fresh file and keeps the damaged one.
        draw(on: reopened.pages[0])
        reopenedStore.save(note)
        await reopenedStore.flush()
        #expect(await relaunch().notebook(for: note).pages[0].strokeCount == 1)
        #expect(packageFiles(of: note).contains { $0.hasPrefix(damaged.lastPathComponent + ".damaged-") })
    }

    // MARK: Objects

    private func objectsURL(of page: CanvasDocument, in note: Note) -> URL {
        NotePackage.objectsURL(for: page.id, noteID: note.id, in: library)
    }

    @Test func objectsAreMovedResizedRotatedUndoneAndPersistedAlongsideInk() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.notebook(for: note).pages[0]
        draw(on: page)
        let object = page.addTestObject(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        let move = CGAffineTransform(translationX: 40, y: 10)
        let resize = CGAffineTransform(scaleX: 1.5, y: 0.75)
        let rotate = CGAffineTransform(rotationAngle: .pi / 8)
        page.transformForTesting(objectIDs: [object.id], by: move)
        page.transformForTesting(objectIDs: [object.id], by: resize)
        page.transformForTesting(objectIDs: [object.id], includingInk: true, by: rotate)
        page.undoForTesting() // the rotation
        page.undoForTesting() // the resize
        page.redoForTesting()
        let placed = move.concatenating(resize)
        #expect(page.object(id: object.id)?.transform == placed)
        store.save(note)
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: objectsURL(of: page, in: note).path))

        let reopened = try #require(await relaunch().notebook(for: note).pages.first)
        #expect(reopened.strokeCount == 1)
        #expect(reopened.inkFile.encoded() == page.inkFile.encoded())
        let loaded = try #require(reopened.object(id: object.id) as? PlaceholderObject)
        #expect(loaded.frame == object.frame)
        #expect(loaded.transform == placed)
        #expect(loaded.color == object.color)
        #expect(try reopened.objectsFile.encoded() == page.objectsFile.encoded())
    }

    @Test func removingTheLastObjectRemovesItsFile() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.notebook(for: note).pages[0]
        page.addTestObject(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        store.save(note)
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: objectsURL(of: page, in: note).path))

        page.undoForTesting()
        store.save(note)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: objectsURL(of: page, in: note).path))
        #expect(await relaunch().notebook(for: note).pages[0].objectCount == 0)
    }

    @Test func inkOnlyNotesHaveNoObjectsFiles() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.notebook(for: note).pages[0]
        draw(on: page)
        store.save(note)
        await store.flush()
        // Exactly the files a note had before objects existed, so older notes and older apps are unaffected.
        #expect(packageFiles(of: note).filter { $0.hasSuffix(".json") } == ["manifest.json"])
        let reopened = await relaunch().notebook(for: note).pages[0]
        #expect(reopened.objectCount == 0)
        #expect(reopened.strokeCount == 1)
    }

    @Test func changingOnlyObjectsRewritesOnlyTheObjectsFile() async {
        let writes = StepLog()
        let store = DocumentStore(library: library, files: PackageFiles { writes.record($0) })
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.notebook(for: note).pages[0]
        draw(on: page)
        let object = page.addTestObject(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        store.save(note)
        await store.flush()

        writes.reset()
        page.transformForTesting(objectIDs: [object.id], by: CGAffineTransform(translationX: 10, y: 0))
        store.save(note)
        await store.flush()
        let replaced = writes.steps.compactMap { step -> String? in
            guard case let .replace(url) = step else { return nil }
            return url.lastPathComponent
        }
        #expect(replaced == ["\(page.id.uuidString).json", "manifest.json"])
    }

    @Test func anUnreadableObjectsFileIsSetAsideNotOverwritten() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.notebook(for: note).pages[0]
        draw(on: page)
        page.addTestObject(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        store.save(note)
        await store.flush()

        let damaged = objectsURL(of: page, in: note)
        try Data(#"{"formatVersion": 99, "objects": []}"#.utf8).write(to: damaged) // from a much newer app
        let reopenedStore = relaunch()
        let reopened = await reopenedStore.notebook(for: note).pages[0]
        #expect(reopened.objectCount == 0)
        #expect(reopened.strokeCount == 1) // the ink still opens
        #expect(packageFiles(of: note).contains { $0.hasPrefix(damaged.lastPathComponent + ".damaged-") })

        reopened.addTestObject(frame: CGRect(x: 10, y: 10, width: 5, height: 5))
        reopenedStore.save(note)
        await reopenedStore.flush()
        #expect(await relaunch().notebook(for: note).pages[0].objectCount == 1)
        #expect(packageFiles(of: note).contains { $0.hasPrefix(damaged.lastPathComponent + ".damaged-") })
    }

    @Test func removedPagesTakeTheirObjectsFileWithThem() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let notebook = await store.notebook(for: note)
        let second = notebook.addPage()
        second.addTestObject(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        store.save(note)
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: objectsURL(of: second, in: note).path))

        notebook.removePage(at: 1)
        store.save(note)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: objectsURL(of: second, in: note).path))
    }

    @Test func duplicateCopiesObjects() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        let page = await store.notebook(for: note).pages[0]
        let object = page.addTestObject(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let copy = Note(title: "Copy")
        store.duplicate(note, as: copy)
        await store.flush()
        let copied = try #require(await relaunch().notebook(for: copy).pages.first)
        #expect(copied.object(id: object.id) != nil)
        #expect(copied.objectsFile.pageID == copied.id)
    }

    // MARK: Library changes

    @Test func duplicateCopiesInkAndCustomBackgrounds() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .blank)
        let artwork = try #require(try TemplateArtwork(data: makePNG()))
        var template = PageTemplate.blank
        template.background = artwork.background
        let notebook = await store.notebook(for: note)
        notebook.setTemplate(template, artwork: artwork, forPageAt: 0)
        draw(on: notebook.pages[0])

        // Not saved yet: duplicating saves the original first.
        let copy = Note(title: "Copy")
        store.duplicate(note, as: copy)
        await store.flush()
        let file = NotePackage.templateURL(for: artwork.background, noteID: copy.id, in: library)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let copied = await relaunch().notebook(for: copy)
        #expect(copied.pages[0].strokeCount == 1)
        #expect(copied.pages[0].id != notebook.pages[0].id)
        #expect(copied.pages[0].templateArtwork?.data == artwork.data)
    }

    @Test func discardRemovesThePackageEvenWithASavePending() async {
        let store = DocumentStore(library: library)
        let note = Note(title: "Test")
        store.create(note, size: .letter, template: .noteDefault)
        await draw(on: store.notebook(for: note).pages[0])
        store.save(note)
        store.discard(noteID: note.id)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: NotePackage.url(for: note.id, in: library).path))
        #expect(!store.isLoaded(note.id))
    }

    @Test func dropsTheLeastRecentlyUsedNoteNoEditorShows() async {
        let store = DocumentStore(library: library, capacity: 1)
        let first = Note(title: "First"), second = Note(title: "Second"), third = Note(title: "Third")
        for note in [first, second, third] {
            store.create(note, size: .letter, template: .noteDefault)
        }
        let editing = await store.beginEditing(first)
        draw(on: editing.pages[0])
        await draw(on: store.notebook(for: second).pages[0])
        // The first is being edited, so it stays; the second is the most recent.
        #expect(store.isLoaded(first.id) && store.isLoaded(second.id))

        _ = await store.notebook(for: third)
        #expect(store.isLoaded(first.id) && !store.isLoaded(second.id) && store.isLoaded(third.id))
        store.endEditing(first)
        #expect(!store.isLoaded(first.id))

        // Dropped notes were saved, and load again with their ink.
        #expect(await store.notebook(for: second).pages[0].strokeCount == 1)
        #expect(await store.notebook(for: first).pages[0].strokeCount == 1)
    }

    // MARK: Library index

    @Test func theIndexCanBeRebuiltFromPackages() async throws {
        let store = DocumentStore(library: library)
        let note = Note(title: "Lecture 7")
        store.create(note, size: .letter, template: .preset(.dots))
        let notebook = await store.notebook(for: note)
        notebook.addPage()
        draw(on: notebook.pages[1])
        store.save(note)
        await store.flush()

        // The SwiftData store is gone; the packages aren't.
        let context = try makeContext()
        let added = await relaunch().rebuildIndex(in: context)
        #expect(added.count == 1)
        let rebuilt = try #require(context.note(withID: note.id))
        #expect(rebuilt.title == "Lecture 7")
        #expect(rebuilt.pageCount == 2)
        #expect(rebuilt.template == .preset(.dots))
        #expect(abs(rebuilt.modifiedAt.timeIntervalSince(note.modifiedAt)) < 1)

        // Run again, nothing's added twice.
        #expect(await relaunch().rebuildIndex(in: context).isEmpty)
    }

    @Test func reconcileWritesManifestsForNotesWithoutOne() async throws {
        let note = Note(title: "Sample", pageCount: 3, template: .preset(.smallGrid))
        await DocumentStore(library: library).reconcile([note])
        let manifest = try #require(NoteManifest.read(from: NotePackage.manifestURL(for: note.id, in: library)))
        #expect(manifest.pageCount == 3)
        #expect(manifest.title == "Sample")
        #expect(await relaunch().notebook(for: note).pageCount == 3)
    }

    @Test func reconcileSetsAsideAManifestItCantRead() async throws {
        let note = Note(title: "Test")
        let url = NotePackage.manifestURL(for: note.id, in: library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: url)
        await DocumentStore(library: library).reconcile([note])
        #expect(NoteManifest.read(from: url) != nil)
        #expect(packageFiles(of: note).contains { $0.hasPrefix("manifest.json.damaged-") })
    }
}

// MARK: - Helpers

/// A note's page order and each page's ink, as written to disk (the format quantizes samples, and
/// re-encoding what it read gives the same bytes).
@MainActor
private struct NoteState: Equatable {
    let pageIDs: [UUID]
    let ink: [UUID: Data]

    init(_ notebook: InkNotebook) {
        pageIDs = notebook.pages.map(\.id)
        ink = Dictionary(uniqueKeysWithValues: notebook.pages.map { ($0.id, $0.inkFile.encoded()) })
    }
}

/// Records the steps of the writes it's handed.
private final class StepLog: Sendable {
    private let log = OSAllocatedUnfairLock(initialState: [PackageFiles.Step]())

    func record(_ step: PackageFiles.Step) {
        log.withLock { $0.append(step) }
    }

    func reset() {
        log.withLock { $0.removeAll() }
    }

    var steps: [PackageFiles.Step] {
        log.withLock { $0 }
    }
}

/// Once armed, throws at the nth write step from then on and at every step after it, like a killed app.
private final class KillSwitch: Sendable {
    private struct State {
        var remaining: Int?
        var fired = false
    }

    struct Killed: Error {}

    private let state = OSAllocatedUnfairLock(initialState: State())

    func arm(failingAt step: Int) {
        state.withLock { $0 = State(remaining: step) }
    }

    var fired: Bool {
        state.withLock(\.fired)
    }

    func step(_: PackageFiles.Step) throws {
        let kill = state.withLock { state -> Bool in
            guard let remaining = state.remaining else { return false }
            if state.fired || remaining == 0 {
                state.fired = true
                // Disarm, so the next save (after a "relaunch") works.
                state.remaining = nil
                return true
            }
            state.remaining = remaining - 1
            return false
        }
        if kill {
            throw Killed()
        }
    }
}

/// A tiny opaque PNG.
func makePNG() throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
