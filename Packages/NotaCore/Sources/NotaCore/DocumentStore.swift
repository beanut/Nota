import Combine
import Foundation
import InkKit
import Observation
import os
import SwiftData

/// Reads and writes each note's `.nota` package (see `NotePackage`) and keeps the notebooks of recently
/// opened notes in memory, so every window showing a note shares one notebook.
///
/// **Loading.** A note's pages are read only when it's opened (`notebook(for:)`): the manifest and each
/// page's `.ink` file and objects file (`pages/<page id>.json`, if it has objects) are read and decoded off
/// the main actor. Up to `capacity` notes stay loaded; past that,
/// the least recently used note that no editor is showing is saved and dropped.
///
/// **Saving.** The store watches every loaded page and autosaves a note `autosaveDelay` after its last
/// change, writing only the pages whose ink or objects changed since they were last saved, then the
/// manifest. A page whose last object is removed has its objects file removed. Editors
/// also save when they close (`endEditing`), and the app calls `saveAll()` when it goes to the background.
/// Writes run in order on a background queue (`flush()` waits for them); each file is replaced atomically
/// and the manifest goes last, so a save cut short by the app being killed leaves the note as it was before
/// that save (see `PackageFiles`).
///
/// A page file that can't be read (damaged, or from a newer app) is set aside in the package rather than
/// overwritten, and the page opens without that ink or those objects.
@Observable
@MainActor
public final class DocumentStore {
    /// How many notes stay loaded when no editor shows them.
    public let capacity: Int
    /// How long after a note's last change it's saved.
    public let autosaveDelay: Duration

    @ObservationIgnored private let library: URL
    @ObservationIgnored private let files: PackageFiles
    @ObservationIgnored private let queue = PackageQueue()
    /// Notes deleted permanently; queued writes for them are skipped so their packages don't come back.
    @ObservationIgnored private let tombstones = NoteIDSet()
    /// Notes whose last save failed part-way, so their next save writes everything again.
    @ObservationIgnored private let failedSaves = NoteIDSet()

    @ObservationIgnored private var open: [UUID: OpenNote] = [:]
    @ObservationIgnored private var loading: [UUID: Task<InkNotebook, Never>] = [:]
    /// Loaded notes, least recently used first.
    @ObservationIgnored private var recency: [UUID] = []
    /// The last manifest read or written for each note.
    @ObservationIgnored private var manifests: [UUID: NoteManifest] = [:]
    /// Custom template backgrounds read or saved this session, by background id.
    @ObservationIgnored private var artworks: [UUID: TemplateArtwork] = [:]

    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var lastChange = ContinuousClock.now
    @ObservationIgnored private var autosave: Task<Void, Never>?

    /// A loaded note: its notebook, and each page's revisions when its ink and objects were last written.
    @MainActor
    private final class OpenNote {
        let note: Note
        let notebook: InkNotebook
        var savedRevisions: [UUID: Int]
        var savedObjectRevisions: [UUID: Int]
        /// Editors showing the note; it's never dropped while there are any.
        var editors = 0
        /// Set when a save failed, so the next one writes every page.
        var needsFullSave = false
        var pagesObservation: AnyCancellable?

        init(note: Note, notebook: InkNotebook) {
            self.note = note
            self.notebook = notebook
            savedRevisions = Self.revisions(of: notebook, \.revision)
            savedObjectRevisions = Self.revisions(of: notebook, \.objectsRevision)
        }

        static func revisions(of notebook: InkNotebook, _ revision: KeyPath<CanvasDocument, Int>) -> [UUID: Int] {
            Dictionary(uniqueKeysWithValues: notebook.pages.map { ($0.id, $0[keyPath: revision]) })
        }
    }

    public init(library: URL = NotePackage.libraryURL, capacity: Int = 8, autosaveDelay: Duration = .seconds(1),
                files: PackageFiles = PackageFiles()) {
        self.library = library
        self.capacity = max(1, capacity)
        self.autosaveDelay = autosaveDelay
        self.files = files
    }

    // MARK: Opening notes

