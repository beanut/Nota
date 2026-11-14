import Foundation
import InkKit

/// Where a note's files live: one `<id>.nota` directory per note under Application Support.
///
/// Each holds `manifest.json` (the title and page layout, see `NoteManifest`), `pages/` (one `.ink` file per
/// page that has ink and one `.json` file per page that has objects, both named by page id), `thumbs/` and
/// `templates/` (custom template backgrounds).
/// `DocumentStore` reads and writes them; every file is replaced atomically (see `PackageFiles`).
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

    /// The folder of the note's page files.
    public static func pagesURL(for noteID: UUID, in library: URL = libraryURL) -> URL {
        url(for: noteID, in: library).appending(path: "pages", directoryHint: .isDirectory)
    }

    /// The `.ink` file holding a page's strokes. A page without one has no ink.
    public static func pageURL(for pageID: UUID, noteID: UUID, in library: URL = libraryURL) -> URL {
        pagesURL(for: noteID, in: library).appending(path: "\(pageID.uuidString).\(InkPageFile.fileExtension)")
    }

    /// The `.json` file holding a page's objects (`PageObjectsFile`). A page without one has no objects.
    public static func objectsURL(for pageID: UUID, noteID: UUID, in library: URL = libraryURL) -> URL {
        pagesURL(for: noteID, in: library).appending(path: "\(pageID.uuidString).\(PageObjectsFile.fileExtension)")
    }

    /// The note an `<id>.nota` package directory belongs to, or nil for anything else in the library.
    public static func noteID(ofPackage url: URL) -> UUID? {
        guard url.pathExtension == "nota" else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
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
