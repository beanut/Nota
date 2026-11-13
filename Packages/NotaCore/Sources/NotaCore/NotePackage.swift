import Foundation
import InkKit

/// Where a note's files live: one `<id>.nota` directory per note under Application Support.
///
/// Each holds `manifest.json` (the page layout, see `NoteManifest`), `thumbs/` and `templates/` (custom
/// template backgrounds); NOT-6 adds page files alongside them.
public enum NotePackage {
    public static var libraryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Notes", directoryHint: .isDirectory)
    }

    public static func url(for noteID: UUID, in library: URL = libraryURL) -> URL {
        library.appending(path: "\(noteID.uuidString).nota", directoryHint: .isDirectory)
    }

    public static func manifestURL(for noteID: UUID, in library: URL = libraryURL) -> URL {
        url(for: noteID, in: library).appending(path: "manifest.json")
    }

    public static func thumbnailsURL(for noteID: UUID, in library: URL = libraryURL) -> URL {
        url(for: noteID, in: library).appending(path: "thumbs", directoryHint: .isDirectory)
    }

    public static func coverURL(for noteID: UUID, in library: URL = libraryURL) -> URL {
        thumbnailsURL(for: noteID, in: library).appending(path: "cover.png")
    }

    /// The folder of the note's custom template backgrounds (PDFs and images used as page templates).
    public static func templatesURL(for noteID: UUID, in library: URL = libraryURL) -> URL {
        url(for: noteID, in: library).appending(path: "templates", directoryHint: .isDirectory)
    }

    /// The file holding `background`'s bytes.
    public static func templateURL(for background: TemplateBackground, noteID: UUID, in library: URL = libraryURL) -> URL {
        templatesURL(for: noteID, in: library)
            .appending(path: "\(background.id.uuidString).\(background.kind.fileExtension)")
    }
}