    /// The note's notebook, read from its package the first time it's asked for. A note without a manifest
    /// (a sample note) gets `pageCount` blank pages of the locale's default size on its template.
    public func notebook(for note: Note) async -> InkNotebook {
        if let entry = open[note.id] {
            touch(note.id)
            return entry.notebook
        }
        if let task = loading[note.id] {
            return await task.value
        }
        let task = Task { await load(note) }
        loading[note.id] = task
        return await task.value
    }

    /// The note's notebook if it's loaded, without loading it.
    public func existingNotebook(for noteID: UUID) -> InkNotebook? {
        open[noteID]?.notebook
    }

    /// The note's notebook, kept loaded until the matching `endEditing(_:)`.
    public func beginEditing(_ note: Note) async -> InkNotebook {
        let notebook = await notebook(for: note)
        open[note.id]?.editors += 1
        return notebook
    }

    /// Saves the note (its title too) and lets it be dropped from memory once no other editor shows it.
    public func endEditing(_ note: Note) {
        guard let entry = open[note.id] else { return }
        entry.editors = max(0, entry.editors - 1)
        save(noteID: note.id)
        evictIfNeeded()
    }

    /// True while the note's pages are in memory.
    public func isLoaded(_ noteID: UUID) -> Bool {
        open[noteID] != nil
    }

    // MARK: Saving

    /// Saves the note now if it's loaded and anything about it changed since its last save.
    public func save(_ note: Note) {
        save(noteID: note.id)
    }

    /// Saves every loaded note that changed, for the app going to the background. Follow with `flush()` to
    /// wait for the writes.
    public func saveAll() {
        autosave?.cancel()
        autosave = nil
        for id in open.keys {
            save(noteID: id)
        }
        dirty.removeAll()
    }

    /// Waits until every save, copy and removal queued so far is on disk.
    public func flush() async {
        await queue.drain()
    }

    // MARK: Library changes

    /// Starts a new note's package with one page of `size` on `template`.
    public func create(_ note: Note, size: PageSize, template: PageTemplate) {
        let manifest = NoteManifest(title: note.title, size: size, template: template,
                                    createdAt: note.createdAt, modifiedAt: note.modifiedAt)
        store(manifest, for: note)
    }

    /// Puts every page of the note on `template` (a built-in: it has no background), in its open notebook too.
    public func setTemplate(_ template: PageTemplate, of note: Note) {
        var manifest = manifest(for: note)
        open[note.id]?.notebook.setTemplateForAllPages(template)
        guard manifest.pages.contains(where: { $0.template != template }) else {
            note.template = template
            return
        }
        for i in manifest.pages.indices {
            manifest.pages[i].template = template
        }
        manifest.modifiedAt = .now
        store(manifest, for: note)
    }

    /// Gives `copy` the same pages (with their ink), sizes and templates (with their backgrounds) as
    /// `original`, which is saved first if it's loaded.
    public func duplicate(_ original: Note, as copy: Note) {
        save(noteID: original.id)
        let source = manifest(for: original)
        var manifest = source.duplicated(title: copy.title, at: copy.createdAt)
        manifest.formatVersion = NoteManifest.currentFormatVersion
        manifests[copy.id] = manifest
        mirror(manifest, onto: copy)
        let pageIDs = zip(source.pages, manifest.pages).map { (from: $0.id, to: $1.id) }
        let artworkData = artworkData(for: source)
        let job = CopyJob(from: original.id, to: copy.id, pageIDs: pageIDs, manifest: manifest, artworks: artworkData)
        let library = library, files = files, tombstones = tombstones
        queue.enqueue {
            try? Self.perform(job, in: library, files: files, tombstones: tombstones)
        }
    }

    /// Adds `pages` to the end of `note`, loading it first if it isn't loaded, and saves it. For pages
    /// copied or moved from another note's page sidebar: pass copies (`CanvasDocument.copy()`), never
    /// pages that are still in another notebook. Their ink, sizes, templates and backgrounds go with them.
    public func addPages(_ pages: [CanvasDocument], to note: Note) async {
        guard !pages.isEmpty else { return }
        let notebook = await notebook(for: note)
        notebook.appendPages(pages)
        save(noteID: note.id)
        evictIfNeeded()
    }

