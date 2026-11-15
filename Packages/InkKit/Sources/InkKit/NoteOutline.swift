import Foundation
import PDFKit

/// A note's bookmarks and outline: the pages marked to come back to, and a table of contents of named
/// entries, each going to a page. It belongs to the notebook (`InkNotebook.outline`), and the host saves it
/// with the note (Nota keeps it in the note's manifest).
///
/// Entries are either the user's own (`Entry.Source.custom`) or brought in with a PDF's own outline
/// (`.pdf`, nested by `level`), so the outline panel shows both. Entries and bookmarks only refer to pages
/// by id: a page that's deleted drops out of the panel (`resolved(in:)`), and the host drops it when it saves
/// (`pruned(keeping:)`).
public struct NoteOutline: Codable, Equatable, Sendable {
    public typealias Entry = NoteOutlineEntry

    /// Bookmarked pages, in the order they were bookmarked.
    public var bookmarks: [UUID]
    /// The outline's entries in order: the user's own and those from PDFs.
    public var entries: [Entry]

    public init(bookmarks: [UUID] = [], entries: [Entry] = []) {
        var seen = Set<UUID>()
        self.bookmarks = bookmarks.filter { seen.insert($0).inserted }
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case bookmarks, entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bookmarks: c.decodeIfPresent([UUID].self, forKey: .bookmarks) ?? [],
                      entries: c.decodeIfPresent([Entry].self, forKey: .entries) ?? [])
    }

    public var isEmpty: Bool {
        bookmarks.isEmpty && entries.isEmpty
    }

    /// The user's own entries, in order.
    public var customEntries: [Entry] {
        entries.filter { $0.source == .custom }
    }

    /// The entries from PDFs, in order.
    public var pdfEntries: [Entry] {
        entries.filter { $0.source == .pdf }
    }

    /// The outline without bookmarks or entries for pages that aren't in `pageIDs`.
    public func pruned(keeping pageIDs: some Sequence<UUID>) -> NoteOutline {
        let pages = Set(pageIDs)
        return NoteOutline(bookmarks: bookmarks.filter(pages.contains), entries: entries.filter { pages.contains($0.pageID) })
    }

    /// The outline with every page id `map` names swapped for its new id, for a copy of the note whose
    /// pages have fresh ids. Pages `map` doesn't name are dropped.
    public func remapped(_ map: [UUID: UUID]) -> NoteOutline {
        NoteOutline(bookmarks: bookmarks.compactMap { map[$0] },
                    entries: entries.compactMap { entry in
                        map[entry.pageID].map { page in
                            Entry(title: entry.title, pageID: page, level: entry.level, source: entry.source)
                        }
                    })
    }

    // MARK: What the panel shows

    /// A bookmark or entry with the index of its page in the notebook.
    public struct Item<Value>: Identifiable {
        public let value: Value
        public let pageIndex: Int
        public let id: UUID
    }

    /// The bookmarked pages that are in `pages`, in page order.
    public func bookmarkedPages(in pages: [UUID]) -> [Item<UUID>] {
        let marked = Set(bookmarks)
        return pages.enumerated().filter { marked.contains($0.element) }
            .map { Item(value: $0.element, pageIndex: $0.offset, id: $0.element) }
    }

    /// The entries whose pages are in `pages`, in outline order, with their page indices.
    public func resolved(_ entries: [Entry], in pages: [UUID]) -> [Item<Entry>] {
        let index = Dictionary(pages.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return entries.compactMap { entry in index[entry.pageID].map { Item(value: entry, pageIndex: $0, id: entry.id) } }
    }
}

/// An entry in a note's outline (`NoteOutline.Entry`): a title and the page it goes to.
public struct NoteOutlineEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Added by the user.
        case custom
        /// Read from an imported PDF's outline.
        case pdf
    }

    public var id: UUID
    public var title: String
    /// The page it goes to (`CanvasDocument.id`).
    public var pageID: UUID
    /// How deeply it's nested, from 0. The user's own entries are all at 0.
    public var level: Int
    public var source: Source

    public init(id: UUID = UUID(), title: String, pageID: UUID, level: Int = 0, source: Source = .custom) {
        self.id = id
        self.title = title
        self.pageID = pageID
        self.level = max(0, level)
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, pageID = "page", level, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pageID = try c.decode(UUID.self, forKey: .pageID)
        level = max(0, (try? c.decodeIfPresent(Int.self, forKey: .level)) ?? 0)
        // An unknown source (from a newer app) is shown like the user's own.
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap(Source.init(rawValue:)) ?? .custom
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(pageID, forKey: .pageID)
        if level > 0 {
            try c.encode(level, forKey: .level)
        }
        try c.encode(source, forKey: .source)
    }
}

