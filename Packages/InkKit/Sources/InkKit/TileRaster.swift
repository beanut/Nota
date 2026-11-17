import Compression
import CoreGraphics
import Foundation

/// A page's committed-ink tiles at one level (its resting level: the fitted page, or the column at zoom 1
/// in continuous scrolling), compressed, so a page coming back into view puts the same pixels back instead
/// of filling every stroke again (NOT-106). The document keeps one while it's loaded, whether or not a
/// canvas shows it, and the app can keep its bytes (`data`) between launches.
///
/// It's labelled with the `CanvasDocument.inkVersion` it shows, and outlives edits: a tile that no change
/// since that version reaches (`CanvasDocument.inkChanges`) is restored as it is, one a change reaches is
/// restored and refilled only there, and when the log no longer knows, the tile is filled whole.
///
/// Lossless (LZFSE per tile), about 5 MB for a fitted 5k-stroke page. It may hold only some of the page's
/// tiles (an embedded page leaves the tiles it had cached); a tile it doesn't hold is filled.
///
/// **Format** (`data`, little-endian): a header (magic, `formatVersion`, `rendererVersion`, tile side,
/// level, page size, tile count), one entry per tile (column, row, offset and length of its compressed
/// pixels, length 0 for a tile with no ink), then the compressed pixels. `data` may be mapped from a file:
/// it's only ever read.
struct TileRaster: @unchecked Sendable { // immutable; `data` is never written
    /// The layout of `data`. A raster of another format isn't read.
    static let formatVersion: UInt16 = 1
    /// The tile fill's own version: bump it whenever the pixels a fill gives for the same strokes change
    /// (the renderer, a built-in brush, grain, wax, colour handling), so rasters kept from before are
    /// ignored and their tiles filled again, rather than shown wrong.
    static let rendererVersion: UInt32 = 1

    private static let magic: UInt32 = 0x5352_544E // "NTRS" read as little-endian bytes
    private static let headerSize = 44
    private static let entrySize = 20
    private static let bytesPerRow = TileKey.side * 4
    private static let tileBytes = bytesPerRow * TileKey.side

    /// The page's `CanvasDocument.inkVersion` that the pixels show.
    let revision: Int
    let level: TileLevel
    /// The page's size when the tiles were taken: tiles of another size of page aren't its.
    let pageSize: CGSize
    /// The encoded raster (see the type's format).
    let data: Data
    /// Where each held tile's compressed pixels are in `data`, by `slot(col, row)`.
    private let slots: [Int: Slot]

    private struct Slot {
        let offset: Int
        /// 0: the tile has no ink.
        let length: Int
    }

    /// One tile's compressed pixels.
    enum Blob {
        /// The tile has no ink.
        case empty
        case compressed(Data)

        var count: Int {
            if case let .compressed(data) = self {
                return data.count
            }
            return 0
        }
    }

    /// One tile of a raster being built.
    struct Entry {
        let col: Int
        let row: Int
        let blob: Blob
    }

    /// What `data`'s header and entries say.
    private struct Layout {
        let level: TileLevel
        let size: CGSize
        let slots: [Int: Slot]
    }

    // MARK: Building

    /// Compresses `tiles` (nil for tiles with no ink). Slow (a few ms a tile): run it off the main thread.
    /// Nil if a tile isn't laid out like a tile bitmap, or `tiles` is empty.
    init?(tiles: [(key: TileKey, image: CGImage?)], revision: Int, level: TileLevel, pageSize: CGSize) {
        var entries: [Entry] = []
        for (key, image) in tiles {
            guard key.level == level, let blob = Self.compress(image) else { return nil }
            entries.append(Entry(col: key.col, row: key.row, blob: blob))
        }
        self.init(entries: entries, revision: revision, level: level, pageSize: pageSize)
    }

