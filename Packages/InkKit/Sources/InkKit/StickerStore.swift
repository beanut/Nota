import Combine
import Foundation

/// A saved selection to place again on any page of any note: ink, shapes, text and pictures, as they were.
///
/// A sticker is a lasso clip (`SelectionClip`), so its ink stays vector and its objects stay editable when
/// it's placed, and its pictures' bytes travel inside it. `preview` is a PNG of it for the sticker picker.
public struct Sticker: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    /// The clip's encoding (`SelectionClip.encoded()`).
    let clip: Data
    /// A PNG of the sticker on a transparent background.
    public let preview: Data

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, clip: Data, preview: Data) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.clip = clip
        self.preview = preview
    }

    /// The selection the sticker holds; throws for a clip this version can't read.
    func selectionClip() throws -> SelectionClip {
        try SelectionClip(data: clip)
    }
}

/// The sticker collection every editor shares, kept app-wide (not per note) so a sticker made in one note
/// can be placed in any other.
///
/// Saved in a folder (`Application Support/InkKit/Stickers` for `shared`): `Stickers.json` lists the stickers
/// in order with their names and dates, and each sticker's clip and preview are files of their own
/// (`<id>.clip`, `<id>.png`), each written atomically. A store made with no folder keeps them in memory.
///
/// ```swift
/// let stickers = StickerStore(folderURL: url)
/// stickers.add(name: "Star", clip: data, preview: png)
/// ```
@MainActor
public final class StickerStore: ObservableObject {
    public static let shared = StickerStore(folderURL: defaultFolderURL)

    /// `Application Support/InkKit/Stickers`.
    public static var defaultFolderURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("InkKit", isDirectory: true)
            .appendingPathComponent("Stickers", isDirectory: true)
    }

    static let indexFormatVersion = 1

    /// Newest first.
    @Published public private(set) var stickers: [Sticker]
    public let folderURL: URL?
    /// The last save's error, if it failed.
    public private(set) var lastSaveError: Error?

    public init(folderURL: URL?) {
        self.folderURL = folderURL
        stickers = Self.load(from: folderURL)
    }

    /// Adds a sticker at the front of the collection.
    @discardableResult
    func add(name: String, clip: Data, preview: Data) -> Sticker {
        let sticker = Sticker(name: name, clip: clip, preview: preview)
        stickers.insert(sticker, at: 0)
        save { folder in
            try clip.write(to: folder.appendingPathComponent("\(sticker.id.uuidString).clip"), options: .atomic)
            try preview.write(to: folder.appendingPathComponent("\(sticker.id.uuidString).png"), options: .atomic)
        }
        return sticker
    }

    /// Adds the selection in `clip` as a sticker, with `preview` as its picture. Nil if it can't be encoded.
    @discardableResult
    func add(_ clip: SelectionClip, preview: Data, name: String? = nil) -> Sticker? {
        guard !clip.isEmpty, let data = try? clip.encoded() else { return nil }
        return add(name: name ?? nextName(), clip: data, preview: preview)
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = stickers.firstIndex(where: { $0.id == id }), stickers[i].name != trimmed else { return }
        stickers[i].name = trimmed
        save()
    }

    public func delete(_ id: UUID) {
        guard let i = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers.remove(at: i)
        save { folder in
            for ext in ["clip", "png"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).\(ext)"))
            }
        }
    }

    /// "Sticker 1", "Sticker 2", … the first not taken.
    func nextName() -> String {
        let names = Set(stickers.map(\.name))
        var n = 1
        while names.contains("Sticker \(n)") {
            n += 1
        }
        return "Sticker \(n)"
    }

    // MARK: Files

    private struct Index: Codable {
        var formatVersion: Int
        var stickers: [Entry]
    }

    private struct Entry: Codable {
        var id: UUID
        var name: String
        var createdAt: Date
    }

    /// Writes `files` (if any) into the folder, then the index.
    private func save(_ files: ((URL) throws -> Void)? = nil) {
        guard let folderURL else { return }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try files?(folderURL)
            let index = Index(formatVersion: Self.indexFormatVersion,
                              stickers: stickers.map { Entry(id: $0.id, name: $0.name, createdAt: $0.createdAt) })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(index).write(to: folderURL.appendingPathComponent("Stickers.json"), options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }

    /// The stickers listed in the folder's index whose files are there. An index from a newer version, or
    /// one that can't be read, is moved aside to `Stickers.unreadable.json` (not overwritten) and the
    /// collection starts empty.
    private static func load(from folder: URL?) -> [Sticker] {
        let url = folder?.appendingPathComponent("Stickers.json")
        guard let folder, let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(Index.self, from: data), index.formatVersion <= indexFormatVersion else {
            let aside = folder.appendingPathComponent("Stickers.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
        return index.stickers.compactMap { entry in
            guard let clip = try? Data(contentsOf: folder.appendingPathComponent("\(entry.id.uuidString).clip")),
                  let preview = try? Data(contentsOf: folder.appendingPathComponent("\(entry.id.uuidString).png"))
            else { return nil }
            return Sticker(id: entry.id, name: entry.name, createdAt: entry.createdAt, clip: clip, preview: preview)
        }
    }
}