// MARK: - PDF outlines

public extension NoteOutline {
    /// The outline (table of contents) of `document` as entries, for a note whose pages show the PDF's pages:
    /// `pageIDs[i]` is the note page showing PDF page `i`. Entries are in the PDF's order, nested by `level`,
    /// and ones whose destination isn't one of those pages are left out (their children are kept, a level up).
    static func entries(fromOutlineOf document: PDFDocument, pageIDs: [UUID]) -> [Entry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [Entry] = []
        func walk(_ item: PDFOutline, level: Int) {
            for i in 0 ..< item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                var childLevel = level
                if let page = child.destination?.page {
                    let index = document.index(for: page)
                    if pageIDs.indices.contains(index) {
                        let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        entries.append(Entry(title: title, pageID: pageIDs[index], level: level, source: .pdf))
                        childLevel = level + 1
                    }
                }
                walk(child, level: childLevel)
            }
        }
        walk(root, level: 0)
        return entries
    }
}

// MARK: - The notebook's outline

public extension InkNotebook {
    func isBookmarked(_ pageID: CanvasDocument.ID) -> Bool {
        outline.bookmarks.contains(pageID)
    }

    /// Bookmarks the page, or removes its bookmark.
    func toggleBookmark(_ pageID: CanvasDocument.ID) {
        guard index(of: pageID) != nil || isBookmarked(pageID) else { return }
        if isBookmarked(pageID) {
            outline.bookmarks.removeAll { $0 == pageID }
        } else {
            outline.bookmarks.append(pageID)
        }
    }

    /// Adds one of the user's own entries going to `pageID`, after the others, and returns it. A blank title
    /// is called after the page's number.
    @discardableResult
    func addOutlineEntry(title: String, pageID: CanvasDocument.ID) -> NoteOutline.Entry? {
        guard let index = index(of: pageID) else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = NoteOutline.Entry(title: trimmed.isEmpty ? "Page \(index + 1)" : trimmed, pageID: pageID)
        outline.entries.append(entry)
        return entry
    }

    func renameOutlineEntry(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = outline.entries.firstIndex(where: { $0.id == id }),
              outline.entries[i].title != trimmed else { return }
        outline.entries[i].title = trimmed
    }

    func removeOutlineEntry(_ id: UUID) {
        outline.entries.removeAll { $0.id == id }
    }

    /// Reorders the user's own entries (offsets into `outline.customEntries`), like `Array.move`. Entries
    /// from PDFs stay where they are.
    func moveCustomOutlineEntries(fromOffsets source: IndexSet, toOffset destination: Int) {
        var custom = outline.customEntries
        custom.move(fromOffsets: source, toOffset: destination)
        var next = custom.makeIterator()
        outline.entries = outline.entries.map { $0.source == .custom ? next.next() ?? $0 : $0 }
    }

    /// Replaces the outline's PDF entries with `document`'s outline, for pages `pageIDs` showing its pages in
    /// order (see `NoteOutline.entries(fromOutlineOf:pageIDs:)`). The user's own entries are kept, before them.
    func importPDFOutline(from document: PDFDocument, pageIDs: [CanvasDocument.ID]) {
        let imported = NoteOutline.entries(fromOutlineOf: document, pageIDs: pageIDs)
        outline.entries = outline.customEntries + imported
    }
}

// MARK: - Going back after following a link

/// Where following links has been, so Back can return: the pages a link was followed from, most recent last.
/// Pages that no longer exist are skipped when going back.
public struct LinkHistory: Equatable, Sendable {
    /// How many steps are kept.
    public static let limit = 50

    public private(set) var pageIDs: [UUID] = []

    public init(pageIDs: [UUID] = []) {
        self.pageIDs = Array(pageIDs.suffix(Self.limit))
    }

    public var isEmpty: Bool {
        pageIDs.isEmpty
    }

    /// Records that a link was followed from `pageID`.
    public mutating func push(_ pageID: UUID) {
        pageIDs.append(pageID)
        if pageIDs.count > Self.limit {
            pageIDs.removeFirst(pageIDs.count - Self.limit)
        }
    }

    /// The most recent page that `exists`, removing it and anything more recent that doesn't.
    public mutating func pop(where exists: (UUID) -> Bool) -> UUID? {
        while let last = pageIDs.popLast() {
            if exists(last) {
                return last
            }
        }
        return nil
    }

    /// The page Back would go to, if any (without going there).
    public func peek(where exists: (UUID) -> Bool) -> UUID? {
        pageIDs.last(where: exists)
    }
}
