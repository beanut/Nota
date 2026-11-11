import InkKit
import Foundation
import Observation

/// Keeps each note's InkKit document alive for the session, so reopening a note restores its strokes
/// and its undo history.
///
/// InkKit has no on-disk format yet, so ink is not persisted across launches.
@Observable
@MainActor
final class InkStore {
    @ObservationIgnored private var documents: [UUID: CanvasDocument] = [:]

    func document(for noteID: UUID) -> CanvasDocument {
        if let document = documents[noteID] { return document }
        let document = CanvasDocument()
        documents[noteID] = document
        return document
    }

    func discard(noteID: UUID) {
        documents[noteID] = nil
    }
}
