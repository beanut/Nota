import Foundation

/// Where a note's files live: one `<id>.nota` directory per note under Application Support.
///
/// Each holds `manifest.json` (the page layout, see `NoteManifest`) and `thumbs/`; NOT-6 adds page files
/// alongside them.
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
}
