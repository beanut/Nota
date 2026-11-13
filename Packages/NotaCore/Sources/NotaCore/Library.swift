import Foundation
import SwiftData

// The library's filtering, search and sorting rules. Kept here rather than in the app's views so they can be
// tested without a UI; the app only adds icons and layout.

/// What the sidebar has selected: a smart collection or a folder.
public enum LibrarySection: Hashable, Sendable {
    case all, recents, favorites, shared, deleted
    case folder(PersistentIdentifier)

    public static let smart: [LibrarySection] = [.all, .recents, .favorites, .shared, .deleted]

    /// How far back Recents looks.
    public static let recentsWindowDays = 7

    public var title: String {
        switch self {
        case .all: "All Notes"
        case .recents: "Recents"
        case .favorites: "Favorites"
        case .shared: "Shared"
        case .deleted: "Recently Deleted"
        case .folder: "Folder"
        }
    }

    /// Whether a note belongs in this section. Recently Deleted shows only deleted notes; every other
    /// section hides them.
    public func contains(_ note: Note, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .deleted: return note.isDeleted
        case _ where note.isDeleted: return false
        case .all: return true
        case .recents:
            let cutoff = calendar.date(byAdding: .day, value: -Self.recentsWindowDays, to: now) ?? .distantPast
            return note.modifiedAt >= cutoff
        case .favorites: return note.isFavorite
        case .shared: return note.isShared
        case let .folder(id): return note.folder?.persistentModelID == id
        }
    }
}

/// The chips above the grid. They narrow whatever section is selected.
public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case recent, notebooks, pdfs
    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .recent: "Recent"
        case .notebooks: "Notebooks"
        case .pdfs: "PDFs"
        }
    }

    /// "Recent" is the unfiltered view: every kind, newest first.
    public func contains(_ note: Note) -> Bool {
        switch self {
        case .recent: true
        case .notebooks: note.kind == .notebook
        case .pdfs: note.kind == .pdf
        }
    }
}

public enum Library {
    /// The notes the grid shows for a section, filter chip and search text, most recently modified first.
    ///
    /// Search ignores surrounding whitespace, case and diacritics, and matches anywhere in the title.
    /// Notes modified at the same moment are ordered by title, so the grid doesn't reshuffle between renders.
    public static func visibleNotes(_ notes: [Note],
                                    in section: LibrarySection,
                                    filter: LibraryFilter = .recent,
                                    search: String = "",
                                    now: Date = .now,
                                    calendar: Calendar = .current) -> [Note] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes
            .filter { note in
                section.contains(note, now: now, calendar: calendar)
                    && filter.contains(note)
                    && (query.isEmpty || note.title.localizedStandardContains(query))
            }
            .sorted(by: isOrderedBefore)
    }

    /// Newest first; ties broken by title, then by id so the order is total.
    static func isOrderedBefore(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The All Notes count in the sidebar: everything not in Recently Deleted.
    public static func activeCount(of notes: [Note]) -> Int {
        notes.filter { !$0.isDeleted }.count
    }

    /// The sort index for a folder added after `folders`.
    public static func nextSortIndex(after folders: [Folder]) -> Int {
        (folders.map(\.sortIndex).max() ?? -1) + 1
    }

    /// Moves folders as a list's `onMove` describes, then renumbers every folder 0, 1, 2… in the new order.
    /// `folders` must be in their current display order (by `sortIndex`).
    public static func moveFolders(_ folders: [Folder], from source: IndexSet, to destination: Int) {
        var reordered = folders
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, folder) in reordered.enumerated() {
            folder.sortIndex = index
        }
    }
}

// MARK: - Recently Deleted

public extension Note {
    /// Moves the note to Recently Deleted. It keeps its folder, so recovering puts it back where it was.
    func moveToRecentlyDeleted(at date: Date = .now) {
        deletedAt = date
    }

    /// Takes the note out of Recently Deleted.
    func recover() {
        deletedAt = nil
    }
}