    /// A raster of `entries` (one per tile; a tile listed twice keeps its last). Nil when there are none.
    init?(entries: [Entry], revision: Int, level: TileLevel, pageSize: CGSize) {
        var unique: [Int: Entry] = [:]
        var order: [Int] = []
        for entry in entries {
            let slot = Self.slot(entry.col, entry.row)
            if unique[slot] == nil {
                order.append(slot)
            }
            unique[slot] = entry
        }
        guard !order.isEmpty, level.pixelsPerPoint > 0 else { return nil }
        let tiles = order.compactMap { unique[$0] }
        let blobBytes = tiles.reduce(0) { $0 + $1.blob.count }
        let start = Self.headerSize + Self.entrySize * tiles.count
        var data = Data(capacity: start + blobBytes)
        data.append(le: Self.magic)
        data.append(le: Self.formatVersion)
        data.append(le: UInt16(0))
        data.append(le: Self.rendererVersion)
        data.append(le: UInt32(TileKey.side))
        data.append(le: Double(level.pixelsPerPoint).bitPattern)
        data.append(le: Double(pageSize.width).bitPattern)
        data.append(le: Double(pageSize.height).bitPattern)
        data.append(le: UInt32(tiles.count))
        var slots: [Int: Slot] = [:]
        var offset = start
        for tile in tiles {
            data.append(le: Int32(truncatingIfNeeded: tile.col))
            data.append(le: Int32(truncatingIfNeeded: tile.row))
            data.append(le: UInt64(offset))
            data.append(le: UInt32(tile.blob.count))
            slots[Self.slot(tile.col, tile.row)] = Slot(offset: offset, length: tile.blob.count)
            offset += tile.blob.count
        }
        for tile in tiles {
            if case let .compressed(bytes) = tile.blob {
                data.append(bytes)
            }
        }
        self.revision = revision
        self.level = level
        self.pageSize = pageSize
        self.data = data
        self.slots = slots
    }

