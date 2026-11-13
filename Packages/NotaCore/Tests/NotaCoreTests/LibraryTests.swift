import Foundation
@testable import NotaCore
import SwiftData
import Testing

/// A small library in an in-memory store: two folders and notes covering every flag the library filters on.
@MainActor
private struct Fixture {
    let context: ModelContext
    let work: Folder
    let personal: Folder
    let notes: [String: Note]

    init() throws {
        context = try makeContext()
        work = Folder(name: "Work", color: .teal, sortIndex: 0)
        personal = Folder(name: "Personal", color: .orange, sortIndex: 1)
        context.insert(work)
        context.insert(personal)

        let all = [
            Note(title: "Physics — Lecture 7", modifiedAt: Clock.daysAgo(0), isFavorite: true, folder: work),
            Note(title: "Kestrel Roadmap", modifiedAt: Clock.daysAgo(2), kind: .pdf, isShared: true, folder: work),
            Note(title: "Reading Journal", modifiedAt: Clock.daysAgo(9), isFavorite: true, folder: personal),
            Note(title: "Café Menu", modifiedAt: Clock.daysAgo(12), kind: .pdf, folder: personal),
            Note(title: "Loose Sketch", modifiedAt: Clock.daysAgo(30), isShared: true),
            Note(title: "Old Draft", modifiedAt: Clock.daysAgo(1), isFavorite: true, isShared: true, folder: work)
        ]
        all.forEach(context.insert)
        all.last?.moveToRecentlyDeleted(at: Clock.now)
        try context.save()
        notes = Dictionary(uniqueKeysWithValues: all.map { ($0.title, $0) })
    }

    var allNotes: [Note] {
        Array(notes.values)
    }

    func titles(in section: LibrarySection, filter: LibraryFilter = .recent, search: String = "") -> [String] {
        Library.visibleNotes(allNotes, in: section, filter: filter, search: search,
                             now: Clock.now, calendar: Clock.calendar).map(\.title)
    }
}

@Suite("Smart collections")
@MainActor
struct SmartCollectionTests {
    @Test func allNotesIsEverythingNotDeletedNewestFirst() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all) == ["Physics — Lecture 7", "Kestrel Roadmap", "Reading Journal",
                                             "Café Menu", "Loose Sketch"])
    }

    @Test func recentsCoversTheLastSevenDays() throws {
        let library = try Fixture()
        #expect(library.titles(in: .recents) == ["Physics — Lecture 7", "Kestrel Roadmap"])
    }

    @Test func recentsCutoffIsInclusive() throws {
        let context = try makeContext()
        let cutoff = try #require(Clock.calendar.date(byAdding: .day, value: -7, to: Clock.now))
        let onTheLine = Note(title: "On the line", modifiedAt: cutoff)
        let justBefore = Note(title: "Just before", modifiedAt: cutoff.addingTimeInterval(-1))
        [onTheLine, justBefore].forEach(context.insert)
        #expect(LibrarySection.recents.contains(onTheLine, now: Clock.now, calendar: Clock.calendar))
        #expect(!LibrarySection.recents.contains(justBefore, now: Clock.now, calendar: Clock.calendar))
    }

    @Test func favoritesAndShared() throws {
        let library = try Fixture()
        #expect(library.titles(in: .favorites) == ["Physics — Lecture 7", "Reading Journal"])
        #expect(library.titles(in: .shared) == ["Kestrel Roadmap", "Loose Sketch"])
    }

    @Test func folderShowsOnlyItsOwnActiveNotes() throws {
        let library = try Fixture()
        #expect(library.titles(in: .folder(library.work.persistentModelID)) == ["Physics — Lecture 7", "Kestrel Roadmap"])
        #expect(library.titles(in: .folder(library.personal.persistentModelID)) == ["Reading Journal", "Café Menu"])
    }

    @Test func recentlyDeletedShowsOnlyDeletedNotes() throws {
        let library = try Fixture()
        #expect(library.titles(in: .deleted) == ["Old Draft"])
    }

    /// A deleted favourite, shared note in a folder appears in none of those sections, only in Recently Deleted.
    @Test func deletedNotesAreHiddenEverywhereElse() throws {
        let library = try Fixture()
        let deleted = try #require(library.notes["Old Draft"])
        for section in LibrarySection.smart + [.folder(library.work.persistentModelID)] where section != .deleted {
            #expect(!section.contains(deleted, now: Clock.now, calendar: Clock.calendar), "\(section.title)")
        }
        #expect(LibrarySection.deleted.contains(deleted))
    }

    @Test func recoveringPutsANoteBack() throws {
        let library = try Fixture()
        try #require(library.notes["Old Draft"]).recover()
        #expect(library.titles(in: .deleted).isEmpty)
        #expect(library.titles(in: .favorites).contains("Old Draft"))
        #expect(library.titles(in: .folder(library.work.persistentModelID)).contains("Old Draft"))
    }

    @Test func deletingMovesANoteToRecentlyDeleted() throws {
        let library = try Fixture()
        try #require(library.notes["Kestrel Roadmap"]).moveToRecentlyDeleted(at: Clock.now)
        #expect(library.titles(in: .deleted) == ["Old Draft", "Kestrel Roadmap"])
        #expect(!library.titles(in: .all).contains("Kestrel Roadmap"))
        #expect(!library.titles(in: .shared).contains("Kestrel Roadmap"))
    }

    @Test func sidebarCountsSkipDeletedNotes() throws {
        let library = try Fixture()
        #expect(Library.activeCount(of: library.allNotes) == 5)
        #expect(library.work.activeNoteCount == 2)
    }

    @Test func smartSectionsAreInSidebarOrder() {
        #expect(LibrarySection.smart.map(\.title) == ["All Notes", "Recents", "Favorites", "Shared", "Recently Deleted"])
    }
}

