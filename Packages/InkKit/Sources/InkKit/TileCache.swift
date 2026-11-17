import CoreGraphics
import Foundation

/// How finely a set of tiles is drawn: device pixels per page point. A canvas settled at a transform
/// shows the level `transform.scale × displayScale` exactly, so a tile pixel is a screen pixel.
struct TileLevel: Hashable, Sendable {
    let pixelsPerPoint: CGFloat

    init(pixelsPerPoint: CGFloat) {
        self.pixelsPerPoint = pixelsPerPoint
    }

    /// The level a view at `transform` on a display of `displayScale` shows.
    init(_ transform: ViewTransform, displayScale: CGFloat) {
        pixelsPerPoint = transform.scale * displayScale
    }

    /// How close a gesture has to end to a cached level for the view to snap to it (2%), so returning to
    /// the fitted page or a zoom already drawn fills nothing.
    static let snapTolerance: CGFloat = 0.02

    func isNear(_ other: TileLevel) -> Bool {
        abs(pixelsPerPoint / other.pixelsPerPoint - 1) <= Self.snapTolerance
    }
}

/// One tile: `side × side` device pixels of one page at one level. Tile (col, row) covers page pixels
/// [col × side, (col + 1) × side) × [row × side, (row + 1) × side) at that level, so tiles are in page
/// space and serve every canvas showing the page at that level, wherever it puts the page.
struct TileKey: Hashable, Sendable {
    /// The tile edge in device pixels (NOT-99: small enough to fill in a few milliseconds at 6×, big
    /// enough that a screen is about a hundred layers).
    static let side = 256

    /// The page's `CanvasDocument.cacheID`.
    let page: UUID
    let level: TileLevel
    let col: Int
    let row: Int

    /// The tile in page pixels at its level.
    var pixelRect: CGRect {
        let s = CGFloat(Self.side)
        return CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)
    }

    /// The tile in page points.
    var rect: CGRect {
        let s = CGFloat(Self.side) / level.pixelsPerPoint
        return CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)
    }

    /// The columns and rows of the tiles at `level` that cover `rect` (page points), or nil for an empty rect.
    static func range(covering rect: CGRect, level: TileLevel) -> (cols: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        guard !rect.isNull, !rect.isEmpty, !rect.isInfinite, level.pixelsPerPoint > 0 else { return nil }
        let s = CGFloat(side) / level.pixelsPerPoint
        let c0 = Int((rect.minX / s).rounded(.down)), c1 = Int((rect.maxX / s).rounded(.up)) - 1
        let r0 = Int((rect.minY / s).rounded(.down)), r1 = Int((rect.maxY / s).rounded(.up)) - 1
        guard c0 <= c1, r0 <= r1 else { return nil }
        return (c0 ... c1, r0 ... r1)
    }

    /// The tiles of `page` at `level` that cover `rect` (page points), row by row.
    static func keys(covering rect: CGRect, page: UUID, level: TileLevel) -> [TileKey] {
        guard let (cols, rows) = range(covering: rect, level: level) else { return [] }
        return rows.flatMap { r in cols.map { TileKey(page: page, level: level, col: $0, row: r) } }
    }
}

/// A tile's pixels and the version of the page's ink they show.
struct Tile: @unchecked Sendable { // CGImage is immutable
    /// Nil when no ink reaches the tile: an empty tile keeps no bitmap.
    let image: CGImage?
    /// The `CanvasDocument.inkVersion` whose ink the tile shows exactly (it moves on mid-gesture too, so
    /// an erase or a lasso drag under way has one), or `Tile.unknownRevision` when the tile shows something
    /// no version describes. A tile whose version isn't the page's is stale: still shown, until its refill
    /// lands, so nothing flashes blank; the page's `inkChanges` say where it's stale (NOT-104).
    let revision: Int

    static let unknownRevision = -1

    /// What the tile costs the cache's budget. An empty tile costs a little, so they're evicted too.
    var bytes: Int {
        image == nil ? 64 : TileKey.side * TileKey.side * 4
    }
}

