import Foundation

/// The file operations a note package is written with. Every write goes to a temporary file beside its
/// target and is then renamed over it, so a file in a package is always either its old or its new contents,
/// whenever the app is killed.
///
/// A save writes the page files first, then the manifest, and only then removes files the manifest no longer
/// lists; until the manifest lands, the package still describes its old state, and every file it names is
/// still there. What a killed save can leave behind is harmless: temporary files (skipped by readers and
/// removed by the note's next save) and page files the manifest doesn't list (removed by the next save).
///
/// Tests pass a `faults` hook to stop a save at any step, as if the app had been killed there.
public struct PackageFiles: Sendable {
    /// A point in a write where the app could be killed.
    public enum Step: Equatable, Sendable {
        /// About to write the temporary file for `URL`.
        case writeTemporary(URL)
        /// The temporary file is written in full; about to rename it over `URL`.
        case replace(URL)
        /// About to remove `URL`.
        case remove(URL)
    }

    /// Called before each step; when it throws, the step and the rest of the save don't happen.
    public var faults: (@Sendable (Step) throws -> Void)?

    public init(faults: (@Sendable (Step) throws -> Void)? = nil) {
        self.faults = faults
    }

    /// Temporary files are hidden and end in this, so readers and directory listings can skip them.
    static let temporarySuffix = ".notatmp"

    static func isTemporary(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(temporarySuffix)
    }

    /// Replaces the file at `url` with `data` atomically, creating its folder if needed.
    public func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)\(Self.temporarySuffix)")
        try faults?(.writeTemporary(url))
        try data.write(to: temporary)
        // A failure from here on leaves the temporary file, as a kill would; the note's next save removes it.
        try faults?(.replace(url))
        try Self.rename(temporary, to: url)
    }

    /// Copies the file at `source` over `url` atomically.
    public func copy(_ source: URL, to url: URL) throws {
        try write(Data(contentsOf: source), to: url)
    }

    /// Removes the file or folder at `url`; nothing there is not an error.
    public func remove(_ url: URL) throws {
        try faults?(.remove(url))
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
    }

    /// Moves a file that can't be read out of the way under a name readers don't look at, so nothing
    /// overwrites it and it can still be recovered by hand.
    func setAside(_ url: URL) {
        let aside = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).damaged-\(Int(Date.now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    /// Removes temporary files left in `folder` by a save the app was killed during.
    func removeTemporaryFiles(in folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in contents where Self.isTemporary(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `rename(2)`, which replaces `destination` atomically when it exists.
    private static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }
}