@Suite("Filter chips")
@MainActor
struct FilterChipTests {
    @Test func recentIsUnfiltered() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all, filter: .recent) == library.titles(in: .all))
    }

    @Test func notebooksAndPDFsSplitByKind() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all, filter: .notebooks) == ["Physics — Lecture 7", "Reading Journal", "Loose Sketch"])
        #expect(library.titles(in: .all, filter: .pdfs) == ["Kestrel Roadmap", "Café Menu"])
    }

    @Test func chipsNarrowTheSelectedSection() throws {
        let library = try Fixture()
        #expect(library.titles(in: .shared, filter: .pdfs) == ["Kestrel Roadmap"])
        #expect(library.titles(in: .favorites, filter: .pdfs).isEmpty)
        #expect(library.titles(in: .folder(library.personal.persistentModelID), filter: .notebooks) == ["Reading Journal"])
    }

    @Test func chipOrder() {
        #expect(LibraryFilter.allCases.map(\.title) == ["Recent", "Notebooks", "PDFs"])
    }
}

@Suite("Search")
@MainActor
struct SearchTests {
    @Test func matchesAnywhereInTheTitleIgnoringCase() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all, search: "road") == ["Kestrel Roadmap"])
        #expect(library.titles(in: .all, search: "LECTURE") == ["Physics — Lecture 7"])
        #expect(library.titles(in: .all, search: "e") == library.titles(in: .all).filter { $0.localizedCaseInsensitiveContains("e") })
    }

    @Test func ignoresDiacritics() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all, search: "cafe") == ["Café Menu"])
    }

    @Test func blankSearchShowsEverything() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all, search: "   ") == library.titles(in: .all))
        #expect(library.titles(in: .all, search: "\n") == library.titles(in: .all))
    }

    @Test func trimsButKeepsInnerSpaces() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all, search: "  reading journal ") == ["Reading Journal"])
        #expect(library.titles(in: .all, search: "readingjournal").isEmpty)
    }

    @Test func staysInsideTheSectionAndChip() throws {
        let library = try Fixture()
        #expect(library.titles(in: .deleted, search: "draft") == ["Old Draft"])
        #expect(library.titles(in: .all, search: "draft").isEmpty)
        #expect(library.titles(in: .all, filter: .pdfs, search: "journal").isEmpty)
    }

    @Test func noMatches() throws {
        let library = try Fixture()
        #expect(library.titles(in: .all, search: "zzz").isEmpty)
    }
}

@Suite("Sorting")
@MainActor
struct SortingTests {
    @Test func newestFirstRegardlessOfInputOrder() throws {
        let library = try Fixture()
        let shuffled = Library.visibleNotes(library.allNotes.shuffled(), in: .all, now: Clock.now, calendar: Clock.calendar)
        let reversed = Library.visibleNotes(library.allNotes.reversed(), in: .all, now: Clock.now, calendar: Clock.calendar)
        #expect(shuffled.map(\.id) == reversed.map(\.id))
        #expect(shuffled.map(\.modifiedAt) == shuffled.map(\.modifiedAt).sorted(by: >))
    }

    @Test func tiesAreBrokenByTitle() throws {
        let context = try makeContext()
        let date = Clock.daysAgo(1)
        let notes = ["Banana", "apple", "Cherry", "item 10", "item 2"].map { Note(title: $0, modifiedAt: date) }
        notes.forEach(context.insert)
        let sorted = Library.visibleNotes(notes.shuffled(), in: .all, now: Clock.now, calendar: Clock.calendar)
        #expect(sorted.map(\.title) == ["apple", "Banana", "Cherry", "item 2", "item 10"])
    }

    @Test func identicalNotesStillHaveAStableOrder() throws {
        let context = try makeContext()
        let date = Clock.daysAgo(1)
        let notes = (0 ..< 5).map { _ in Note(title: "Untitled Note", modifiedAt: date) }
        notes.forEach(context.insert)
        let first = Library.visibleNotes(notes, in: .all, now: Clock.now, calendar: Clock.calendar).map(\.id)
        let second = Library.visibleNotes(notes.reversed(), in: .all, now: Clock.now, calendar: Clock.calendar).map(\.id)
        #expect(first == second)
    }
}

@Suite("Folder ordering")
@MainActor
struct FolderOrderingTests {
    private func folders(_ names: [String], in context: ModelContext) -> [Folder] {
        let folders = names.enumerated().map { Folder(name: $1, color: .blue, sortIndex: $0) }
        folders.forEach(context.insert)
        return folders
    }

    @Test func newFolderGoesLast() throws {
        let context = try makeContext()
        #expect(Library.nextSortIndex(after: []) == 0)
        let existing = folders(["A", "B"], in: context)
        existing[0].sortIndex = 5 // gaps can exist after deletions
        #expect(Library.nextSortIndex(after: existing) == 6)
    }

    @Test func moveRenumbersInTheNewOrder() throws {
        let context = try makeContext()
        let list = folders(["Courses", "Work", "Personal"], in: context)
        Library.moveFolders(list, from: IndexSet(integer: 2), to: 0)
        let reordered = try context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortIndex)]))
        #expect(reordered.map(\.name) == ["Personal", "Courses", "Work"])
        #expect(reordered.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func moveToTheEnd() throws {
        let context = try makeContext()
        let list = folders(["Courses", "Work", "Personal"], in: context)
        Library.moveFolders(list, from: IndexSet(integer: 0), to: 3)
        #expect(list.sorted { $0.sortIndex < $1.sortIndex }.map(\.name) == ["Work", "Personal", "Courses"])
    }
}
