import Combine
import Foundation

/// Keeps a `PenTray` and saves it as JSON whenever it changes, so saved pens, quick sizes and colours,
/// custom brushes, palettes and recent colours survive relaunch.
///
/// Every editor uses `PenTrayStore.shared` (a file in Application Support), so a pen saved in one window
/// shows in the others straight away. A store made with no file keeps the tray in memory only.
///
/// ```swift
/// let store = PenTrayStore(fileURL: url)
/// store.update { $0.addRecentColor(PenColor(rgb: 0x3345D9)) }   // saved to `url`
/// ```
@MainActor
public final class PenTrayStore: ObservableObject {
    /// The tray every editor shares, saved to `defaultFileURL`.
    public static let shared = PenTrayStore(fileURL: defaultFileURL)

    /// `Application Support/InkKit/PenTray.json`.
    public static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("InkKit", isDirectory: true)
            .appendingPathComponent("PenTray.json")
    }

    @Published public private(set) var tray: PenTray
    /// Where the tray is saved; nil keeps it in memory.
    public let fileURL: URL?
    /// The last save's error, if it failed.
    public private(set) var lastSaveError: Error?

    /// Reads the tray at `fileURL`, or starts an empty one. A file that can't be read at all is moved
    /// aside to `PenTray.unreadable.json` rather than overwritten.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        tray = Self.load(from: fileURL)
    }

    /// Changes the tray and saves it, if the change did anything.
    public func update(_ change: (inout PenTray) -> Void) {
        var next = tray
        change(&next)
        guard next != tray else { return }
        tray = next
        save()
    }

    /// Replaces the tray (for example with one from another device) and saves it.
    public func replace(with tray: PenTray) {
        update { $0 = tray }
    }

    /// Reads the file again, dropping unsaved state (there is none: every change is saved).
    public func reload() {
        tray = Self.load(from: fileURL)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let data = try tray.jsonData()
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }

    private static func load(from url: URL?) -> PenTray {
        guard let url, let data = try? Data(contentsOf: url) else { return PenTray() }
        if let tray = try? PenTray(json: data) {
            return tray
        }
        let aside = url.deletingLastPathComponent().appendingPathComponent("PenTray.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return PenTray()
    }
}