    /// Reads a raster from `data` (as `data` gave it), labelled `revision`. Nil when it isn't one, it's of
    /// another format or renderer, or an entry points outside it: the tiles are then filled.
    init?(data: Data, revision: Int) {
        let parsed: Layout? = data.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            guard let magic: UInt32 = reader.read(), magic == Self.magic,
                  let format: UInt16 = reader.read(), format == Self.formatVersion,
                  reader.skip(2),
                  let renderer: UInt32 = reader.read(), renderer == Self.rendererVersion,
                  let side: UInt32 = reader.read(), side == UInt32(TileKey.side),
                  let ppp: UInt64 = reader.read(), let width: UInt64 = reader.read(), let height: UInt64 = reader.read(),
                  let count: UInt32 = reader.read()
            else { return nil }
            let pixelsPerPoint = Double(bitPattern: ppp), w = Double(bitPattern: width), h = Double(bitPattern: height)
            guard pixelsPerPoint.isFinite, pixelsPerPoint > 0, w.isFinite, w > 0, h.isFinite, h > 0,
                  Int(count) <= (raw.count - Self.headerSize) / Self.entrySize
            else { return nil }
            var slots: [Int: Slot] = [:]
            for _ in 0 ..< count {
                guard let col: Int32 = reader.read(), let row: Int32 = reader.read(),
                      let offset: UInt64 = reader.read(), let length: UInt32 = reader.read(),
                      offset <= UInt64(raw.count), UInt64(length) <= UInt64(raw.count) - offset
                else { return nil }
                slots[Self.slot(Int(col), Int(row))] = Slot(offset: Int(offset), length: Int(length))
            }
            return Layout(level: TileLevel(pixelsPerPoint: CGFloat(pixelsPerPoint)), size: CGSize(width: w, height: h), slots: slots)
        }
        guard let parsed, !parsed.slots.isEmpty else { return nil }
        self.revision = revision
        level = parsed.level
        pageSize = parsed.size
        self.data = data
        slots = parsed.slots
    }

    /// The same tiles, labelled `revision` (they show it as well: no change since reached them).
    func relabeled(_ revision: Int) -> TileRaster {
        TileRaster(revision: revision, level: level, pageSize: pageSize, data: data, slots: slots)
    }

    private init(revision: Int, level: TileLevel, pageSize: CGSize, data: Data, slots: [Int: Slot]) {
        self.revision = revision
        self.level = level
        self.pageSize = pageSize
        self.data = data
        self.slots = slots
    }

    /// `image`'s pixels compressed (`.empty` for nil), or nil if it isn't laid out like a tile bitmap.
    static func compress(_ image: CGImage?) -> Blob? {
        guard let image else { return .empty }
        guard image.width == TileKey.side, image.height == TileKey.side, image.bytesPerRow == bytesPerRow,
              image.bitsPerPixel == 32, image.bitmapInfo.rawValue == TileBitmap.bitmapInfo,
              let bytes = image.dataProvider?.data, CFDataGetLength(bytes) >= tileBytes
        else { return nil }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: tileBytes)
        defer { destination.deallocate() }
        let size = compression_encode_buffer(destination, tileBytes, CFDataGetBytePtr(bytes), tileBytes, nil,
                                             COMPRESSION_LZFSE)
        guard size > 0 else { return nil }
        return .compressed(Data(bytes: destination, count: size))
    }

    private static func slot(_ col: Int, _ row: Int) -> Int {
        row &* 1_000_003 &+ col
    }

    // MARK: Reading

    /// The encoded size.
    var byteCount: Int {
        data.count
    }

    /// How many tiles it holds.
    var tileCount: Int {
        slots.count
    }

    /// Whether it holds `key`'s tile (at some version: see `revision`).
    func holds(_ key: TileKey) -> Bool {
        key.level == level && slots[Self.slot(key.col, key.row)] != nil
    }

    /// Whether it holds every one of `keys`.
    func holdsAll(_ keys: [TileKey]) -> Bool {
        keys.allSatisfy(holds)
    }

    /// `key`'s compressed pixels, to carry into a newer raster without compressing them again.
    func blob(for key: TileKey) -> Blob? {
        guard key.level == level, let slot = slots[Self.slot(key.col, key.row)] else { return nil }
        guard slot.length > 0 else { return .empty }
        return .compressed(data.subdata(in: data.startIndex + slot.offset ..< data.startIndex + slot.offset + slot.length))
    }

    /// `key`'s tile, decompressed and labelled `revision`, or nil if it isn't held or doesn't decode.
    func restore(_ key: TileKey) -> Tile? {
        guard key.level == level, let slot = slots[Self.slot(key.col, key.row)] else { return nil }
        guard slot.length > 0 else {
            return Tile(image: nil, revision: revision)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: TileKey.side, height: TileKey.side, bitsPerComponent: 8,
                                  bytesPerRow: Self.bytesPerRow, space: space, bitmapInfo: TileBitmap.bitmapInfo),
              let target = ctx.data
        else { return nil }
        let decoded = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(target.assumingMemoryBound(to: UInt8.self), Self.tileBytes,
                                             base + slot.offset, slot.length, nil, COMPRESSION_LZFSE)
        }
        guard decoded == Self.tileBytes, let image = ctx.makeImage() else { return nil }
        return Tile(image: image, revision: revision)
    }
}

// MARK: - Bytes

private extension Data {
    mutating func append(le value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Reads little-endian integers from the start of a buffer, failing past its end.
private struct ByteReader {
    let raw: UnsafeRawBufferPointer
    var position = 0

    init(_ raw: UnsafeRawBufferPointer) {
        self.raw = raw
    }

    mutating func read<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard position + size <= raw.count else { return nil }
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[position ..< position + size])) }
        position += size
        return T(littleEndian: value)
    }

    /// Steps over `count` bytes; false past the end.
    mutating func skip(_ count: Int) -> Bool {
        guard position + count <= raw.count else { return false }
        position += count
        return true
    }
}
