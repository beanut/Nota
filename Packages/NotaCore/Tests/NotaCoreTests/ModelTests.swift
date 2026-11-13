import Foundation
@testable import NotaCore
import SwiftData
import Testing

@Suite("Note")
@MainActor
struct NoteTests {
    @Test func defaultsAndCreationDate() {
        let date = Clock.daysAgo(3)
        let note = Note(title: "Physics", modifiedAt: date)
        #expect(note.pageCount == 1)
        #expect(note.paper == .lined)
        #expect(note.tint == .indigo)
        #expect(note.kind == .notebook)
        #expect(!note.isFavorite && !note.isShared && !note.isDeleted)
        #expect(note.folder == nil)
        #expect(note.createdAt == date)
        #expect(note.modifiedAt == date)
    }

    @Test func eachNoteGetsItsOwnID() {
        #expect(Note(title: "A").id != Note(title: "A").id)
    }

    @Test func enumPropertiesWriteThroughToStoredNames() {
        let note = Note(title: "N")
        note.paper = .grid
        note.tint = .rust
        note.kind = .pdf
        #expect(note.paperName == "grid")
        #expect(note.tintName == "rust")
        #expect(note.kindName == "pdf")
    }

    /// A value written by a newer build (or a typo in a migration) mustn't crash or blank the library.
    @Test func unknownStoredNamesFallBackToDefaults() {
        let note = Note(title: "N", paper: .dotted, tint: .teal, kind: .pdf)
        note.paperName = "hexagonal"
        note.tintName = "chartreuse"
        note.kindName = "video"
        #expect(note.paper == .lined)
        #expect(note.tint == .indigo)
        #expect(note.kind == .notebook)
    }

    @Test func subtitlePluralisesPages() {
        #expect(Note(title: "N", pageCount: 1, modifiedAt: .now).subtitle == "1 page · Today")
        #expect(Note(title: "N", pageCount: 12, modifiedAt: .now).subtitle == "12 pages · Today")
    }

    @Test func recentlyDeletedRoundTrip() {
        let folder = Folder(name: "Work", color: .teal, sortIndex: 0)
        let note = Note(title: "N", folder: folder)
        note.moveToRecentlyDeleted(at: Clock.now)
        #expect(note.isDeleted)
        #expect(note.deletedAt == Clock.now)
        #expect(note.folder === folder, "a deleted note remembers its folder")
        note.recover()
        #expect(!note.isDeleted)
        #expect(note.deletedAt == nil)
        #expect(note.folder === folder)
    }

    @Test func persistsThroughSwiftData() throws {
        let context = try makeContext()
        let note = Note(title: "Kestrel", pageCount: 8, paper: .grid, tint: .violet, kind: .pdf, isShared: true)
        note.moveToRecentlyDeleted(at: Clock.now)
        context.insert(note)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Note>()).first)
        #expect(fetched.title == "Kestrel")
        #expect(fetched.pageCount == 8)
        #expect(fetched.paper == .grid)
        #expect(fetched.tint == .violet)
        #expect(fetched.kind == .pdf)
        #expect(fetched.isShared)
        #expect(fetched.deletedAt == Clock.now)
    }
}

@Suite("Folder")
@MainActor
struct FolderTests {
    @Test func colorWritesThroughAndFallsBack() {
        let folder = Folder(name: "F", color: .pink, sortIndex: 0)
        #expect(folder.color == .pink)
        folder.color = .green
        #expect(folder.colorName == "green")
        folder.colorName = "mauve"
        #expect(folder.color == .blue)
    }

    @Test func notesRelationshipIsTheInverseOfNoteFolder() throws {
        let context = try makeContext()
        let folder = Folder(name: "Courses", color: .blue, sortIndex: 0)
        context.insert(folder)
        let notes = (1 ... 3).map { Note(title: "Lecture \($0)", folder: folder) }
        notes.forEach(context.insert)
        try context.save()
        #expect(Set(folder.notes.map(\.id)) == Set(notes.map(\.id)))

        notes[0].folder = nil
        try context.save()
        #expect(folder.notes.count == 2)
    }

    @Test func activeNoteCountSkipsRecentlyDeleted() throws {
        let context = try makeContext()
        let folder = Folder(name: "Work", color: .teal, sortIndex: 0)
        context.insert(folder)
        let notes = (1 ... 4).map { Note(title: "N\($0)", folder: folder) }
        notes.forEach(context.insert)
        notes[1].moveToRecentlyDeleted()
        notes[3].moveToRecentlyDeleted()
        try context.save()
        #expect(folder.activeNoteCount == 2)

        notes[1].recover()
        #expect(folder.activeNoteCount == 3)
    }

    /// The sidebar promises "Notes in this folder stay in All Notes."
    @Test func deletingAFolderKeepsItsNotes() throws {
        let context = try makeContext()
        let folder = Folder(name: "Personal", color: .orange, sortIndex: 0)
        context.insert(folder)
        let note = Note(title: "Recipes", folder: folder)
        context.insert(note)
        try context.save()

        context.delete(folder)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<Note>())
        #expect(remaining.map(\.title) == ["Recipes"])
        #expect(remaining.first?.folder == nil)
        #expect(try context.fetchCount(FetchDescriptor<Folder>()) == 0)
    }
}

@Suite("SampleData")
@MainActor
struct SampleDataTests {
    @Test func seedsFoldersAndNotes() throws {
        let context = try makeContext()
        SampleData.seed(in: context)
        let folders = try context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortIndex)]))
        #expect(folders.map(\.name) == ["Courses", "Work", "Personal"])
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 42)
        #expect(notes.allSatisfy { $0.folder != nil && !$0.isDeleted })
        #expect(notes.contains { $0.kind == .pdf })
    }
}
