import Foundation
import InkKit
import Observation

/// Keeps each note's InkKit notebook alive for the session, so reopening a note restores its pages,
/// their strokes and their undo history.
///
/// InkKit has no on-disk format yet, so ink is not persisted across launches.
@Observable
@MainActor
final class InkStore {
    @ObservationIgnored private var notebooks: [UUID: InkNotebook] = [:]

    /// The note's notebook, created on first use with `pageCount` blank pages of `pageSize`.
    func notebook(for noteID: UUID, pageCount: Int = 1, pageSize: PageSize = .default) -> InkNotebook {
        if let notebook = notebooks[noteID] {
            return notebook
        }
        let notebook = InkNotebook(pageSize: pageSize, pageCount: pageCount)
        notebooks[noteID] = notebook
        return notebook
    }

    /// The note's notebook if it has been opened this session, without creating one.
    func existingNotebook(for noteID: UUID) -> InkNotebook? {
        notebooks[noteID]
    }

    func discard(noteID: UUID) {
        notebooks[noteID] = nil
    }
}
