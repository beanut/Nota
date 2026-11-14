import Foundation
import SwiftData

// MARK: - Notes open in a window

/// The notes open in one library window: none (the library grid), one, or two side by side. Saved with
/// the window's scene, so each window reopens with the notes it had open.
///
/// The first note is the one opened from the library; the second is the one opened beside it.
public struct NoteWorkspace: Hashable, Sendable {
    /// How many notes a window shows at once.
    public static let capacity = 2

    public private(set) var noteIDs: [UUID]

    /// The notes in order, without duplicates and at most `capacity` of them.
    public init(noteIDs: [UUID] = []) {
        var unique: [UUID] = []
        for id in noteIDs where !unique.contains(id) && unique.count < Self.capacity {
            unique.append(id)
        }
        self.noteIDs = unique
    }

    /// No note is open: the window shows the library.
    public var isEmpty: Bool {
        noteIDs.isEmpty
    }

    /// Two notes are open side by side.
    public var isSplit: Bool {
        noteIDs.count == Self.capacity
    }

    public func contains(_ id: UUID) -> Bool {
        noteIDs.contains(id)
    }

    /// Shows only `id`, closing whatever was open.
    public mutating func open(_ id: UUID) {
        noteIDs = [id]
    }

    /// Opens `id` beside the open note, replacing the one already beside it. With nothing open, it
    /// just opens; a note that's already open stays where it is.
    public mutating func openBeside(_ id: UUID) {
        guard !contains(id) else { return }
        noteIDs = (noteIDs.first.map { [$0] } ?? []) + [id]
    }

    /// Closes `id`; in a split, the other note fills the window.
    public mutating func close(_ id: UUID) {
        noteIDs.removeAll { $0 == id }
    }

    /// Closes every note, back to the library.
    public mutating func closeAll() {
        noteIDs = []
    }

    /// Swaps the two sides of a split.
    public mutating func swapSides() {
        noteIDs.reverse()
    }

    /// Closes the notes `isGone` says are gone (deleted permanently, from this or another window).
    public mutating func removeNotes(where isGone: (UUID) -> Bool) {
        noteIDs.removeAll(where: isGone)
    }
}

extension NoteWorkspace: RawRepresentable {
    /// Comma-separated note IDs, for `@SceneStorage`.
    public var rawValue: String {
        noteIDs.map(\.uuidString).joined(separator: ",")
    }

    /// Unreadable IDs are skipped, so a damaged value restores what it can.
    public init(rawValue: String) {
        self.init(noteIDs: rawValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}

// MARK: - Restoring the sidebar selection

public extension LibrarySection {
    /// The section as a string, for `@SceneStorage`. A folder is kept by its persistent identifier.
    var sceneValue: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The section `sceneValue` describes, or nil when it can't be read.
    init?(sceneValue: String) {
        guard let data = sceneValue.data(using: .utf8),
              let section = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = section
    }
}

// MARK: - Finding notes

public extension Library {
    /// The notes pages can be copied or moved to from `note`'s page sidebar: every other note not in
    /// Recently Deleted, most recently modified first, at most `limit` of them.
    static func notesToSendPagesTo(_ notes: [Note], from note: UUID, limit: Int = 20) -> [Note] {
        notesToOpenBeside(notes, excluding: [note], limit: limit)
    }

    /// The notes that can be opened beside `open`: every note not in Recently Deleted and not already open,
    /// most recently modified first, at most `limit` of them.
    static func notesToOpenBeside(_ notes: [Note], excluding open: [UUID], limit: Int = 12) -> [Note] {
        let open = Set(open)
        return notes
            .filter { !$0.isDeleted && !open.contains($0.id) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map(\.self)
    }
}

public extension ModelContext {
    /// The note with `id`, or nil once it's deleted permanently.
    func note(withID id: UUID) -> Note? {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }
}

// MARK: - Opening a note in a new window

/// The user activity that opens a note in a window of its own: dragged from the library to the side or
/// edge of the screen, the system makes a new window from it. Its type is listed under
/// `NSUserActivityTypes` in the app's Info.plist.
public enum NoteActivity {
    public static let activityType = "com.bernard.nota.openNote"
    /// Routes the activity to the note window scene (`handlesExternalEvents(matching:)`).
    public static let targetContentIdentifier = "nota-note"
    static let noteIDKey = "noteID"

    /// An activity that opens the note `noteID`, titled `title` in the app switcher.
    public static func make(noteID: UUID, title: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = title
        activity.targetContentIdentifier = targetContentIdentifier
        activity.userInfo = [noteIDKey: noteID.uuidString]
        activity.requiredUserInfoKeys = [noteIDKey]
        return activity
    }

    /// The note an activity opens, or nil when it isn't a note activity.
    public static func noteID(in activity: NSUserActivity) -> UUID? {
        guard activity.activityType == activityType,
              let value = activity.userInfo?[noteIDKey] as? String else { return nil }
        return UUID(uuidString: value)
    }
}
