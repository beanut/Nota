import CryptoKit
import Foundation
import InkKit
import os

/// Each page's committed-ink tiles, kept between launches so a page shows its ink at once the first time
/// it's opened after a launch, in paged and continuous scrolling alike (NOT-106).
///
/// **Derived data, in the caches directory.** Tiles are only ever a faster way to show ink the page's
/// `.ink` file already holds: a note never needs them to open, and they're rebuilt (by filling) when
/// they're missing, stale or damaged. So they live in `Library/Caches/PageTiles/<note id>/<page id>.tiles`,
/// outside the note's package: they aren't backed up, synced or exported with the note (about 5 MB for a
/// dense page would bloat all three), and the system may purge them.
///
/// **Keyed by the ink they show.** Each file starts with the SHA-256 of the page's ink file as saved, then
/// holds InkKit's encoded tiles (`CanvasDocument.committedTiles`, which carry InkKit's own format and
/// renderer versions, the level and the page size). Tiles are only written for ink that's on disk (the
/// page's last save, or what it was read from), and only read back for an ink file with the same hash, so
/// they can never show ink the page doesn't have. Anything else found is removed and the page filled.
///
/// **Bounded.** Past `byteLimit`, the folders of the notes opened least recently go first (a note's folder
/// is touched each time it's opened), never the note just opened or written.
///
/// Reads are mapped (`Data(contentsOf:options: .alwaysMapped)`): opening a note reads only the tiles that
/// are shown. Writes are atomic (`PackageFiles`: a temporary file renamed over the old one), on the cache's
/// own serial queue, so they never hold up a note's save; a reader sees the old file or the new one.
public final class PageTileCache: Sendable {
    /// `Library/Caches/PageTiles`.
    public static var standardDirectory: URL {
        URL.cachesDirectory.appending(path: "PageTiles", directoryHint: .isDirectory)
    }

    public let directory: URL
    /// How many bytes of tiles are kept, all notes together.
    public let byteLimit: Int
    private let files: PackageFiles
    private let queue = DispatchQueue(label: "com.bernard.nota.page-tiles", qos: .utility)

    /// The file's own header: magic, version, then the ink file's hash.
    private static let magic = Data("NTPT".utf8)
    private static let version: UInt32 = 1
    private static let headerSize = 4 + 4 + 32
    static let fileExtension = "tiles"

    public init(directory: URL = PageTileCache.standardDirectory, byteLimit: Int = 256 << 20,
                files: PackageFiles = PackageFiles()) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.files = files
    }

    /// What the tiles of a page are keyed by: the hash of its ink file's bytes.
    public static func inkHash(of inkFile: Data) -> Data {
        Data(SHA256.hash(data: inkFile))
    }

    func folder(ofNote note: UUID) -> URL {
        directory.appending(path: note.uuidString, directoryHint: .isDirectory)
    }

    func url(ofPage page: UUID, note: UUID) -> URL {
        folder(ofNote: note).appending(path: "\(page.uuidString).\(Self.fileExtension)")
    }

    // MARK: Reading

    /// The tiles kept for the page, if they were taken of the ink whose file hashes to `inkHash`; mapped,
    /// not read. A file that isn't (the ink was saved since, or it's damaged) is removed. Call it off the
    /// main actor.
    public func tiles(ofPage page: UUID, note: UUID, inkHash: Data) -> Data? {
        let url = url(ofPage: page, note: note)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        guard data.count > Self.headerSize, data.prefix(4) == Self.magic,
              data[data.startIndex + 4 ..< data.startIndex + 8].elementsEqual(Self.versionBytes),
              data[data.startIndex + 8 ..< data.startIndex + Self.headerSize].elementsEqual(inkHash)
        else {
            remove(url)
            return nil
        }
        return data[(data.startIndex + Self.headerSize)...]
    }

    private static var versionBytes: [UInt8] {
        withUnsafeBytes(of: version.littleEndian) { Array($0) }
    }

    // MARK: Writing

    /// Keeps `tiles` for the page, taken of the ink whose file hashes to `inkHash`, in the background; then
    /// hands `stored` the bytes as kept (mapped), or nil if they couldn't be written.
    public func store(_ tiles: Data, ofPage page: UUID, note: UUID, inkHash: Data,
                      stored: (@Sendable (Data?) -> Void)? = nil) {
        let url = url(ofPage: page, note: note)
        queue.async { [self] in
            var file = Self.magic
            file.append(contentsOf: Self.versionBytes)
            file.append(inkHash)
            file.append(tiles)
            do {
                try files.write(file, to: url)
            } catch {
                Logger.documents.error("Keeping tiles failed: \(String(describing: error), privacy: .public)")
                stored?(nil)
                return
            }
            trim(keeping: note)
            stored?(self.tiles(ofPage: page, note: note, inkHash: inkHash))
        }
    }

    // MARK: Housekeeping

    /// The note was opened, with `pages`: it's now the most recently opened, files for pages it no longer
    /// has go, and the cache is trimmed to its limit. Call it off the main actor.
    public func noteOpened(_ note: UUID, pages: Set<UUID>) {
        let folder = folder(ofNote: note)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        files.removeTemporaryFiles(in: folder)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let page = UUID(uuidString: url.deletingPathExtension().lastPathComponent), pages.contains(page)
            else {
                remove(url)
                continue
            }
        }
        queue.async { [self] in trim(keeping: note) }
    }

    /// Forgets the note's tiles (it was deleted).
    public func removeNote(_ note: UUID) {
        let folder = folder(ofNote: note)
        queue.async { [self] in remove(folder) }
    }

    /// Forgets one page's tiles (they turned out unusable).
    public func removePage(_ page: UUID, note: UUID) {
        let url = url(ofPage: page, note: note)
        queue.async { [self] in remove(url) }
    }

    /// Waits for every write and removal queued so far.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// The bytes kept, all notes together.
    var byteCount: Int {
        noteFolders().reduce(0) { $0 + $1.bytes }
    }

    /// Removes whole notes' tiles, least recently opened first, until the cache is within `byteLimit`.
    private func trim(keeping kept: UUID?) {
        var folders = noteFolders()
        var total = folders.reduce(0) { $0 + $1.bytes }
        guard total > byteLimit else { return }
        folders.sort { $0.used < $1.used }
        for folder in folders where total > byteLimit && folder.note != kept {
            remove(folder.url)
            total -= folder.bytes
        }
    }

    private func noteFolders() -> [(note: UUID, url: URL, used: Date, bytes: Int)] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return folders.compactMap { url in
            guard let note = UUID(uuidString: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true
            else { return nil }
            let contents = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
            let bytes = contents.reduce(0) { sum, file in
                sum + ((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
            return (note, url, values.contentModificationDate ?? .distantPast, bytes)
        }
    }

    private func remove(_ url: URL) {
        try? files.remove(url)
    }
}