    /// Forgets the note and deletes its package, for a note deleted permanently.
    public func discard(noteID: UUID) {
        if let entry = open.removeValue(forKey: noteID) {
            stopObserving(entry)
        }
        recency.removeAll { $0 == noteID }
        dirty.remove(noteID)
        for background in manifests[noteID]?.backgrounds ?? [] {
            artworks[background.id] = nil
        }
        manifests[noteID] = nil
        tombstones.insert(noteID)
        let url = NotePackage.url(for: noteID, in: library), files = files
        queue.enqueue {
            try? files.remove(url)
        }
    }

    // MARK: Library index

    /// Brings every note's page count, cover template and modification date in line with its manifest,
    /// copies its title into the manifest, and writes a manifest for any note that has none yet (sample
    /// notes), so from then on the manifest is what the library shows. Reads files off the main actor.
    public func reconcile(_ notes: [Note]) async {
        let library = library, files = files
        let wanted = notes.filter { manifests[$0.id] == nil }.map { note in
            (id: note.id, title: note.title, fallback: Self.fallbackManifest(for: note))
        }
        let found: [UUID: NoteManifest] = await queue.perform {
            var found: [UUID: NoteManifest] = [:]
            for (id, title, fallback) in wanted {
                let url = NotePackage.manifestURL(for: id, in: library)
                var manifest = Self.readManifest(at: url, files: files) ?? fallback
                if manifest.title != title || manifest.formatVersion != NoteManifest.currentFormatVersion
                    || !FileManager.default.fileExists(atPath: url.path) {
                    manifest.title = title
                    manifest.formatVersion = NoteManifest.currentFormatVersion
                    try? files.write(manifest.encoded(), to: url)
                }
                found[id] = manifest
            }
            return found
        }
        for note in notes {
            // A note opened or saved meanwhile has a newer manifest in memory.
            guard manifests[note.id] == nil, let manifest = found[note.id] else { continue }
            manifests[note.id] = manifest
            mirror(manifest, onto: note)
        }
    }

    /// Adds a `Note` to `context` for every package in the library that has none, from its manifest: its
    /// title, dates, page count and cover template. For a library whose SwiftData store was lost or reset;
    /// folders, favourites and tints aren't in packages, so rebuilt notes start without them. Returns the
    /// notes added.
    @discardableResult
    public func rebuildIndex(in context: ModelContext) async -> [Note] {
        let library = library, files = files, tombstones = tombstones
        let packages: [(id: UUID, manifest: NoteManifest)] = await queue.perform {
            let contents = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
            return contents.compactMap { url in
                guard let id = NotePackage.noteID(ofPackage: url), !tombstones.contains(id),
                      let manifest = Self.readManifest(at: NotePackage.manifestURL(for: id, in: library), files: files)
                else { return nil }
                return (id, manifest)
            }
        }
        let known = Set(((try? context.fetch(FetchDescriptor<Note>())) ?? []).map(\.id))
        var added: [Note] = []
        for (id, manifest) in packages where !known.contains(id) {
            let note = Note(title: manifest.title ?? String(localized: "Untitled Note"),
                            pageCount: manifest.pageCount, modifiedAt: manifest.modifiedAt,
                            template: manifest.coverTemplate, id: id)
            note.createdAt = manifest.createdAt
            context.insert(note)
            manifests[id] = manifest
            added.append(note)
        }
        return added
    }

    // MARK: Loading

