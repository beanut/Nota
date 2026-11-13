import Foundation
@testable import NotaCore
import SwiftData
import Testing

@Suite("NoteWorkspace")
struct NoteWorkspaceTests {
    private let a = UUID(), b = UUID(), c = UUID()

    @Test func startsOnTheLibrary() {
        let workspace = NoteWorkspace()
        #expect(workspace.isEmpty)
        #expect(!workspace.isSplit)
    }

    @Test func keepsAtMostTwoDistinctNotes() {
        #expect(NoteWorkspace(noteIDs: [a, a, b, c]).noteIDs == [a, b])
    }

    @Test func openingReplacesEverything() {
        var workspace = NoteWorkspace(noteIDs: [a, b])
        workspace.open(c)
        #expect(workspace.noteIDs == [c])
    }

    @Test func openingBesideSplitsTheWindow() {
        var workspace = NoteWorkspace()
        workspace.openBeside(a)
        #expect(workspace.noteIDs == [a], "with nothing open it just opens")

        workspace.openBeside(b)
        #expect(workspace.noteIDs == [a, b])
        #expect(workspace.isSplit)

        workspace.openBeside(c)
        #expect(workspace.noteIDs == [a, c], "replaces the note beside, keeps the first")

        workspace.openBeside(a)
        #expect(workspace.noteIDs == [a, c], "an open note stays where it is")
    }

    @Test func closingOneSideLeavesTheOther() {
        var workspace = NoteWorkspace(noteIDs: [a, b])
        workspace.close(a)
        #expect(workspace.noteIDs == [b])
        workspace.close(b)
        #expect(workspace.isEmpty)
    }

    @Test func swapsAndClosesAll() {
        var workspace = NoteWorkspace(noteIDs: [a, b])
        workspace.swapSides()
        #expect(workspace.noteIDs == [b, a])
        workspace.closeAll()
        #expect(workspace.isEmpty)
    }

    @Test func dropsNotesThatAreGone() {
        var workspace = NoteWorkspace(noteIDs: [a, b])
        workspace.removeNotes { $0 == a }
        #expect(workspace.noteIDs == [b])
    }

    @Test func roundTripsThroughSceneStorage() {
        let workspace = NoteWorkspace(noteIDs: [a, b])
        #expect(NoteWorkspace(rawValue: workspace.rawValue) == workspace)
        #expect(NoteWorkspace(rawValue: "").isEmpty)
    }

    @Test func restoresWhatItCanFromADamagedValue() {
        #expect(NoteWorkspace(rawValue: "not-a-uuid,\(a.uuidString)").noteIDs == [a])
    }
}

@MainActor
@Suite("Restoring a window")
struct WindowRestorationTests {
    @Test func smartSectionsRoundTrip() {
        for section in LibrarySection.smart {
            #expect(LibrarySection(sceneValue: section.sceneValue) == section)
        }
    }

    @Test func folderSectionRoundTrips() throws {
        let context = try makeContext()
        let folder = Folder(name: "Work", color: .teal, sortIndex: 0)
        context.insert(folder)
        try context.save()
        let section = LibrarySection.folder(folder.persistentModelID)
        #expect(LibrarySection(sceneValue: section.sceneValue) == section)
    }

    @Test func unreadableSectionIsNil() {
        #expect(LibrarySection(sceneValue: "") == nil)
        #expect(LibrarySection(sceneValue: "{\"nope\":{}}") == nil)
    }

    @Test func findsNotesByIDUntilPurged() throws {
        let context = try makeContext()
        let note = Note(title: "Physics")
        context.insert(note)
        try context.save()
        #expect(context.note(withID: note.id) === note)
        #expect(context.note(withID: UUID()) == nil)

        note.moveToRecentlyDeleted(at: Clock.now)
        #expect(context.note(withID: note.id) === note, "Recently Deleted notes can still be shown")

        context.delete(note)
        try context.save()
        #expect(context.note(withID: note.id) == nil)
    }
}

@MainActor
@Suite("Opening beside")
struct OpenBesideTests {
    @Test func offersRecentLiveNotesThatArentOpen() throws {
        let context = try makeContext()
        let open = Note(title: "Open", modifiedAt: Clock.daysAgo(0))
        let older = Note(title: "Older", modifiedAt: Clock.daysAgo(5))
        let newer = Note(title: "Newer", modifiedAt: Clock.daysAgo(1))
        let deleted = Note(title: "Deleted", modifiedAt: Clock.daysAgo(2))
        [open, older, newer, deleted].forEach(context.insert)
        deleted.moveToRecentlyDeleted(at: Clock.now)

        let offered = Library.notesToOpenBeside([open, older, newer, deleted], excluding: [open.id])
        #expect(offered.map(\.title) == ["Newer", "Older"])
    }

    @Test func offersAtMostTheLimit() throws {
        let context = try makeContext()
        let notes = (0 ..< 20).map { Note(title: "\($0)", modifiedAt: Clock.daysAgo($0)) }
        notes.forEach(context.insert)
        let offered = Library.notesToOpenBeside(notes, excluding: [], limit: 5)
        #expect(offered.map(\.title) == ["0", "1", "2", "3", "4"])
    }
}

@Suite("NoteActivity")
struct NoteActivityTests {
    @Test func carriesTheNote() {
        let id = UUID()
        let activity = NoteActivity.make(noteID: id, title: "Physics")
        #expect(activity.activityType == NoteActivity.activityType)
        #expect(activity.title == "Physics")
        #expect(activity.targetContentIdentifier == NoteActivity.targetContentIdentifier)
        #expect(NoteActivity.noteID(in: activity) == id)
    }

    @Test func ignoresOtherActivities() {
        let other = NSUserActivity(activityType: "com.example.other")
        other.userInfo = [NoteActivity.noteIDKey: UUID().uuidString]
        #expect(NoteActivity.noteID(in: other) == nil)

        let damaged = NSUserActivity(activityType: NoteActivity.activityType)
        damaged.userInfo = [NoteActivity.noteIDKey: "not-a-uuid"]
        #expect(NoteActivity.noteID(in: damaged) == nil)
    }
}
