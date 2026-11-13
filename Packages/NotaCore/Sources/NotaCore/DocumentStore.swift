import Foundation
import InkKit
import Observation

/// Keeps each note's InkKit notebook alive for the session and its page layout on disk. Replaces the
/// app's former `InkStore`; lazy page loading, autosave and an LRU of open pages arrive with NOT-6.
///
/// Each note package holds a `manifest.json` (see `NoteManifest`) with every page's size and paper, so a
/// note reopens after relaunch with the same pages. The note's `pageCount`, `modifiedAt` and `paper` are
/// mirrored from it on every save. Ink and undo history live only in memory for now: InkKit encodes a
/// page as an `InkPageFile` (`.ink`), and NOT-6 writes those into the package.
@Observable
@MainActor
public final class DocumentStore {
    @ObservationIgnored private var notebooks: [UUID: InkNotebook] = [:]
    /// The last manifest read or written for each note.
    @ObservationIgnored private var manifests: [UUID: NoteManifest] = [:]
    @ObservationIgnored private let library: URL

    public init(library: URL = NotePackage.libraryURL) {
        self.library = library
    }

    // MARK: Notebooks

    /// The note's notebook, built on first use from its manifest. A note without one (an older or sample
    /// note) gets `pageCount` pages of the locale's default size on its paper.
    public func notebook(for note: Note) -> InkNotebook {
        if let notebook = notebooks[note.id] {
            return notebook
        }
        let manifest = manifest(for: note)
        let pages = manifest.pages.map { CanvasDocument(pageSize: $0.size, id: $0.id) }
        let notebook = InkNotebook(pages: pages, defaultPageSize: manifest.defaultPageSize)
        notebooks[note.id] = notebook
        return notebook
    }

    /// The note's notebook if it has been opened this session, without creating one.
    public func existingNotebook(for noteID: UUID) -> InkNotebook? {
        notebooks[noteID]
    }

    /// The paper the note's page `pageID` is drawn on.
    public func paper(ofPage pageID: UUID, in note: Note) -> PaperStyle {
        manifest(for: note).pages.first { $0.id == pageID }?.paper ?? note.paper
    }

    // MARK: Saving

    /// Writes the open notebook's page order, sizes and papers to the note's manifest and mirrors its page
    /// count, cover paper and modification date onto `note`. The note counts as modified when its pages
    /// changed or `inkChanged` is set; otherwise nothing is written.
    public func save(_ note: Note, inkChanged: Bool = false) {
        guard let notebook = notebooks[note.id] else { return }
        let old = manifest(for: note)
        var new = old
        new.defaultPageSize = notebook.defaultPageSize
        new.pages = []
        for page in notebook.pages {
            // A page added in the editor takes the paper of the page before it.
            let paper = old.pages.first { $0.id == page.id }?.paper ?? new.pages.last?.paper ?? old.coverPaper
            new.pages.append(NoteManifest.Page(id: page.id, size: page.pageSize, paper: paper))
        }
        guard inkChanged || !new.hasSameLayout(as: old) else { return }
        new.modifiedAt = .now
        store(new, for: note)
    }

    /// Puts every page of the note on `paper`.
    public func setPaper(_ paper: PaperStyle, of note: Note) {
        var manifest = manifest(for: note)
        guard manifest.pages.contains(where: { $0.paper != paper }) else {
            note.paper = paper
            return
        }
        for i in manifest.pages.indices {
            manifest.pages[i].paper = paper
        }
        manifest.modifiedAt = .now
        store(manifest, for: note)
    }

    /// Starts a new note's package with one page of `size` on `paper`.
    public func create(_ note: Note, size: PageSize, paper: PaperStyle) {
        store(NoteManifest(size: size, paper: paper, createdAt: note.createdAt, modifiedAt: note.modifiedAt), for: note)
    }

    /// Gives `copy` the same pages, sizes and papers as `original`.
    public func duplicate(_ original: Note, as copy: Note) {
        store(manifest(for: original).duplicated(at: copy.createdAt), for: copy)
    }

    /// Forgets the note's notebook and deletes its package, for a note deleted permanently.
    public func discard(noteID: UUID) {
        notebooks[noteID] = nil
        manifests[noteID] = nil
        try? FileManager.default.removeItem(at: NotePackage.url(for: noteID, in: library))
    }

    // MARK: Library

    /// Brings every note's page count, paper and modification date in line with its manifest, and writes
    /// a manifest for any note that has none yet (sample notes, or notes from before manifests existed),
    /// so from then on the manifest is what the library shows. Reads files off the main actor.
    public func reconcile(_ notes: [Note]) async {
        let library = library
        let wanted = notes.map { note in
            (id: note.id, fallback: Self.fallbackManifest(for: note))
        }
        let found: [UUID: NoteManifest] = await Task.detached(priority: .utility) {
            var found: [UUID: NoteManifest] = [:]
            for (id, fallback) in wanted {
                let url = NotePackage.manifestURL(for: id, in: library)
                if let manifest = NoteManifest.read(from: url) {
                    found[id] = manifest
                } else {
                    try? fallback.write(to: url)
                    found[id] = fallback
                }
            }
            return found
        }.value
        for note in notes {
            // A note opened meanwhile has a newer manifest in memory.
            guard manifests[note.id] == nil, let manifest = found[note.id] else { continue }
            manifests[note.id] = manifest
            mirror(manifest, onto: note)
        }
    }

    // MARK: Private

    private func manifest(for note: Note) -> NoteManifest {
        if let manifest = manifests[note.id] {
            return manifest
        }
        let url = NotePackage.manifestURL(for: note.id, in: library)
        let manifest = NoteManifest.read(from: url) ?? Self.fallbackManifest(for: note)
        manifests[note.id] = manifest
        return manifest
    }

    private func store(_ manifest: NoteManifest, for note: Note) {
        manifests[note.id] = manifest
        try? manifest.write(to: NotePackage.manifestURL(for: note.id, in: library))
        mirror(manifest, onto: note)
    }

    private func mirror(_ manifest: NoteManifest, onto note: Note) {
        if note.pageCount != manifest.pageCount {
            note.pageCount = manifest.pageCount
        }
        if note.paper != manifest.coverPaper {
            note.paper = manifest.coverPaper
        }
        if note.modifiedAt != manifest.modifiedAt {
            note.modifiedAt = manifest.modifiedAt
        }
    }

    private static func fallbackManifest(for note: Note) -> NoteManifest {
        NoteManifest(pageCount: note.pageCount, size: .localeDefault, paper: note.paper,
                     createdAt: note.createdAt, modifiedAt: note.modifiedAt)
    }
}

public extension PageSize {
    /// Letter where US paper sizes are used, A4 everywhere else.
    static var localeDefault: PageSize {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }
}