    private func load(_ note: Note) async -> InkNotebook {
        let id = note.id
        let library = library, files = files
        let cached = manifests[id]
        let fallback = Self.fallbackManifest(for: note)
        let knownArtworks = Set(artworks.keys)
        let package = await queue.perform {
            Self.readPackage(noteID: id, cachedManifest: cached, fallback: fallback, knownArtworks: knownArtworks,
                             in: library, files: files)
        }
        for (backgroundID, data) in package.artworks {
            guard let background = package.manifest.backgrounds.first(where: { $0.id == backgroundID }),
                  let artwork = TemplateArtwork(id: background.id, kind: background.kind, data: data,
                                                pageIndex: background.pageIndex)
            else { continue }
            artworks[backgroundID] = artwork
        }
        let manifest = package.manifest
        let pages = manifest.pages.map { page in
            let document = CanvasDocument(file: package.ink[page.id] ?? InkPageFile(pageID: page.id),
                                          objects: package.objects[page.id], pageSize: page.size)
            document.setTemplate(page.template, artwork: page.template.background.flatMap { artworks[$0.id] })
            return document
        }
        var defaultTemplate = manifest.coverTemplate
        if defaultTemplate.background != nil {
            defaultTemplate = PageTemplate.blank.on(defaultTemplate.paper)
        }
        let notebook = InkNotebook(pages: pages, defaultPageSize: manifest.defaultPageSize, defaultTemplate: defaultTemplate)
        loading[id] = nil
        // Deleted while it loaded, or opened by another caller first (can't happen, but cheap to check).
        guard !tombstones.contains(id) else { return notebook }
        if let entry = open[id] {
            return entry.notebook
        }
        if manifests[id] == nil {
            manifests[id] = manifest
        }
        let entry = OpenNote(note: note, notebook: notebook)
        open[id] = entry
        observe(entry)
        touch(id)
        evictIfNeeded()
        return notebook
    }

