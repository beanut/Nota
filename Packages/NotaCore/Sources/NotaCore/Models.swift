import Foundation
import InkKit
import SwiftData

// MARK: - Value types

/// The four papers notes had before page templates (NOT-27). Still read from older manifests and stores.
enum LegacyPaperStyle: String, Codable {
    case plain, lined, dotted, grid

    var template: PageTemplate {
        switch self {
        case .plain: PageTemplate.Preset.blank.template
        case .lined: PageTemplate.Preset.collegeRuled.template
        case .dotted: PageTemplate.Preset.dots.template
        case .grid: PageTemplate.Preset.smallGrid.template
        }
    }
}

public extension PageTemplate {
    /// What a new note gets unless it asks for something else.
    static let noteDefault = Preset.collegeRuled.template

    /// The template as a compact JSON string, for `Note.paperName` and remembered choices.
    var encodedString: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// A template from `encodedString`, or from the name of a pre-template paper ("lined", "grid", …).
    init?(encodedString string: String) {
        if let legacy = LegacyPaperStyle(rawValue: string) {
            self = legacy.template
        } else if string.hasPrefix("{"), let template = try? JSONDecoder().decode(PageTemplate.self, from: Data(string.utf8)) {
            self = template
        } else {
            return nil
        }
    }
}

public enum NoteKind: String, Codable, Sendable {
    case notebook, pdf
}

/// A note's colour. Kept with the note, though thumbnails now show its real ink rather than a heading in it.
/// The app maps it to a design-system ink.
public enum NoteTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case indigo, teal, rust, violet, graphite
    public var id: String {
        rawValue
    }
}

/// A folder's label colour. The app maps it to a design-system ink.
public enum FolderColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, teal, orange, purple, pink, green
    public var id: String {
        rawValue
    }
}

// MARK: - SwiftData models

@Model
public final class Folder {
    public var name: String
    public var colorName: String
    public var sortIndex: Int
    public var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    public var notes: [Note] = []

    public init(name: String, color: FolderColor, sortIndex: Int) {
        self.name = name
        colorName = color.rawValue
        self.sortIndex = sortIndex
        createdAt = .now
    }

    public var color: FolderColor {
        get { FolderColor(rawValue: colorName) ?? .blue }
        set { colorName = newValue.rawValue }
    }

    /// Notes in this folder that are not in Recently Deleted.
    public var activeNoteCount: Int {
        notes.filter { $0.deletedAt == nil }.count
    }
}

@Model
public final class Note {
    @Attribute(.unique) public var id: UUID
    public var title: String
    /// Mirrored from the note's manifest by `DocumentStore` on every save and at launch; the value a note is
    /// created with only seeds the manifest of a note that has none.
    public var pageCount: Int
    public var createdAt: Date
    /// Mirrored from the note's manifest, like `pageCount`.
    public var modifiedAt: Date
    /// The first page's template (`PageTemplate.encodedString`), mirrored from the manifest; each page's own
    /// template is kept there. Stores from before templates hold a paper name ("lined"), read the same way.
    public var paperName: String
    public var tintName: String
    public var kindName: String
    public var isFavorite: Bool
    public var isShared: Bool
    /// Set when the note is moved to Recently Deleted.
    public var deletedAt: Date?
    /// The typed text in the note's text boxes, for search. Mirrored from the note's pages by `DocumentStore`
    /// whenever it saves or opens the note, and read from its package when the index is rebuilt.
    public var textContent: String = ""
    public var folder: Folder?

    public init(title: String,
                pageCount: Int = 1,
                modifiedAt: Date = .now,
                template: PageTemplate = .noteDefault,
                tint: NoteTint = .indigo,
                kind: NoteKind = .notebook,
                isFavorite: Bool = false,
                isShared: Bool = false,
                folder: Folder? = nil,
                id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        createdAt = modifiedAt
        self.modifiedAt = modifiedAt
        paperName = template.encodedString
        tintName = tint.rawValue
        kindName = kind.rawValue
        self.isFavorite = isFavorite
        self.isShared = isShared
        self.folder = folder
    }

    /// The first page's template. Unreadable values read as the default.
    public var template: PageTemplate {
        get { PageTemplate(encodedString: paperName) ?? .noteDefault }
        set { paperName = newValue.encodedString }
    }

    public var tint: NoteTint {
        get { NoteTint(rawValue: tintName) ?? .indigo }
        set { tintName = newValue.rawValue }
    }

    public var kind: NoteKind {
        get { NoteKind(rawValue: kindName) ?? .notebook }
        set { kindName = newValue.rawValue }
    }

    public var isDeleted: Bool {
        deletedAt != nil
    }

    public var subtitle: String {
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        return "\(pages) · \(modifiedAt.libraryLabel)"
    }
}

// MARK: - Dates

public extension Date {
    /// "Today", "Yesterday", a weekday within the last week, otherwise "Nov 2" (plus the year if it isn't this one).
    var libraryLabel: String {
        libraryLabel(relativeTo: .now)
    }

    /// `libraryLabel` as seen at `now`, in `calendar` (whose time zone decides where days begin) and `locale`.
    func libraryLabel(relativeTo now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(self, inSameDayAs: now) {
            return String(localized: "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), self >= weekAgo {
            return formatted(style.weekday(.wide))
        }
        if calendar.isDate(self, equalTo: now, toGranularity: .year) {
            return formatted(style.month(.abbreviated).day())
        }
        return formatted(style.month(.abbreviated).day().year())
    }
}
