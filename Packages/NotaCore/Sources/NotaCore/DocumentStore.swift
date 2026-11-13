import Foundation
import InkKit
import Observation

/// Keeps each note's InkKit notebook alive for the session and its page layout on disk. Replaces the
/// app's former `InkStore`; lazy page loading, autosave and an LRU of open pages arrive with NOT-6.
///
/// Each note package holds a `manifest.json` (see `NoteManifest`) with every page's size and template, and
/// a `templates/` folder with the PDFs and images custom templates are drawn on, so a note reopens after
/// relaunch with the same pages. The note's `pageCount`, `modifiedAt` and `template` are
/// mirrored from it on every save. Ink and undo history live only in memory for now: InkKit encodes a
/// page as an `InkPageFile` (`.ink`), and NOT-6 writes those into the package.
@Observable
@MainActor
public final class DocumentStore {
    @ObservationIgnored private var notebooks: [UUID: InkNotebook] = [:]
    /// The last manifest read or written for each note.
    @ObservationIgnored private var manifests: [UUID: NoteManifest] = [:]
    /// Custom template backgrounds read or saved this session, by background id.
    @ObservationIgnored private var artworks: [UUID: TemplateArtwork] = [:]
    @ObservationIgnored private let library: URL

    public init(library: URL = NotePackage.libraryURL) {
        self.library = library
    }

    // MARK: Notebooks

    /// The note's notebook, built on first use from its manifest. A note without one (an older or sample
    /// note) gets `pageCount` pages of the locale's default size on its template.
    public func notebook(for note: Note) -> InkNotebook {
        if let notebook = notebooks[note.id] {
            return notebook
        }
        let manifest = manifest(for: note)
        let pages = manifest.pages.map { page in
            CanvasDocument(pageSize: page.size, template: page.template,
                           templateArtwork: page.template.background.flatMap { artwork(for: $0, noteID: note.id) },
                           id: page.id)
        }
        var defaultTemplate = manifest.coverTemplate
        if defaultTemplate.background != nil {
            defaultTemplate = PageTemplate.blank.on(defaultTemplate.paper)
        }
        let notebook = InkNotebook(pages: pages, defaultPageSize: manifest.defaultPageSize, defaultTemplate: defaultTemplate)
        notebooks[note.id] = notebook
        return notebook
    }

    /// The note's notebook if it has been opened this session, without creating one.
    public func existingNotebook(for noteID: UUID) -> InkNotebook? {
        notebooks[noteID]
    }

    // MARK: Saving

    /// Writes the open notebook's page order, sizes and templates to the note's manifest (and any new custom
    /// template backgrounds to its `templates/` folder) and mirrors its page count, cover template and
    /// modification date onto `note`. The note counts as modified when its pages changed or `inkChanged` is
    /// set; otherwise nothing is written.
    public func save(_ note: Note, inkChanged: Bool = false) {
        guard let notebook = notebooks[note.id] else { return }
        let old = manifest(for: note)
        var new = old
        new.defaultPageSize = notebook.defaultPageSize
        new.pages = notebook.pages.map { NoteManifest.Page(id: $0.id, size: $0.pageSize, template: $0.template) }
        guard inkChanged || !new.hasSameLayout(as: old) else { return }
        for page in notebook.pages {
            if let artwork = page.templateArtwork, artwork.id == page.template.background?.id {
                artworks[artwork.id] = artwork
            }
        }
        writeArtworks(of: new, noteID: note.id)
        new.modifiedAt = .now
        store(new, for: note)
    }

    /// Puts every page of the note on `template` (a built-in: it has no background), in its open notebook too.
    public func setTemplate(_ template: PageTemplate, of note: Note) {
        if let notebook = notebooks[note.id] {
            notebook.setTemplateForAllPages(template)
        }
        var manifest = manifest(for: note)
        guard manifest.pages.contains(where: { $0.template != template }) else {
            note.template = template
            return
        }
        for i in manifest.pages.indices {
            manifest.pages[i].template = template
        }
        manifest.modifiedAt = .now
        writeArtworks(of: manifest, noteID: note.id)
        store(manifest, for: note)
    }

    /// Starts a new note's package with one page of `size` on `template`.
    public func create(_ note: Note, size: PageSize, template: PageTemplate) {
        store(NoteManifest(size: size, template: template, createdAt: note.createdAt, modifiedAt: note.modifiedAt),
              for: note)
    }

    /// Gives `copy` the same pages, sizes and templates (with their backgrounds) as `original`.
    public func duplicate(_ original: Note, as copy: Note) {
        let manifest = manifest(for: original)
        for background in manifest.backgrounds {
            _ = artwork(for: background, noteID: original.id)
        }
        writeArtworks(of: manifest, noteID: copy.id)
        store(manifest.duplicated(at: copy.createdAt), for: copy)
    }

    /// Forgets the note's notebook and deletes its package, for a note deleted permanently.
    public func discard(noteID: UUID) {
        notebooks[noteID] = nil
        for background in manifests[noteID]?.backgrounds ?? [] {
            artworks[background.id] = nil
        }
        manifests[noteID] = nil
        try? FileManager.default.removeItem(at: NotePackage.url(for: noteID, in: library))
    }

    // MARK: Library

    /// Brings every note's page count, cover template and modification date in line with its manifest, and writes
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

    /// The decoded bytes of `background`, from memory or the note's `templates/` folder. Nil if the file is
    /// missing or unreadable; the page then shows its paper without the background.
    private func artwork(for background: TemplateBackground, noteID: UUID) -> TemplateArtwork? {
        if let artwork = artworks[background.id] {
            return artwork
        }
        let url = NotePackage.templateURL(for: background, noteID: noteID, in: library)
        guard let data = try? Data(contentsOf: url),
              let artwork = TemplateArtwork(id: background.id, kind: background.kind, data: data,
                                            pageIndex: background.pageIndex)
        else { return nil }
        artworks[background.id] = artwork
        return artwork
    }

    /// Makes the note's `templates/` folder hold exactly the backgrounds `manifest` uses: writes the ones it
    /// lacks (from memory) and removes the rest.
    private func writeArtworks(of manifest: NoteManifest, noteID: UUID) {
        let files = FileManager.default
        let folder = NotePackage.templatesURL(for: noteID, in: library)
        let backgrounds = manifest.backgrounds
        var wanted = Set<String>()
        for background in backgrounds {
            let url = NotePackage.templateURL(for: background, noteID: noteID, in: library)
            wanted.insert(url.lastPathComponent)
            guard !files.fileExists(atPath: url.path), let artwork = artworks[background.id] else { continue }
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            try? artwork.data.write(to: url, options: .atomic)
        }
        guard let existing = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in existing where !wanted.contains(url.lastPathComponent) {
            try? files.removeItem(at: url)
        }
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
        if note.template != manifest.coverTemplate {
            note.template = manifest.coverTemplate
        }
        if note.modifiedAt != manifest.modifiedAt {
            note.modifiedAt = manifest.modifiedAt
        }
    }

    private static func fallbackManifest(for note: Note) -> NoteManifest {
        NoteManifest(pageCount: note.pageCount, size: .localeDefault, template: note.template,
                     createdAt: note.createdAt, modifiedAt: note.modifiedAt)
    }
}

public extension PageSize {
    /// Letter where US paper sizes are used, A4 everywhere else.
    static var localeDefault: PageSize {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }
}
