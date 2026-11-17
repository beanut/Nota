import CoreGraphics
import Foundation
import UIKit

/// Every page's stroke geometry under one byte budget for the whole app (NOT-108): packed
/// (`PackedGeometry`), and the most recently drawn of it unpacked as well, in a smaller tier of its own, so
/// edits refilling the same strokes over and over don't unpack them each time. Least recently used
/// geometry is let go once a tier is over budget; it's unpacked, or built again from the stroke (~0.2 ms),
/// when a tile fill or an edit next needs it. All of it goes on a memory warning. Thread-safe: tile fills
/// look geometry up and keep what they build on their worker threads while the main thread edits.
///
/// Pages don't use it directly: each `CanvasDocument` has a `PageGeometry`, which keeps its strokes'
/// geometry here and knows which of it is still current.
final class GeometryCache: @unchecked Sendable { // `packed` and `unpacked` lock themselves
    /// The app's cache. 32 MB holds a dense 5k-stroke page (~20 MB packed) whole, so editing one never
    /// builds geometry, and 32 MB unpacked holds the ~500 dense strokes an edit or a zoomed-in view refills.
    static let shared = GeometryCache(budget: 32 << 20, unpackedBudget: 32 << 20)

    struct Key: Hashable {
        let page: Int
        let stroke: UUID
    }

    private let packedTier: ByteLRU<PackedGeometry>
    private let unpackedTier: ByteLRU<StrokeGeometry>
    private let pages = NSLock()
    private var nextPage = 0
    private var observer: NSObjectProtocol?

    init(budget: Int, unpackedBudget: Int = 0) {
        packedTier = ByteLRU(budget: budget)
        unpackedTier = ByteLRU(budget: unpackedBudget)
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                          object: nil, queue: nil) { [weak self] _ in
            self?.trim(to: 0)
        }
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
    }

    /// A key space of its own for a page.
    func makePage() -> Int {
        pages.withLock {
            nextPage += 1
            return nextPage
        }
    }

    /// The most packed bytes it holds before letting the least recently used geometry go.
    var budget: Int {
        packedTier.budget
    }

    /// The most unpacked bytes it holds.
    var unpackedBudget: Int {
        unpackedTier.budget
    }

    /// The packed bytes held, by the budget's measure.
    var byteCount: Int {
        packedTier.byteCount
    }

    /// The unpacked bytes held, by an estimate of what their `CGPath`s cost.
    var unpackedByteCount: Int {
        unpackedTier.byteCount
    }

    /// How many strokes' packed geometry is held.
    var count: Int {
        packedTier.count
    }

    /// Changes the packed budget, letting go of the oldest geometry if it's now over.
    func setBudget(_ budget: Int) {
        packedTier.setBudget(budget)
    }

    /// The packed geometry kept for `key`, now the most recently used.
    func packed(_ key: Key) -> PackedGeometry? {
        packedTier.value(key)
    }

    /// The unpacked geometry kept for `key`, now the most recently used.
    func unpacked(_ key: Key) -> StrokeGeometry? {
        unpackedTier.value(key)
    }

    /// Whether packed geometry is kept for `key` (without counting as a use).
    func contains(_ key: Key) -> Bool {
        packedTier.contains(key)
    }

    /// Keeps `packed` for `key`, letting go of the least recently used if that takes the cache over budget.
    func store(_ packed: PackedGeometry, for key: Key) {
        packedTier.store(packed, cost: packed.byteCount, for: key)
    }

    /// Keeps `geometry` (unpacked from `packed`) for `key` in the unpacked tier.
    func storeUnpacked(_ geometry: StrokeGeometry, from packed: PackedGeometry, for key: Key) {
        unpackedTier.store(geometry, cost: packed.unpackedByteCount, for: key)
    }

    func remove(_ key: Key) {
        packedTier.remove(key)
        unpackedTier.remove(key)
    }

    /// Lets go of every geometry of `page`.
    func removeAll(page: Int) {
        packedTier.removeAll { $0.page == page }
        unpackedTier.removeAll { $0.page == page }
    }

    /// Lets go of the least recently used geometry until at most `limit` packed bytes are held, and of all
    /// that's unpacked.
    func trim(to limit: Int) {
        packedTier.trim(to: limit)
        unpackedTier.trim(to: 0)
    }
}

/// Values by `GeometryCache.Key` under a byte budget, the least recently used let go first. What's let go
/// is released after the lock is.
final class ByteLRU<Value>: @unchecked Sendable { // every stored property is guarded by `lock`
    private final class Entry {
        let key: GeometryCache.Key
        let value: Value
        let cost: Int
        var newer: Entry?
        var older: Entry?

