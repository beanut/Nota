import Foundation
import InkKit
import NotaCore
import Observation
import UIKit

/// Renders each note's cover page (paper template + ink) to an image, keeps it in the note package's
/// `thumbs/` folder and serves it to library cards.
///
/// Rendering, PNG encoding, disk reads and decoding all happen off the main actor; a card asks with
/// `image(for:)` and redraws when `generation(for:)` changes. Decoded images are kept in a bounded memory
/// cache, so a large library scrolls without holding every thumbnail.
///
/// Paper and ink are the same in light and dark mode (see DESIGN.md), so one image serves both.
@Observable
@MainActor
public final class ThumbnailStore {
    /// Cards are at most 260 pt wide; 2× that keeps them sharp on iPad.
    nonisolated static let pixelWidth = 520

    /// Bumped each time a note's cover is re-rendered or removed, so its card reloads.
    private var generations: [UUID: Int] = [:]

    @ObservationIgnored private let library: URL
    @ObservationIgnored private let memory = NSCache<NSUUID, UIImage>()
    /// What each note's cached cover was rendered from, so an unchanged cover isn't rendered again.
    @ObservationIgnored private var renderedFrom: [UUID: CoverKey] = [:]
    @ObservationIgnored private var renders: [UUID: Task<Void, Never>] = [:]
    /// Finishes once stale covers from a previous launch are gone; reads wait for it.
    @ObservationIgnored private let ready: Task<Void, Never>

    private struct CoverKey: Equatable {
        let pageID: UUID
        let revision: Int
        let paper: PaperStyle
    }

    public init(library: URL = NotePackage.libraryURL) {
        self.library = library
        memory.countLimit = 150
        // Ink lives only in memory until NOT-6, so covers left by an earlier launch show ink that no longer
        // exists. Drop them; remove this once notes are saved to disk.
        ready = Task.detached(priority: .userInitiated) {
            Self.removeAllThumbnails(in: library)
        }
    }

    public func generation(for noteID: UUID) -> Int {
        generations[noteID, default: 0]
    }

    /// The note's cover if it's already decoded in memory. Cheap enough to call from `body`.
    public func cachedImage(for noteID: UUID) -> UIImage? {
        memory.object(forKey: noteID as NSUUID)
    }

    /// The note's cover, loaded from its package and decoded off the main actor. Nil when the note has no
    /// ink yet.
    public func image(for noteID: UUID) async -> UIImage? {
        if let image = cachedImage(for: noteID) {
            return image
        }
        await ready.value
        let url = NotePackage.coverURL(for: noteID, in: library)
        let generation = generation(for: noteID)
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
        // A newer render may have landed while this one decoded; it's already in the cache.
        if let image, generation == self.generation(for: noteID) {
            memory.setObject(image, forKey: noteID as NSUUID)
        }
        return cachedImage(for: noteID) ?? image
    }

    /// Re-renders the note's cover from `page` unless the cached cover already shows this revision.
    public func updateCover(of noteID: UUID, page: PageSnapshot, paper: PaperStyle) {
        let key = CoverKey(pageID: page.pageID, revision: page.revision, paper: paper)
        guard renderedFrom[noteID] != key else { return }
        renderedFrom[noteID] = key
        renders[noteID]?.cancel()

        let url = NotePackage.coverURL(for: noteID, in: library)
        let ready = ready
        renders[noteID] = Task { [weak self] in
            await ready.value
            let image = await Task.detached(priority: .userInitiated) {
                Self.renderAndSave(page, paper: paper, to: url)
            }.value
            guard let self, !Task.isCancelled else { return }
            if let image {
                memory.setObject(image, forKey: noteID as NSUUID)
            } else {
                memory.removeObject(forKey: noteID as NSUUID)
            }
            generations[noteID, default: 0] += 1
            renders[noteID] = nil
        }
    }

    /// Forgets the note's cover and deletes its thumbnails, for a note deleted permanently.
    public func remove(noteID: UUID) {
        renders.removeValue(forKey: noteID)?.cancel()
        renderedFrom[noteID] = nil
        memory.removeObject(forKey: noteID as NSUUID)
        generations[noteID] = nil
        let folder = NotePackage.thumbnailsURL(for: noteID, in: library)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Off the main actor

    /// Renders the cover and writes it to `url`, returning it decoded for display. A blank page has no
    /// cover: its file is removed and the card shows the bare template.
    private nonisolated static func renderAndSave(_ page: PageSnapshot, paper: PaperStyle, to url: URL) -> UIImage? {
        let files = FileManager.default
        guard !page.isBlank else {
            try? files.removeItem(at: url)
            return nil
        }
        guard let cgImage = PageRenderer.image(of: page, pixelWidth: pixelWidth, background: { ctx, size in
            PaperTemplate.draw(paper, in: ctx, size: size)
        }) else { return nil }
        let image = UIImage(cgImage: cgImage)
        if let png = image.pngData() {
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
        }
        return image.preparingForDisplay() ?? image
    }

    private nonisolated static func removeAllThumbnails(in library: URL) {
        let files = FileManager.default
        guard let packages = try? files.contentsOfDirectory(at: library, includingPropertiesForKeys: nil) else { return }
        for package in packages where package.pathExtension == "nota" {
            try? files.removeItem(at: package.appending(path: "thumbs", directoryHint: .isDirectory))
        }
    }
}