    private func touch(_ id: UUID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    /// Drops the least recently used notes no editor shows, past `capacity`. The most recent one stays.
    private func evictIfNeeded() {
        while open.count > capacity,
              let id = recency.dropLast().first(where: { (open[$0]?.editors ?? 0) == 0 }),
              let entry = open[id] {
            save(noteID: id)
            stopObserving(entry)
            open[id] = nil
            dirty.remove(id)
            recency.removeAll { $0 == id }
        }
    }

    // MARK: Watching for changes

    private func observe(_ entry: OpenNote) {
        let id = entry.note.id
        observe(entry.notebook.pages, of: id)
        // Pages added, removed or reordered; new pages are watched from then on.
        entry.pagesObservation = entry.notebook.$pages.dropFirst().sink { [weak self] pages in
            self?.observe(pages, of: id)
            self?.changed(id)
        }
    }

    private func observe(_ pages: [CanvasDocument], of noteID: UUID) {
        for page in pages {
            page.observeChanges(self) { [weak self] in self?.changed(noteID) }
        }
    }

    private func stopObserving(_ entry: OpenNote) {
        entry.pagesObservation = nil
        for page in entry.notebook.pages {
            page.stopObservingChanges(self)
        }
    }

    /// Called on every committed edit, so it only notes the change; the save happens once the note is quiet.
    private func changed(_ noteID: UUID) {
        dirty.insert(noteID)
        lastChange = .now
        guard autosave == nil else { return }
        autosave = Task { [weak self] in
            while true {
                guard let self else { return }
                let wait = autosaveDelay - (ContinuousClock.now - lastChange)
                guard wait > .zero else { break }
                try? await Task.sleep(for: wait)
                if Task.isCancelled {
                    return
                }
            }
            self?.autosaveNow()
        }
    }

    private func autosaveNow() {
        autosave = nil
        let ids = dirty
        dirty.removeAll()
        for id in ids {
            save(noteID: id)
        }
    }

    // MARK: Writing

    /// Queues a write of the note's changed pages and manifest, if anything changed: ink, objects, page
    /// layout or title. Ink, object or layout changes also make it the note's modification date.
    private func save(noteID: UUID) {
        guard let entry = open[noteID] else { return }
        if failedSaves.remove(noteID) {
            entry.needsFullSave = true
        }
        let note = entry.note, notebook = entry.notebook
        let old = manifest(for: note)
        var new = old
        new.title = note.title
        new.defaultPageSize = notebook.defaultPageSize
        new.pages = notebook.pages.map { NoteManifest.Page(id: $0.id, size: $0.pageSize, template: $0.template) }

        var pageFiles: [InkPageFile] = []
        for page in notebook.pages {
            let saved = entry.savedRevisions[page.id]
            let changed = entry.needsFullSave || (saved.map { $0 != page.revision } ?? (page.strokeCount > 0))
            if changed {
                pageFiles.append(page.inkFile)
            }
        }
        var objectFiles: [PageObjectsFile] = []
        for page in notebook.pages {
            let saved = entry.savedObjectRevisions[page.id]
            let changed = entry.needsFullSave || (saved.map { $0 != page.objectsRevision } ?? (page.objectCount > 0))
            if changed {
                objectFiles.append(page.objectsFile)
            }
        }
        let inkChanged = !pageFiles.isEmpty || !objectFiles.isEmpty
        let layoutChanged = !new.hasSameLayout(as: old)
        guard inkChanged || layoutChanged || new.title != old.title || entry.needsFullSave else { return }

        if inkChanged || layoutChanged {
            new.modifiedAt = .now
        }
        for page in notebook.pages {
            if let artwork = page.templateArtwork, artwork.id == page.template.background?.id {
                artworks[artwork.id] = artwork
            }
        }
        entry.savedRevisions = OpenNote.revisions(of: notebook, \.revision)
        entry.savedObjectRevisions = OpenNote.revisions(of: notebook, \.objectsRevision)
        entry.needsFullSave = false
        store(new, for: note, pageFiles: pageFiles, objectFiles: objectFiles)
    }

    private func store(_ manifest: NoteManifest, for note: Note, pageFiles: [InkPageFile] = [],
                       objectFiles: [PageObjectsFile] = []) {
        var manifest = manifest
        manifest.formatVersion = NoteManifest.currentFormatVersion
        manifests[note.id] = manifest
        mirror(manifest, onto: note)
        let job = SaveJob(noteID: note.id, manifest: manifest, pageFiles: pageFiles, objectFiles: objectFiles,
                          artworks: artworkData(for: manifest))
        let library = library, files = files, tombstones = tombstones
        let failedSaves = failedSaves
        queue.enqueue {
            do {
                try Self.perform(job, in: library, files: files, tombstones: tombstones)
            } catch {
                // The disk may hold some of the save and not the rest; the next save writes it all again.
                Logger.documents.error("Saving note \(job.noteID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failedSaves.insert(job.noteID)
            }
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

    /// The bytes of the manifest's backgrounds that are in memory, for writing any the package lacks.
    private func artworkData(for manifest: NoteManifest) -> [UUID: Data] {
        var data: [UUID: Data] = [:]
        for background in manifest.backgrounds {
            data[background.id] = artworks[background.id]?.data
        }
        return data
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
        NoteManifest(title: note.title, pageCount: note.pageCount, size: .localeDefault, template: note.template,
                     createdAt: note.createdAt, modifiedAt: note.modifiedAt)
    }
}

// MARK: - Package reading and writing (off the main actor)

extension DocumentStore {
    struct LoadedPackage: Sendable {
        var manifest: NoteManifest
        /// Each page's ink, for pages with a readable file.
        var ink: [UUID: InkPageFile]
        /// Each page's objects, for pages with a readable objects file.
        var objects: [UUID: PageObjectsFile]
        /// Bytes of backgrounds that weren't in memory yet.
        var artworks: [UUID: Data]
    }

    struct SaveJob: Sendable {
        let noteID: UUID
        let manifest: NoteManifest
        /// Pages whose ink changed since they were last written.
        let pageFiles: [InkPageFile]
        /// Pages whose objects changed since they were last written; an empty one removes the page's file.
        let objectFiles: [PageObjectsFile]
        /// Background bytes in memory, for any the package lacks.
        let artworks: [UUID: Data]
    }

    struct CopyJob: Sendable {
        let from: UUID
        let to: UUID
        /// Each page of the original and the page that copies it.
        let pageIDs: [(from: UUID, to: UUID)]
        let manifest: NoteManifest
        let artworks: [UUID: Data]
    }

    /// The manifest at `url`; nil if there's none. One that exists but can't be read is set aside first,
    /// so the manifest written in its place doesn't destroy it.
    nonisolated static func readManifest(at url: URL, files: PackageFiles) -> NoteManifest? {
        if let manifest = NoteManifest.read(from: url) {
            return manifest
        }
        if FileManager.default.fileExists(atPath: url.path) {
            files.setAside(url)
        }
        return nil
    }

    nonisolated static func readPackage(noteID: UUID, cachedManifest: NoteManifest?, fallback: NoteManifest,
                                        knownArtworks: Set<UUID>, in library: URL, files: PackageFiles) -> LoadedPackage {
        let manifest = cachedManifest
            ?? readManifest(at: NotePackage.manifestURL(for: noteID, in: library), files: files)
            ?? fallback
        var ink: [UUID: InkPageFile] = [:]
        var objects: [UUID: PageObjectsFile] = [:]
        for page in manifest.pages {
            let objectsURL = NotePackage.objectsURL(for: page.id, noteID: noteID, in: library)
            if let data = try? Data(contentsOf: objectsURL) {
                do {
                    var file = try PageObjectsFile(data: data)
                    file.pageID = page.id
                    objects[page.id] = file
                } catch {
                    Logger.documents
                        .error(
                            "Setting aside unreadable objects \(objectsURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                        )
                    files.setAside(objectsURL)
                }
            }
            let url = NotePackage.pageURL(for: page.id, noteID: noteID, in: library)
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                var file = try InkPageFile(data: data)
                file.pageID = page.id
                ink[page.id] = file
            } catch {
                Logger.documents
                    .error(
                        "Setting aside unreadable page \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                files.setAside(url)
            }
        }
        var artworks: [UUID: Data] = [:]
        for background in manifest.backgrounds where !knownArtworks.contains(background.id) {
            let url = NotePackage.templateURL(for: background, noteID: noteID, in: library)
            artworks[background.id] = try? Data(contentsOf: url)
        }
        return LoadedPackage(manifest: manifest, ink: ink, objects: objects, artworks: artworks)
    }

    /// Writes changed pages (ink, then objects), then missing backgrounds, then the manifest, then removes what
    /// it no longer lists.
    nonisolated static func perform(_ job: SaveJob, in library: URL, files: PackageFiles, tombstones: NoteIDSet) throws {
        guard !tombstones.contains(job.noteID) else { return }
        let id = job.noteID
        removeTemporaryFiles(of: id, in: library, files: files)
        for file in job.pageFiles {
            try files.write(file.encoded(), to: NotePackage.pageURL(for: file.pageID, noteID: id, in: library))
        }
        for file in job.objectFiles {
            let url = NotePackage.objectsURL(for: file.pageID, noteID: id, in: library)
            if file.isEmpty {
                try files.remove(url)
            } else {
                try files.write(file.encoded(), to: url)
            }
        }
        for background in job.manifest.backgrounds {
            let url = NotePackage.templateURL(for: background, noteID: id, in: library)
            guard !FileManager.default.fileExists(atPath: url.path), let data = job.artworks[background.id] else { continue }
            try files.write(data, to: url)
        }
        try files.write(job.manifest.encoded(), to: NotePackage.manifestURL(for: id, in: library))
        try removeUnlisted(by: job.manifest, noteID: id, in: library, files: files)
    }

    /// Copies the original's page files and backgrounds into the copy's package, then writes its manifest.
    nonisolated static func perform(_ job: CopyJob, in library: URL, files: PackageFiles, tombstones: NoteIDSet) throws {
        guard !tombstones.contains(job.to) else { return }
        let fileManager = FileManager.default
        for (from, to) in job.pageIDs {
            let source = NotePackage.pageURL(for: from, noteID: job.from, in: library)
            if fileManager.fileExists(atPath: source.path) {
                try files.copy(source, to: NotePackage.pageURL(for: to, noteID: job.to, in: library))
            }
            // Objects: the copy's file names its own page.
            let objectsSource = NotePackage.objectsURL(for: from, noteID: job.from, in: library)
            if let data = try? Data(contentsOf: objectsSource), var file = try? PageObjectsFile(data: data) {
                file.pageID = to
                try files.write(file.encoded(), to: NotePackage.objectsURL(for: to, noteID: job.to, in: library))
            }
        }
        for background in job.manifest.backgrounds {
            let source = NotePackage.templateURL(for: background, noteID: job.from, in: library)
            let target = NotePackage.templateURL(for: background, noteID: job.to, in: library)
            if fileManager.fileExists(atPath: source.path) {
                try files.copy(source, to: target)
            } else if let data = job.artworks[background.id] {
                try files.write(data, to: target)
            }
        }
        try files.write(job.manifest.encoded(), to: NotePackage.manifestURL(for: job.to, in: library))
    }

    private nonisolated static func removeTemporaryFiles(of noteID: UUID, in library: URL, files: PackageFiles) {
        files.removeTemporaryFiles(in: NotePackage.url(for: noteID, in: library))
        files.removeTemporaryFiles(in: NotePackage.pagesURL(for: noteID, in: library))
        files.removeTemporaryFiles(in: NotePackage.templatesURL(for: noteID, in: library))
    }

    /// Removes page files (ink and objects) for pages the manifest no longer has, and backgrounds no page
    /// uses. Files set aside as unreadable are kept.
    private nonisolated static func removeUnlisted(by manifest: NoteManifest, noteID: UUID, in library: URL,
                                                   files: PackageFiles) throws {
        let fileManager = FileManager.default
        let pageIDs = Set(manifest.pages.map(\.id.uuidString))
        let pageExtensions: Set = [InkPageFile.fileExtension, PageObjectsFile.fileExtension]
        let pagesFolder = NotePackage.pagesURL(for: noteID, in: library)
        for url in (try? fileManager.contentsOfDirectory(at: pagesFolder, includingPropertiesForKeys: nil)) ?? []
            where pageExtensions.contains(url.pathExtension) && !PackageFiles.isTemporary(url)
            && !pageIDs.contains(url.deletingPathExtension().lastPathComponent) {
            try files.remove(url)
        }
        let backgrounds = Set(manifest.backgrounds.map {
            NotePackage.templateURL(for: $0, noteID: noteID, in: library).lastPathComponent
        })
        let templatesFolder = NotePackage.templatesURL(for: noteID, in: library)
        for url in (try? fileManager.contentsOfDirectory(at: templatesFolder, includingPropertiesForKeys: nil)) ?? []
            where !backgrounds.contains(url.lastPathComponent) && !PackageFiles.isTemporary(url) && !url.lastPathComponent
            .contains(".damaged-") {
            try files.remove(url)
        }
    }
}

// MARK: - Support

/// Runs package reads and writes one at a time, in the order they were queued, off the main actor, so a
/// read always sees every write queued before it.
@MainActor
final class PackageQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ job: @escaping @Sendable () -> Void) {
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            job()
        }
    }

    func perform<T: Sendable>(_ job: @escaping @Sendable () -> T) async -> T {
        let previous = tail
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            return job()
        }
        tail = Task.detached { _ = await task.value }
        return await task.value
    }

    /// Waits for everything queued, including work queued while waiting.
    func drain() async {
        while let current = tail {
            await current.value
            if tail == current {
                return
            }
        }
    }
}

/// A set of note ids shared between the main actor and the write queue.
final class NoteIDSet: Sendable {
    private let ids = OSAllocatedUnfairLock(initialState: Set<UUID>())

    func insert(_ id: UUID) {
        ids.withLock { _ = $0.insert(id) }
    }

    func contains(_ id: UUID) -> Bool {
        ids.withLock { $0.contains(id) }
    }

    /// Removes `id`; true if it was there.
    func remove(_ id: UUID) -> Bool {
        ids.withLock { $0.remove(id) != nil }
    }
}

extension Logger {
    static let documents = Logger(subsystem: "com.bernard.nota", category: "documents")
}

public extension PageSize {
    /// Letter where US paper sizes are used, A4 everywhere else.
    static var localeDefault: PageSize {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }
}