        init(key: GeometryCache.Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let lock = NSLock()
    private var entries: [GeometryCache.Key: Entry] = [:]
    private var newest: Entry?
    private var oldest: Entry?
    private var bytes = 0
    private var limit: Int

    init(budget: Int) {
        limit = budget
    }

    var budget: Int {
        lock.withLock { limit }
    }

    var byteCount: Int {
        lock.withLock { bytes }
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    func setBudget(_ budget: Int) {
        let dropped: [Entry] = lock.withLock {
            limit = budget
            return evict(to: budget)
        }
        withExtendedLifetime(dropped) {}
    }

    func value(_ key: GeometryCache.Key) -> Value? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            if newest !== entry {
                unlink(entry)
                linkFront(entry)
            }
            return entry.value
        }
    }

    func contains(_ key: GeometryCache.Key) -> Bool {
        lock.withLock { entries[key] != nil }
    }

    func store(_ value: Value, cost: Int, for key: GeometryCache.Key) {
        guard cost <= budget else { return }
        let dropped: [Entry] = lock.withLock {
            var dropped: [Entry] = []
            if let old = entries.removeValue(forKey: key) {
                unlink(old)
                dropped.append(old)
            }
            let entry = Entry(key: key, value: value, cost: cost)
            entries[key] = entry
            linkFront(entry)
            return dropped + evict(to: limit)
        }
        withExtendedLifetime(dropped) {}
    }

    func remove(_ key: GeometryCache.Key) {
        let dropped: Entry? = lock.withLock {
            guard let entry = entries.removeValue(forKey: key) else { return nil }
            unlink(entry)
            return entry
        }
        withExtendedLifetime(dropped) {}
    }

    func removeAll(where gone: (GeometryCache.Key) -> Bool) {
        let dropped: [Entry] = lock.withLock {
            let dropped = entries.values.filter { gone($0.key) }
            for entry in dropped {
                entries[entry.key] = nil
                unlink(entry)
            }
            return dropped
        }
        withExtendedLifetime(dropped) {}
    }

    func trim(to limit: Int) {
        let dropped: [Entry] = lock.withLock { evict(to: limit) }
        withExtendedLifetime(dropped) {}
    }

    // MARK: The list (under `lock`)

    private func evict(to limit: Int) -> [Entry] {
        var dropped: [Entry] = []
        while bytes > limit, let entry = oldest {
            entries[entry.key] = nil
            unlink(entry)
            dropped.append(entry)
        }
        return dropped
    }

    private func linkFront(_ entry: Entry) {
        entry.older = newest
        entry.newer = nil
        newest?.newer = entry
        newest = entry
        if oldest == nil {
            oldest = entry
        }
        bytes += entry.cost
    }

    private func unlink(_ entry: Entry) {
        if let newer = entry.newer {
            newer.older = entry.older
        } else {
            newest = entry.older
        }
        if let older = entry.older {
            older.newer = entry.newer
        } else {
            oldest = entry.newer
        }
        entry.newer = nil
        entry.older = nil
        bytes -= entry.cost
    }
}

/// One page's stroke geometry (NOT-108): shared by every canvas showing the page, its erasers and lasso,
/// and its tile fills. The geometry itself is kept in the app's `GeometryCache`, which lets the least
/// recently used go; each stroke's ink bounds are kept here for as long as the stroke is unchanged, so the
/// erasers and the lasso rarely need the geometry itself. Geometry doesn't depend on zoom: it's built once,
/// in page points.
///
/// Changing a stroke in place (the lasso, a late Pencil estimate, a restyle) must `forget` it. Geometry
/// built off the main thread from a snapshot of the strokes is only kept if none of them changed since
/// the snapshot's `generation`.
final class PageGeometry: @unchecked Sendable { // every stored property is guarded by `lock`
    let cache: GeometryCache
    private let page: Int
    private let lock = NSLock()
    private var bounds: [UUID: CGRect] = [:]
    /// Goes up whenever a stroke is forgotten; `modified` says when each was.
    private var currentGeneration = 0
    private var modified: [UUID: Int] = [:]
    private var built = 0

    init(cache: GeometryCache = .shared) {
        self.cache = cache
        page = cache.makePage()
    }

    deinit {
        cache.removeAll(page: page)
    }

