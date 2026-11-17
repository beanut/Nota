import Foundation

/// A page's committed-ink tiles as bytes, for an app to keep between launches (NOT-106): derived data,
/// never needed to open the page. What `CanvasDocument.committedTiles` hands out and
/// `restoreCommittedTiles(_:)` takes back.
public struct PageTiles: @unchecked Sendable { // immutable
    /// The encoded tiles (InkKit's own format, with its version and the renderer's; see `TileRaster`).
    public let data: Data
    /// The page's `CanvasDocument.inkVersion` the tiles show. Keep them with whatever identifies the ink
    /// at that version (the app hashes the saved ink file), and restore them only onto the same ink.
    public let inkVersion: Int
    /// Which capture of the page's tiles these are (`adoptPersistedTiles(_:for:)`).
    let generation: Int
}

public extension CanvasDocument {
    /// The page's committed tiles at its resting level, as the last canvas showing it left them, or nil if
    /// none has. They change when a canvas showing the page goes away (or the app goes to the background):
    /// `observeCommittedTiles` hears when.
    var committedTiles: PageTiles? {
        tileRaster.map { PageTiles(data: $0.data, inkVersion: $0.revision, generation: tileRasterGeneration) }
    }

    /// Takes tiles kept from an earlier launch, for the page's ink as it is now (the caller checks that,
    /// e.g. by a hash of the ink file the page was read from). A canvas showing the page then restores
    /// them instead of filling them. False, and nothing changes, when `data` isn't tiles of this InkKit's
    /// format and renderer, or of a page of this size: the tiles are then filled as usual.
    @discardableResult
    func restoreCommittedTiles(_ data: Data) -> Bool {
        guard let raster = TileRaster(data: data, revision: inkVersion), raster.pageSize == pageBounds.size else {
            return false
        }
        tileRaster = raster
        return true
    }

    /// `tiles`' bytes as stored by the app (mapped from its file, say), to keep in place of the copy in
    /// memory: the same tiles, if no newer capture has replaced them since.
    func adoptPersistedTiles(_ data: Data, for tiles: PageTiles) {
        guard tileRasterGeneration == tiles.generation, let raster = tileRaster, data.count == raster.data.count,
              let mapped = TileRaster(data: data, revision: raster.revision)
        else { return }
        tileRaster = mapped
        tileRasterGeneration = tiles.generation
    }

    /// Calls `onCapture` each time a canvas leaves new `committedTiles` with the page, until `owner` is
    /// released or `stopObservingCommittedTiles(_:)` is called. Observing again with the same owner
    /// replaces the handler.
    func observeCommittedTiles(_ owner: AnyObject, onCapture: @escaping () -> Void) {
        stopObservingCommittedTiles(owner)
        tileObservers.append((owner: { [weak owner] in owner }, onCapture: onCapture))
    }

    func stopObservingCommittedTiles(_ owner: AnyObject) {
        tileObservers.removeAll { $0.owner() == nil || $0.owner() === owner }
    }
}

extension CanvasDocument {
    /// A canvas left `raster` with the page: keeps it and tells the observers.
    func captured(_ raster: TileRaster) {
        tileRaster = raster
        tileObservers.removeAll { $0.owner() == nil }
        for observer in tileObservers {
            observer.onCapture()
        }
    }
}
