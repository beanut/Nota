import CoreGraphics
import Foundation
import InkKit
@testable import NotaCore
import Testing

/// Tape in note packages: whether each strip is revealed or hidden is saved with the note and read back after
/// a relaunch, with its place, colour and pattern.
@Suite("DocumentStore tape")
@MainActor
struct DocumentStoreTapeTests {
    private let library = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    @Test func tapeAndItsRevealedStateSurviveASaveAndReopen() async throws {
        let documents = DocumentStore(library: library)
        let note = Note(title: "Flashcards")
        documents.create(note, size: .letter, template: .blank)
        let page = try #require(await documents.notebook(for: note).pages.first)
        let covering = TapeObject(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 250, y: 100), width: 24,
                                  color: PenColor(rgb: 0xB9D3B2), pattern: .striped)
        let shown = TapeObject(from: CGPoint(x: 50, y: 200), to: CGPoint(x: 250, y: 260), color: PenColor(rgb: 0xA9C8EA))
        page.addObject(covering)
        page.addObject(shown)
        page.toggleTape(id: shown.id)
        documents.save(note)
        await documents.flush()

        // A fresh store reads the package from disk.
        let reopened = try #require(await DocumentStore(library: library).notebook(for: note).pages.first)
        let tapes = reopened.tapes
        #expect(tapes.count == 2)
        #expect(tapes.first { $0.id == covering.id } == covering)
        #expect(tapes.first { $0.id == covering.id }?.isRevealed == false)
        #expect(tapes.first { $0.id == shown.id }?.isRevealed == true)

        // Hiding it again is saved too.
        page.setAllTape(revealed: false)
        documents.save(note)
        await documents.flush()
        let again = try #require(await DocumentStore(library: library).notebook(for: note).pages.first)
        #expect(again.tapes.allSatisfy { !$0.isRevealed })
    }
}