    private func key(_ id: UUID) -> GeometryCache.Key {
        GeometryCache.Key(page: page, stroke: id)
    }

    /// The generation to hand a snapshot of the strokes taken now, for keeping what's built from it.
    var generation: Int {
        lock.withLock { currentGeneration }
    }

    /// `stroke`'s geometry as the page keeps it (`StrokeRenderer.keptGeometry`): kept unpacked, unpacked, or
    /// built. Any thread; `stroke` must be the page's stroke as it is now (the main thread), or as it was at
    /// `generation`. With `keeps` (the default), what's built or unpacked is kept for next time; without, it's
    /// only used (a first fill of a page only scrolled past, which never needs it again).
    func geometry(for stroke: Stroke, generation: Int? = nil, keeps: Bool = true) -> StrokeGeometry {
        let key = key(stroke.id)
        let current: Bool = lock.withLock { generation.map { (modified[stroke.id] ?? -1) <= $0 } ?? true }
        if current {
            if let unpacked = cache.unpacked(key) {
                return unpacked
            }
            if let packed = cache.packed(key) {
                let unpacked = packed.unpacked()
                if keeps {
                    keepUnpacked(unpacked, from: packed, for: stroke.id, builtAt: generation)
                }
                return unpacked
            }
        }
        let packed = PackedGeometry(StrokeRenderer.geometry(for: stroke))
        let unpacked = packed.unpacked()
        lock.withLock { built += 1 }
        if keeps, current {
            keep(packed, for: stroke.id, builtAt: generation)
            keepUnpacked(unpacked, from: packed, for: stroke.id, builtAt: generation)
        }
        return unpacked
    }

    /// How many geometries have been built from strokes for the page (rather than found kept).
    var builtCount: Int {
        lock.withLock { built }
    }

    /// `stroke`'s ink bounds (the main thread, `stroke` as it is now), without its geometry when they're known.
    func bounds(for stroke: Stroke) -> CGRect {
        if let known = cachedBounds(stroke.id) {
            return known
        }
        let packed = PackedGeometry(StrokeRenderer.geometry(for: stroke))
        keep(packed, for: stroke.id, builtAt: nil)
        lock.withLock { built += 1 }
        return packed.bounds
    }

    /// The ink bounds of stroke `id` when they're known.
    func cachedBounds(_ id: UUID) -> CGRect? {
        lock.withLock { bounds[id] }
    }

    /// The ink bounds of each of `ids` that are known, under one lock.
    func cachedBounds(_ ids: [UUID]) -> [CGRect?] {
        lock.withLock { ids.map { bounds[$0] } }
    }

    /// Whether stroke `id`'s geometry is kept now.
    func isKept(_ id: UUID) -> Bool {
        cache.contains(key(id))
    }

    /// Stroke `id`'s kept geometry, packed; nil when none is, or (with `generation`) the stroke changed since.
    func packed(for id: UUID, asOf generation: Int? = nil) -> PackedGeometry? {
        lock.withLock {
            if let generation, (modified[id] ?? -1) > generation {
                return nil
            }
            return cache.packed(key(id))
        }
    }

    /// Keeps geometry built for stroke `id`: from the stroke as it is now (`generation` nil), or as it was at
    /// `generation`, in which case it's dropped if the stroke changed since.
    func keep(_ geometry: StrokeGeometry, for id: UUID, builtAt generation: Int? = nil) {
        keep(PackedGeometry(geometry), for: id, builtAt: generation)
    }

    private func keep(_ packed: PackedGeometry, for id: UUID, builtAt generation: Int?) {
        lock.withLock {
            if let generation, (modified[id] ?? -1) > generation {
                return
            }
            bounds[id] = packed.bounds
            cache.store(packed, for: key(id))
        }
    }

    private func keepUnpacked(_ unpacked: StrokeGeometry, from packed: PackedGeometry, for id: UUID,
                              builtAt generation: Int?) {
        lock.withLock {
            if let generation, (modified[id] ?? -1) > generation {
                return
            }
            cache.storeUnpacked(unpacked, from: packed, for: key(id))
        }
    }

    /// Stroke `id` changed (or went): drops what's kept of it.
    func forget(_ id: UUID) {
        forget(CollectionOfOne(id))
    }

    /// `forget` for several strokes, as one change.
    func forget(_ ids: some Sequence<UUID>) {
        lock.withLock {
            currentGeneration += 1
            for id in ids {
                modified[id] = currentGeneration
                bounds[id] = nil
                cache.remove(key(id))
            }
        }
    }
}
