import SwiftData
import SwiftUI

// MARK: - Value types

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case plain, lined, dotted, grid
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .plain: "Blank"
        case .lined: "Lined"
        case .dotted: "Dotted"
        case .grid: "Grid"
        }
    }
}

enum NoteKind: String, Codable {
    case notebook, pdf
}

/// Cover colour of a note: the band across the top of its thumbnail.
enum NoteTint: String, Codable, CaseIterable, Identifiable {
    case indigo, teal, rust, violet, graphite
    var id: String {
        rawValue
    }

    var color: Color {
        switch self {
        case .indigo: Color(red: 0.20, green: 0.27, blue: 0.78)
        case .teal: Color(red: 0.07, green: 0.47, blue: 0.42)
        case .rust: Color(red: 0.75, green: 0.27, blue: 0.10)
        case .violet: Color(red: 0.49, green: 0.23, blue: 0.93)
        case .graphite: Color(red: 0.27, green: 0.28, blue: 0.31)
        }
    }
}

enum FolderColor: String, Codable, CaseIterable, Identifiable {
    case blue, teal, orange, purple, pink, green
    var id: String {
        rawValue
    }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.20, green: 0.27, blue: 0.85)
        case .teal: Color(red: 0.07, green: 0.47, blue: 0.42)
        case .orange: Color(red: 0.80, green: 0.30, blue: 0.10)
        case .purple: .purple
        case .pink: .pink
        case .green: .green
        }
    }
}

// MARK: - SwiftData models

@Model
final class Folder {
    var name: String
    var colorName: String
    var sortIndex: Int
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note] = []

    init(name: String, color: FolderColor, sortIndex: Int) {
        self.name = name
        colorName = color.rawValue
        self.sortIndex = sortIndex
        createdAt = .now
    }

    var color: FolderColor {
        get { FolderColor(rawValue: colorName) ?? .blue }
        set { colorName = newValue.rawValue }
    }

    /// Notes in this folder that are not in Recently Deleted.
    var activeNoteCount: Int {
        notes.filter { $0.deletedAt == nil }.count
    }
}

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var title: String
    var pageCount: Int
    var createdAt: Date
    var modifiedAt: Date
    var paperName: String
    var tintName: String
    var kindName: String
    var isFavorite: Bool
    var isShared: Bool
    /// Set when the note is moved to Recently Deleted.
    var deletedAt: Date?
    var folder: Folder?

    init(title: String,
         pageCount: Int = 1,
         modifiedAt: Date = .now,
         paper: PaperStyle = .lined,
         tint: NoteTint = .indigo,
         kind: NoteKind = .notebook,
         isFavorite: Bool = false,
         isShared: Bool = false,
         folder: Folder? = nil) {
        id = UUID()
        self.title = title
        self.pageCount = pageCount
        createdAt = modifiedAt
        self.modifiedAt = modifiedAt
        paperName = paper.rawValue
        tintName = tint.rawValue
        kindName = kind.rawValue
        self.isFavorite = isFavorite
        self.isShared = isShared
        self.folder = folder
    }

    var paper: PaperStyle {
        get { PaperStyle(rawValue: paperName) ?? .lined }
        set { paperName = newValue.rawValue }
    }

    var tint: NoteTint {
        get { NoteTint(rawValue: tintName) ?? .indigo }
        set { tintName = newValue.rawValue }
    }

    var kind: NoteKind {
        get { NoteKind(rawValue: kindName) ?? .notebook }
        set { kindName = newValue.rawValue }
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    var subtitle: String {
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        return "\(pages) · \(modifiedAt.libraryLabel)"
    }
}

// MARK: - Dates

extension Date {
    /// "Today", "Yesterday", a weekday within the last week, otherwise "Nov 2" (plus the year if it isn't this one).
    var libraryLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return String(localized: "Today")
        }
        if calendar.isDateInYesterday(self) {
            return String(localized: "Yesterday")
        }
        let startOfToday = calendar.startOfDay(for: .now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), self >= weekAgo {
            return formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }
}