/// Every page's committed-ink tiles, shared by every canvas, embedded page and zoom panel that shows a
/// page, so ink drawn once at a level is reused across pans, re-centred render windows and canvases
/// coming and going. Thread-safe: render jobs store tiles from their queue while the main thread reads.
///
/// Least recently used tiles are evicted once the cache is over its byte budget: tiles no canvas shows
/// first, then those of a page's resting level (the fitted page, kept for zooming back out), never one
/// that's on screen.
final class TileCache: @unchecked Sendable { // every stored property is guarded by `lock`
    static let shared = TileCache(byteBudget: 192 << 20)

    let byteBudget: Int
    private let lock = NSLock()
    private var entries: [TileKey: Entry] = [:]
    private var pages: [UUID: Set<TileKey>] = [:]
    private var clock: UInt64 = 0
    private var interests: [ObjectIdentifier: Interest] = [:]
    private var storedBytes = 0

    private struct Entry {
        var tile: Tile
        var lastUse: UInt64
    }

    /// What one canvas (or zoom panel) is showing of a page: its tiles are never evicted, and its resting
    /// level goes after other levels.
    private struct Interest {
        let page: UUID
        let visible: Set<TileKey>
        let resting: TileLevel?
        let shown: [TileLevel]
    }

    init(byteBudget: Int) {
        self.byteBudget = byteBudget
    }

