import Foundation

/// Where links between notes have led in one window, so Back can return: each step is the note (and page) a
/// link was followed from and the note it opened in its place. In a split, each side has its own steps: Back
/// in a note returns to whatever that note replaced.
///
/// Links inside one note are InkKit's to go back from (`LinkHistory`); this is only for links to other notes.
public struct LinkTrail: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        /// The note the link was on, and the page it was on there.
        public var fromNote: UUID
        public var fromPage: UUID?
        /// The note the link opened.
        public var toNote: UUID

        public init(fromNote: UUID, fromPage: UUID?, toNote: UUID) {
            self.fromNote = fromNote
            self.fromPage = fromPage
            self.toNote = toNote
        }
    }

    /// How many steps are kept.
    public static let limit = 50

    public private(set) var steps: [Step] = []

    public init(steps: [Step] = []) {
        self.steps = Array(steps.suffix(Self.limit))
    }

    /// Records that a link on `fromPage` of `fromNote` opened `toNote` in its place.
    public mutating func follow(from fromNote: UUID, page fromPage: UUID?, to toNote: UUID) {
        guard fromNote != toNote else { return }
        steps.append(Step(fromNote: fromNote, fromPage: fromPage, toNote: toNote))
        if steps.count > Self.limit {
            steps.removeFirst(steps.count - Self.limit)
        }
    }

    /// Where Back in `note` goes: the most recent step that opened it.
    public func back(from note: UUID) -> Step? {
        steps.last { $0.toNote == note }
    }

    /// Takes the most recent step that opened `note` off the trail and returns it, for going back.
    public mutating func goBack(from note: UUID) -> Step? {
        guard let i = steps.lastIndex(where: { $0.toNote == note }) else { return nil }
        return steps.remove(at: i)
    }

    /// Forgets the steps Back can no longer reach from the open notes: those into notes that were closed (or
    /// deleted), so a note opened again later from the library doesn't offer to go back. Steps further back
    /// along a chain (A → B → C, with C open) are kept.
    public mutating func keepSteps(reachableFrom open: some Sequence<UUID>) {
        var reachable = Set(open)
        var kept: [Step] = []
        for step in steps.reversed() where reachable.contains(step.toNote) {
            kept.append(step)
            reachable.insert(step.fromNote)
        }
        steps = kept.reversed()
    }
}

public extension NoteWorkspace {
    /// Shows `new` where `old` is (the same side of a split), as following a link does. If `new` is already
    /// open beside it, nothing changes; if `old` isn't open, `new` is opened on its own.
    mutating func replace(_ old: UUID, with new: UUID) {
        guard old != new, !contains(new) else { return }
        guard let i = noteIDs.firstIndex(of: old) else {
            open(new)
            return
        }
        var ids = noteIDs
        ids[i] = new
        self = NoteWorkspace(noteIDs: ids)
    }
}

public extension Library {
    /// The notes a link on `note` can go to: every other note not in Recently Deleted, most recently modified
    /// first, at most `limit` of them.
    static func notesToLinkTo(_ notes: [Note], from note: UUID, limit: Int = 100) -> [Note] {
        notesToOpenBeside(notes, excluding: [note], limit: limit)
    }
}
