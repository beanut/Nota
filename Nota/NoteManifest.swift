import Foundation
import InkKit

/// What a note package records about its pages, kept as `manifest.json` in the note's `.nota` directory:
/// the page order and each page's size and paper, the size new pages get, and when the note last changed.
///
/// The manifest is the source of truth for a note's page count and modification date; the SwiftData
/// `Note` mirrors them for the library. Ink is not stored yet (NOT-6 adds page files alongside it).
struct NoteManifest: Codable, Equatable {
    static let currentFormatVersion = 1

    struct Page: Codable, Equatable {
        var id: UUID
        var size: PageSize
        var paper: PaperStyle
    }

    var formatVersion = Self.currentFormatVersion
    var pages: [Page]
    /// The size new pages get when there's no neighbouring page to copy, and the size "Use … for All
    /// Pages" last applied.
    var defaultPageSize: PageSize
    var createdAt: Date
    var modifiedAt: Date

    /// A manifest of `pageCount` blank pages (at least one) of `size` and `paper`.
    init(pageCount: Int = 1, size: PageSize, paper: PaperStyle, createdAt: Date = .now, modifiedAt: Date = .now) {
        pages = (0 ..< max(1, pageCount)).map { _ in Page(id: UUID(), size: size, paper: paper) }
        defaultPageSize = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    var pageCount: Int {
        pages.count
    }

    /// The paper of the note's first page, which its cover is drawn on.
    var coverPaper: PaperStyle {
        pages.first?.paper ?? .lined
    }

    /// The same pages and sizes with fresh page IDs, for a duplicated note.
    func duplicated(at date: Date = .now) -> NoteManifest {
        var copy = self
        copy.pages = pages.map { Page(id: UUID(), size: $0.size, paper: $0.paper) }
        copy.createdAt = date
        copy.modifiedAt = date
        return copy
    }

    /// True when the two manifests describe the same pages, ignoring timestamps.
    func hasSameLayout(as other: NoteManifest) -> Bool {
        pages == other.pages && defaultPageSize == other.defaultPageSize
    }

    // MARK: Reading and writing

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The manifest at `url`, or nil if there's none or it can't be read (including one written by a newer
    /// format version) or lists no pages.
    static func read(from url: URL) -> NoteManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(NoteManifest.self, from: data),
              manifest.formatVersion <= currentFormatVersion,
              !manifest.pages.isEmpty
        else { return nil }
        return manifest
    }

    /// Writes the manifest to `url` atomically, creating the package directory if needed.
    func write(to url: URL) throws {
        let data = try Self.encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