    /// The bytes of every tile held.
    var bytes: Int {
        lock.withLock { storedBytes }
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    func tile(for key: TileKey) -> Tile? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock &+= 1
            entry.lastUse = clock
            entries[key] = entry
            return entry.tile
        }
    }

    /// The tiles held for `keys`, in order, under one lock.
    func tiles(for keys: [TileKey]) -> [Tile?] {
        lock.withLock {
            clock &+= 1
            return keys.map { key in
                guard var entry = entries[key] else { return nil }
                entry.lastUse = clock
                entries[key] = entry
                return entry.tile
            }
        }
    }

    /// Every tile held for `page`.
    func tiles(page: UUID) -> [TileKey: Tile] {
        lock.withLock {
            var result: [TileKey: Tile] = [:]
            for key in pages[page] ?? [] {
                result[key] = entries[key]?.tile
            }
            return result
        }
    }

    /// The levels `page` has tiles at.
    func levels(page: UUID) -> Set<TileLevel> {
        lock.withLock { Set((pages[page] ?? []).map(\.level)) }
    }

    /// Keeps `tile` for `key`, replacing what was there, then evicts down to the budget.
    func store(_ tile: Tile, for key: TileKey) {
        lock.withLock {
            put(tile, for: key)
            evictIfNeeded()
        }
    }

    /// Keeps `tile` unless the cache already holds a newer revision of the key (a refill that lost a race).
    func storeIfNewer(_ tile: Tile, for key: TileKey) {
        lock.withLock {
            // Tiles of no known version always land.
            if let held = entries[key]?.tile, held.revision > tile.revision, tile.revision >= 0 {
                return
            }
            put(tile, for: key)
            evictIfNeeded()
        }
    }

    private func put(_ tile: Tile, for key: TileKey) {
        clock &+= 1
        if let old = entries[key] {
            storedBytes -= old.tile.bytes
        }
        entries[key] = Entry(tile: tile, lastUse: clock)
        pages[key.page, default: []].insert(key)
        storedBytes += tile.bytes
    }

    private func remove(_ key: TileKey) {
        guard let old = entries.removeValue(forKey: key) else { return }
        storedBytes -= old.tile.bytes
        pages[key.page]?.remove(key)
        if pages[key.page]?.isEmpty == true {
            pages[key.page] = nil
        }
    }

    /// A change to `page` from revision `from` to `to` touched only `rect` (page points): every tile at
    /// `from` that doesn't reach it shows `to` just as well.
    func advance(page: UUID, from: Int, to: Int, outside rect: CGRect) {
        guard from >= 0, to >= 0 else { return }
        lock.withLock {
            for key in pages[page] ?? [] {
                guard let entry = entries[key], entry.tile.revision == from, !key.rect.intersects(rect) else { continue }
                entries[key]?.tile = Tile(image: entry.tile.image, revision: to)
            }
        }
    }

    /// Each tile of `tiles` still at the revision it says shows `revision` just as well (no change since
    /// reached it): it's labelled so, keeping its pixels.
    func relabel(_ tiles: [(key: TileKey, from: Int)], to revision: Int) {
        lock.withLock {
            for (key, from) in tiles {
                guard let entry = entries[key], entry.tile.revision == from else { continue }
                entries[key]?.tile = Tile(image: entry.tile.image, revision: revision)
            }
        }
    }

    /// The ink of `page` in `rect` (page points; nil: anywhere) isn't what the tiles' versions say, though
    /// the document logged no change there: the tiles there, at every level, are marked as showing no
    /// known version and are filled again whole. They keep their pixels, to show until their refills land.
    func invalidate(page: UUID, rect: CGRect? = nil) {
        lock.withLock {
            for key in pages[page] ?? [] {
                guard let entry = entries[key], entry.tile.revision != Tile.unknownRevision,
                      rect.map({ key.rect.intersects($0) }) ?? true
                else { continue }
                entries[key]?.tile = Tile(image: entry.tile.image, revision: Tile.unknownRevision)
            }
        }
    }

    /// Forgets `page`'s tiles at every level but `kept`.
    func removeAll(page: UUID, except kept: TileLevel) {
        lock.withLock {
            for key in pages[page] ?? [] where key.level != kept {
                remove(key)
            }
        }
    }

    /// Forgets every tile of `page` (the page went away).
    func removeAll(page: UUID) {
        lock.withLock {
            for key in pages[page] ?? [] {
                remove(key)
            }
            interests = interests.filter { $0.value.page != page }
        }
    }

    /// `owner` shows `visible` (never evicted) of `page`, at the levels `shown`, and keeps `resting`'s tiles
    /// over other levels. Off-screen tiles of a level shown (the margin a pan finds next) go after those of
    /// levels nobody shows (one zoomed through, NOT-105), before the resting level's.
    func setInterest(_ owner: ObjectIdentifier, page: UUID, visible: Set<TileKey>, resting: TileLevel?,
                     shown: [TileLevel] = []) {
        lock.withLock {
            interests[owner] = Interest(page: page, visible: visible, resting: resting, shown: shown)
            evictIfNeeded()
        }
    }

    func removeInterest(_ owner: ObjectIdentifier) {
        lock.withLock {
            interests[owner] = nil
        }
    }

    /// Evicts least recently used tiles until the cache is within 90% of its budget: tiles of levels no one
    /// shows first, then off-screen tiles of levels shown, then resting-level tiles, never a visible one.
    private func evictIfNeeded() {
        guard storedBytes > byteBudget else { return }
        var visible = Set<TileKey>()
        var resting = Set<PageLevel>()
        var shown = Set<PageLevel>()
        for interest in interests.values {
            visible.formUnion(interest.visible)
            if let level = interest.resting {
                resting.insert(PageLevel(page: interest.page, level: level))
            }
            for level in interest.shown {
                shown.insert(PageLevel(page: interest.page, level: level))
            }
        }
        let candidates = entries.filter { !visible.contains($0.key) }.map { key, entry in
            let level = PageLevel(page: key.page, level: key.level)
            return (key: key, rank: resting.contains(level) ? 2 : shown.contains(level) ? 1 : 0, lastUse: entry.lastUse)
        }.sorted { ($0.rank, $0.lastUse) < ($1.rank, $1.lastUse) }
        let target = byteBudget / 10 * 9
        for candidate in candidates {
            guard storedBytes > target else { break }
            remove(candidate.key)
        }
    }

    private struct PageLevel: Hashable {
        let page: UUID
        let level: TileLevel
    }
}
