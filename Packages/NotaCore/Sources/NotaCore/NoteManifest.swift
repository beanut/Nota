import Foundation
import InkKit

/// What a note package records about the note, kept as `manifest.json` in the note's `.nota` directory: its
/// title, the page order and each page's size and template, the size new pages get, and when the note was
/// created and last changed. Each page's ink is in `pages/<page id>.ink` beside it, and custom template
/// backgrounds in `templates/` (see `NotePackage`).
///
/// Format 3 added `title` and page files; format 2 replaced each page's `paper` name with a full
/// `template`. Formats 1 and 2 are still read.
///
/// The manifest is the source of truth for a note's page count and modification date; the SwiftData
/// `Note` mirrors them for the library. The title's source of truth is the `Note`: it's copied here on
/// every save so the library index can be rebuilt from packages alone (`DocumentStore.rebuildIndex`).
public struct NoteManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 3

    public struct Page: Codable, Equatable, Sendable {
        public var id: UUID
        public var size: PageSize
        public var template: PageTemplate

        public init(id: UUID, size: PageSize, template: PageTemplate) {
            self.id = id
            self.size = size
            self.template = template
        }

        private enum CodingKeys: String, CodingKey {
            case id, size, template, paper
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            size = try c.decode(PageSize.self, forKey: .size)
            if let template = try c.decodeIfPresent(PageTemplate.self, forKey: .template) {
                self.template = template
            } else {
                // Format 1: a paper name.
                let paper = try? c.decodeIfPresent(String.self, forKey: .paper)
                template = paper.flatMap(LegacyPaperStyle.init(rawValue:))?.template ?? .noteDefault
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(size, forKey: .size)
            try c.encode(template, forKey: .template)
        }
    }

    public var formatVersion = Self.currentFormatVersion
    /// The note's title when it was last saved. Nil in manifests from before format 3.
    public var title: String?
    public var pages: [Page]
    /// The size new pages get when there's no neighbouring page to copy, and the size "Use … for All
    /// Pages" last applied.
    public var defaultPageSize: PageSize
    public var createdAt: Date
    public var modifiedAt: Date

    /// A manifest of `pageCount` blank pages (at least one) of `size` on `template`.
    public init(title: String? = nil, pageCount: Int = 1, size: PageSize, template: PageTemplate,
                createdAt: Date = .now, modifiedAt: Date = .now) {
        self.title = title
        pages = (0 ..< max(1, pageCount)).map { _ in Page(id: UUID(), size: size, template: template) }
        defaultPageSize = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var pageCount: Int {
        pages.count
    }

    /// The template of the note's first page, which its cover is drawn on.
    public var coverTemplate: PageTemplate {
        pages.first?.template ?? .noteDefault
    }

    /// Every custom background the pages use, once each.
    public var backgrounds: [TemplateBackground] {
        var seen = Set<UUID>()
        return pages.compactMap(\.template.background).filter { seen.insert($0.id).inserted }
    }

    /// The same pages and sizes with fresh page IDs, for a duplicated note titled `title`.
    public func duplicated(title: String? = nil, at date: Date = .now) -> NoteManifest {
        var copy = self
        copy.title = title
        copy.pages = pages.map { Page(id: UUID(), size: $0.size, template: $0.template) }
        copy.createdAt = date
        copy.modifiedAt = date
        return copy
    }

    /// True when the two manifests describe the same pages, ignoring timestamps.
    public func hasSameLayout(as other: NoteManifest) -> Bool {
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
    public static func read(from url: URL) -> NoteManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(NoteManifest.self, from: data),
              manifest.formatVersion <= currentFormatVersion,
              !manifest.pages.isEmpty
        else { return nil }
        return manifest
    }

    /// The manifest as JSON. `DocumentStore` sets `formatVersion` to `currentFormatVersion` before it saves.
    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Writes the manifest to `url` atomically, creating the package directory if needed.
    public func write(to url: URL, files: PackageFiles = PackageFiles()) throws {
        try files.write(encoded(), to: url)
    }
}
