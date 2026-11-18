import QuartzCore
import UIKit

/// Which page rect each version of a vector layer's content changed, newest last, so a tile drawn at an
/// older version that no change since reached still counts as current (NOT-109).
struct VectorChangeLog: Sendable {
    private struct Entry {
        let version: Int
        let rect: CGRect
    }

    /// The most changes remembered: a tile older than the oldest is drawn again.
    static let limit = 64
    private var entries: [Entry] = []
    /// What changed before this version isn't known any more.
    private(set) var oldest: Int

    init(version: Int = 0) {
        oldest = version
    }

    /// The change to `version` touched `rect` (page points; `.null` for nothing).
    mutating func record(_ rect: CGRect, version: Int) {
        entries.append(Entry(version: version, rect: rect))
        if entries.count > Self.limit {
            oldest = entries.removeFirst().version
        }
    }

    /// Everything a page rect may have changed in from `from` to `to`: the union of the changes' rects
    /// (`.null` if none), or nil when that's no longer known (everything may have).
    func touched(from: Int, to: Int) -> CGRect? {
        guard from >= oldest, from <= to else { return nil }
        return entries.lazy.filter { $0.version > from && $0.version <= to }.reduce(CGRect.null) { $0.union($1.rect) }
    }
}

/// What a `VectorTileLayer` draws: page-space vectors (the template, the page's objects, its tape) frozen
/// at one version, drawable from any thread.
struct VectorTileContent: @unchecked Sendable { // immutable; `draw` only reads values it captured
    /// Names the content's tiles in the `TileCache` (their `TileKey.page`).
    let cacheID: UUID
    /// The version tiles drawn now are labelled with; one labelled otherwise is stale where `changes` say.
    let version: Int
    /// Tiles cover the page and nothing outside it is drawn.
    let pageBounds: CGRect
    let changes: VectorChangeLog
    /// The page rects anything is drawn in (nil: anywhere): a tile reaching none of them is empty, and
    /// kept so without drawing.
    let drawnRects: [CGRect]?
    /// Draws the page rect `rect` at `level` into `ctx`, which is addressed in page points and clipped to it.
    let draw: @Sendable (CGContext, CGRect, TileLevel) -> Void
    /// True when drawing any part costs about as much as drawing it all (a PDF page is read whole however
    /// little of it is drawn): the tiles in view are then drawn by one job, not by several in parallel.
    var drawsWhole = false

    func mayDraw(in rect: CGRect) -> Bool {
        drawnRects?.contains { $0.intersects(rect) } ?? true
    }

    /// Whether a tile of `key` labelled `revision` shows this version: it's labelled so, or nothing changed in
    /// it since.
    func isCurrent(_ revision: Int, for key: TileKey) -> Bool {
        guard revision != version else { return true }
        guard revision >= 0, revision < version, let touched = changes.touched(from: revision, to: version) else {
            return false
        }
        return !touched.intersects(key.rect)
    }
}

/// What a vector layer's fills have cost.
struct VectorFillStats: Equatable {
    /// Tiles drawn.
    var tilesFilled = 0
    /// Tiles nothing reaches, kept empty without drawing.
    var tilesEmpty = 0
    /// The fills' drawing time added up (CPU, across workers).
    var fillMilliseconds = 0.0
}

/// A canvas layer of page-space vectors drawn into tiles (NOT-109): the template, the objects under the
/// ink, the tape over it. The tiles go through the same `TileCache` and `RenderScheduler` as the committed
/// ink, at the same levels (device pixels per page point), so a pan at one zoom moves layers of cached
/// tiles and draws nothing on the main thread; a tile is drawn only where nothing is cached for it at the
/// level, or where the content changed (`VectorTileContent.changes`).
///
/// It follows the ink's settle rule: during a pan or pinch the level shown stays the last one, moved and
/// scaled; once the view settles at a new zoom, the new level's tiles in view are drawn and swapped in
/// together, so a level appears whole. Under it, where it has no tile yet (a pinch out, a pan uncovering
/// new ground), the resting (fitted) level's tiles show, masked away where the level above has tiles.
///
/// Main thread only, apart from the fills it runs on the scheduler.
@MainActor
final class VectorTileLayer {
    /// The host's view hierarchy holds it; the grids are laid out inside it in view points.
    let layer = CALayer()
    let cache: TileCache
    let scheduler: RenderScheduler
    private let current = TileLayerGrid()
    private let fallback = TileLayerGrid()
    private let fallbackHost = CALayer()
    private let fallbackMask = CAShapeLayer()

    private(set) var content: VectorTileContent?
    private(set) var transform = ViewTransform()
    private var size = CGSize.zero
    private(set) var scale: CGFloat = 2
    private var moving = false
    private var restingScale: CGFloat = 1
    /// The level whose tiles are on screen.
    private(set) var displayedLevel: TileLevel?
    /// Every tile on screen (both levels): the cache never evicts them.
    private var shownKeys = Set<TileKey>()
    private var fills: [TileKey: Ticket] = [:]
    private struct Ticket {
        let job: RenderJob
        let cacheID: UUID
        let version: Int
        let serial: Int
    }

    private var nextSerial = 0
    private(set) var stats = VectorFillStats()
    private let lifetime = RenderCancellation()
    private var reportedMoving = false
    /// Run once the layer is next settled (`isSettled`).
    private var settledActions: [() -> Void] = []
    /// Called when the tiles on screen changed (not when they only moved).
    var onPublish: (() -> Void)?
    /// What the last layout covered: a frame that only moves the view over the same tiles skips the lookups.
    private var lastLayout: LayoutKey?
    private var contentVersion = 0
    private struct LayoutKey: Equatable {
        let contentVersion: Int
        let shown: TileLevel
        let cols: ClosedRange<Int>?
        let rows: ClosedRange<Int>?
        let resting: TileLevel
        let moving: Bool
    }

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "transform": NSNull(),
        "sublayers": NSNull(), "path": NSNull(), "contents": NSNull()
    ]

    init(cache: TileCache = .shared, scheduler: RenderScheduler = .shared) {
        self.cache = cache
        self.scheduler = scheduler
        for layer in [layer, fallbackHost, fallbackMask] {
            layer.anchorPoint = .zero
            layer.actions = Self.noActions
        }
        fallbackMask.fillRule = .evenOdd
        fallbackHost.mask = fallbackMask
        fallbackHost.isHidden = true
        fallbackHost.addSublayer(fallback.layer)
        layer.addSublayer(fallbackHost)
        layer.addSublayer(current.layer)
        layer.isHidden = true
    }

    deinit {
        lifetime.cancel()
        scheduler.setGesture(false, for: ObjectIdentifier(self))
        cache.removeInterest(ObjectIdentifier(self))
    }

    // MARK: Content and placement

    /// Shows `content`, or nothing. Tiles cached for its `cacheID` at its version (or untouched since) are
    /// shown at once; the rest are drawn.
    func show(_ new: VectorTileContent?) {
        let old = content
        content = new
        if old?.cacheID != new?.cacheID || old?.version != new?.version {
            contentVersion &+= 1
        }
        if old?.cacheID != new?.cacheID {
            // Another page or paper: nothing of the old one stays on screen or is drawn any more.
            cancelFills { _, _ in true }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            current.clear()
            fallback.clear()
            fallbackHost.isHidden = true
            CATransaction.commit()
            displayedLevel = nil
            shownKeys = []
            if new == nil {
                cache.removeInterest(ObjectIdentifier(self))
            }
        }
        layout()
    }

    /// Follows the host: its bounds' size, display scale, the transform from page to view, whether it's
    /// moving (a pan, a pinch, a scroll) and the scale whose tiles are kept under the others (the fitted page's).
    func update(transform: ViewTransform, size: CGSize, scale: CGFloat, moving: Bool, restingScale: CGFloat) {
        if scale != self.scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            current.clear()
            fallback.clear()
            CATransaction.commit()
            displayedLevel = nil
            contentVersion &+= 1
        }
        if size != self.size {
            contentVersion &+= 1
        }
        self.transform = transform
        self.size = size
        self.scale = scale
        self.moving = moving
        self.restingScale = restingScale
        layout()
    }

    /// Drops what's on screen and every fill under way (the host's page left view).
    func clear() {
        show(nil)
    }

    func level(for t: ViewTransform) -> TileLevel {
        TileLevel(t, displayScale: scale)
    }

    var restingLevel: TileLevel {
        TileLevel(pixelsPerPoint: restingScale * scale)
    }

    private var visibleRect: CGRect {
        guard let content else { return .null }
        return transform.toCanvas(CGRect(origin: .zero, size: size)).intersection(content.pageBounds)
    }

    // MARK: Settled state

    /// True when the layer shows its content as it is, sharp at the current transform: the tiles in view
    /// are at the transform's own level and current, and none of them is being drawn. Always true with nothing to show.
    var isSettled: Bool {
        guard let content, size != .zero else { return true }
        guard displayedLevel == level(for: transform) else { return false }
        let keys = TileKey.keys(covering: visibleRect, page: content.cacheID, level: level(for: transform))
        return zip(keys, cache.tiles(for: keys)).allSatisfy { key, tile in
            guard let tile else { return false }
            return content.isCurrent(tile.revision, for: key)
        }
    }

    /// True while tiles are being drawn.
    var isFilling: Bool {
        !fills.isEmpty
    }

    /// Runs `action` once the layer is settled (now, if it is).
    func whenSettled(_ action: @escaping () -> Void) {
        if isSettled {
            action()
        } else {
            settledActions.append(action)
        }
    }

    // MARK: Layout

    /// Shows the tiles for the current transform and asks for those missing or stale.
    func layout() {
        reportMoving()
        guard let content, size != .zero else {
            if !layer.isHidden {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.isHidden = true
                CATransaction.commit()
            }
            runSettledActions()
            return
        }
        let t = transform, want = level(for: t)
        if displayedLevel == nil {
            displayedLevel = want
        } else if displayedLevel != want, !moving, coverage(at: want, content: content).complete {
            // The new level is drawn wherever the view is: swap it in whole.
            displayedLevel = want
            contentVersion &+= 1
        }
        guard let shown = displayedLevel else { return }
        requestFills(shown: shown, want: want, content: content)
        let range = TileKey.range(covering: visibleRect, level: shown)
        let key = LayoutKey(contentVersion: contentVersion, shown: shown, cols: range?.cols, rows: range?.rows,
                            resting: restingLevel, moving: moving)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.isHidden = false
        layer.frame = CGRect(origin: .zero, size: size)
        fallbackHost.frame = layer.bounds
        fallbackMask.frame = layer.bounds
        if key == lastLayout {
            place(at: t)
            return
        }
        lastLayout = key
        let held = coverage(at: shown, content: content)
        let changed = current.show(held.present.compactMap { key, tile in tile.image.map { (key, $0) } }, level: shown,
                                   displayScale: scale)
        shownKeys = Set(held.present.map(\.key))
        let resting = restingLevel
        if held.complete || shown == resting {
            fallback.clear()
            fallbackHost.isHidden = true
            covered = []
        } else {
            let rested = coverage(at: resting, content: content).present
            shownKeys.formUnion(rested.map(\.key))
            fallback.show(rested.compactMap { key, tile in tile.image.map { (key, $0) } }, level: resting,
                          displayScale: scale)
            fallbackHost.isHidden = rested.isEmpty
            covered = TileLayerGrid.merged(held.present.map(\.key))
        }
        place(at: t)
        cache.setInterest(ObjectIdentifier(self), page: content.cacheID,
                          visible: shownKeys.union(fills.keys.filter { $0.level == want }), resting: resting,
                          shown: [shown, want])
        if changed {
            onPublish?()
        }
        runSettledActions()
    }

    /// The displayed level's tiles, as page rects: holes in the resting level's mask.
    private var covered: [CGRect] = []

    private func place(at t: ViewTransform) {
        current.place(at: t, displayScale: scale)
        guard !fallbackHost.isHidden else { return }
        fallback.place(at: t, displayScale: scale)
        let path = CGMutablePath()
        path.addRect(layer.bounds.insetBy(dx: -1, dy: -1))
        for rect in covered {
            // A pixel inside the tiles, so the level below runs under their edge rather than leaving a hairline.
            path.addRect(t.toView(rect).insetBy(dx: 1 / scale, dy: 1 / scale))
        }
        fallbackMask.path = path
    }

    /// The cached tiles of `level` in view (stale ones too: shown until their redraw lands), and whether
    /// every tile in view is cached and current.
    private func coverage(at level: TileLevel, content: VectorTileContent)
        -> (present: [(key: TileKey, tile: Tile)], complete: Bool) {
        guard let (cols, rows) = TileKey.range(covering: visibleRect, level: level) else { return ([], true) }
        let expected = cols.count * rows.count
        if expected > 400 {
            // Zoomed far out over a fine level: look through what's cached rather than every key in view.
            let present = cache.tiles(page: content.cacheID).filter {
                $0.key.level == level && cols.contains($0.key.col) && rows.contains($0.key.row)
            }.map { (key: $0.key, tile: $0.value) }
            return (present, present.count == expected && present.allSatisfy { content.isCurrent($0.tile.revision, for: $0.key) })
        }
        let keys = TileKey.keys(covering: visibleRect, page: content.cacheID, level: level)
        var complete = true
        var present: [(key: TileKey, tile: Tile)] = []
        for (key, tile) in zip(keys, cache.tiles(for: keys)) {
            guard let tile else {
                complete = false
                continue
            }
            present.append((key, tile))
            if !content.isCurrent(tile.revision, for: key) {
                complete = false
            }
        }
        return (present, complete)
    }

    private func reportMoving() {
        guard moving != reportedMoving else { return }
        reportedMoving = moving
        scheduler.setGesture(moving, for: ObjectIdentifier(self))
    }

    private func runSettledActions() {
        guard !settledActions.isEmpty, isSettled else { return }
        let actions = settledActions
        settledActions = []
        for action in actions {
            action()
        }
    }

    // MARK: Fills

    /// Asks for the tiles in view that aren't cached and current: settled, at the transform's level (and a
    /// ring of a tile around the view); moving, at the level shown, when only a few are missing (a pan
    /// uncovering an edge), never a whole level mid-pinch. The resting level's tiles in view are asked for
    /// too, to show under the others while a pinch or pan uncovers ground.
    private func requestFills(shown: TileLevel, want: TileLevel, content: VectorTileContent) {
        var wanted: [Wanted] = []
        let visible = visibleRect
        guard !visible.isNull, !visible.isEmpty else { return }
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        func rank(_ key: TileKey) -> Double {
            let dx = key.rect.midX - middle.x, dy = key.rect.midY - middle.y
            return Double(dx * dx + dy * dy)
        }
        func missing(_ keys: [TileKey]) -> [TileKey] {
            zip(keys, cache.tiles(for: keys)).compactMap { key, tile in
                tile.map { content.isCurrent($0.revision, for: key) } == true ? nil : key
            }
        }
        func count(at level: TileLevel) -> Int {
            TileKey.range(covering: visible, level: level).map { $0.cols.count * $0.rows.count } ?? 0
        }
        let target = moving ? shown : want
        // Mid-gesture, a level much finer than the view (a pinch out from a high zoom) isn't filled whole.
        let inViewKeys = !moving || count(at: target) <= 256
            ? TileKey.keys(covering: visible, page: content.cacheID, level: target) : []
        let inView = missing(inViewKeys)
        if !moving || inView.count <= 48 {
            wanted += inView.map { Wanted(key: $0, priority: .visible, rank: rank($0)) }
        }
        if !moving {
            let pad = CGFloat(TileKey.side) / target.pixelsPerPoint
            let ring = visible.insetBy(dx: -pad, dy: -pad).intersection(content.pageBounds)
            let inner = Set(inViewKeys)
            wanted += missing(TileKey.keys(covering: ring, page: content.cacheID, level: target).filter { !inner.contains($0) })
                .map { Wanted(key: $0, priority: .margin, rank: rank($0)) }
        }
        let resting = restingLevel
        if resting != target {
            // The whole page at the resting level (the fitted page: a few dozen tiles), so a pinch out or a
            // pan finds it under the level shown; mid-gesture, what's in view first.
            let page = TileKey.range(covering: content.pageBounds, level: resting).map { $0.cols.count * $0.rows.count } ?? 0
            let area = moving || page > 256 ? visible : content.pageBounds
            if moving || page <= 256 || count(at: resting) <= 256 {
                let rested = missing(TileKey.keys(covering: area, page: content.cacheID, level: resting))
                wanted += rested.map { Wanted(key: $0, priority: moving ? .visible : .otherLevel, rank: rank($0)) }
            }
        }
        // Fills no longer wanted (a level passed through, the ground left behind) are dropped.
        let keep = Set(wanted.map(\.key))
        cancelFills { key, ticket in
            ticket.cacheID != content.cacheID || ticket.version != content.version
                || (!keep.contains(key) && key.level != target && key.level != resting)
        }
        var toFill: [Wanted] = []
        var storedEmpty = false
        for want in wanted {
            let key = want.key, priority = want.priority, rank = want.rank
            if let ticket = fills[key] {
                // Being drawn at this version already (its block's priority is its most urgent tile's).
                if priority < ticket.job.priority {
                    scheduler.reprioritise(ticket.job, to: priority, rank: rank)
                }
                continue
            }
            if !content.mayDraw(in: key.rect) {
                cache.store(Tile(image: nil, revision: content.version), for: key)
                stats.tilesEmpty += 1
                storedEmpty = true
                continue
            }
            toFill.append(want)
        }
        if storedEmpty {
            contentVersion &+= 1
        }
        // Neighbouring tiles are drawn together, a block at a time: what a page's vectors cost to draw (a
        // PDF's content is read whole however little of it a tile shows) is paid once per block, not per tile.
        struct Block: Hashable {
            let level: TileLevel
            let priority: RenderPriority
            let col: Int
            let row: Int
        }
        var blocks: [Block: [(key: TileKey, rank: Double)]] = [:]
        for item in toFill {
            let key = item.key, priority = item.priority, rank = item.rank
            let block: Block
            if content.drawsWhole, priority != .margin {
                block = Block(level: key.level, priority: priority, col: 0, row: 0)
            } else {
                let side = content.drawsWhole ? Self.blockSide * 2 : Self.blockSide
                block = Block(level: key.level, priority: priority, col: key.col / side, row: key.row / side)
            }
            blocks[block, default: []].append((key, rank))
        }
        let jobs = blocks.map { block, members in
            fillJob(members.map(\.key), content: content, priority: block.priority, rank: members.map(\.rank).min() ?? 0)
        }
        if !jobs.isEmpty {
            scheduler.submit(jobs)
        }
    }

    /// A tile asked for, how soon, and how near the middle of the view.
    private struct Wanted {
        let key: TileKey
        let priority: RenderPriority
        let rank: Double
    }

    /// Tiles a side drawn by one job, at most (twice that for content that `drawsWhole`, beyond the view).
    static let blockSide = 4

    private struct FillOutput {
        let tiles: [(key: TileKey, tile: Tile)]
        let milliseconds: Double
    }

    private func fillJob(_ keys: [TileKey], content: VectorTileContent, priority: RenderPriority, rank: Double) -> RenderJob {
        nextSerial += 1
        let serial = nextSerial
        let job = RenderJob(priority: priority, rank: rank, cancellation: lifetime, work: { job -> FillOutput? in
            guard !job.isCancelled else { return nil }
            return Self.fill(keys, content: content)
        }, publish: { [weak self] (output: FillOutput?) in
            self?.fillDidLand(keys, serial: serial, output: output)
        })
        let ticket = Ticket(job: job, cacheID: content.cacheID, version: content.version, serial: serial)
        for key in keys {
            fills[key] = ticket
        }
        return job
    }

    /// Draws the tiles of `keys` (one level) of `content`: the rect they span once, then cut into tiles; a
    /// tile left blank keeps no bitmap. Any thread.
    private nonisolated static func fill(_ keys: [TileKey], content: VectorTileContent) -> FillOutput? {
        guard let first = keys.first else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        let level = first.level
        let pixels = keys.dropFirst().reduce(first.pixelRect) { $0.union($1.pixelRect) }
        let rect = CGRect(x: pixels.minX / level.pixelsPerPoint, y: pixels.minY / level.pixelsPerPoint,
                          width: pixels.width / level.pixelsPerPoint, height: pixels.height / level.pixelsPerPoint)
        guard let ctx = TileBitmap.context(pixelRect: pixels, level: level), let data = ctx.data else { return nil }
        ctx.clip(to: rect)
        content.draw(ctx, rect, level)
        let side = TileKey.side
        var tiles: [(key: TileKey, tile: Tile)] = []
        for key in keys {
            let x0 = Int(key.pixelRect.minX - pixels.minX), y0 = Int(key.pixelRect.minY - pixels.minY)
            // Row 0 of the bitmap's memory is the top of the rect drawn (page y grows down it).
            var blank = true
            for row in 0 ..< side where blank {
                let line = UnsafeRawBufferPointer(start: data + (y0 + row) * ctx.bytesPerRow + x0 * 4, count: side * 4)
                blank = !line.contains { $0 != 0 }
            }
            guard !blank else {
                tiles.append((key, Tile(image: nil, revision: content.version)))
                continue
            }
            guard let tile = TileBitmap.context(for: key), let target = tile.data else { return nil }
            for row in 0 ..< side {
                memcpy(target + row * tile.bytesPerRow, data + (y0 + row) * ctx.bytesPerRow + x0 * 4, side * 4)
            }
            tiles.append((key, Tile(image: tile.makeImage(), revision: content.version)))
        }
        return FillOutput(tiles: tiles, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }

    /// Draws `key`'s tile of `content` now, on this thread (tests' references).
    nonisolated static func drawTile(_ key: TileKey, content: VectorTileContent) -> CGImage? {
        fill([key], content: content)?.tiles.first?.tile.image
    }

    private func fillDidLand(_ keys: [TileKey], serial: Int, output: FillOutput?) {
        for key in keys where fills[key]?.serial == serial {
            fills[key] = nil
        }
        if let output {
            for (key, tile) in output.tiles {
                cache.storeIfNewer(tile, for: key)
            }
            stats.tilesFilled += output.tiles.count
            stats.fillMilliseconds += output.milliseconds
        }
        contentVersion &+= 1
        scheduler.afterBatch(self) { [weak self] in self?.layout() }
    }

    /// Cancels the fill jobs every one of whose tiles `drop` picks; a job drawing a tile still wanted goes on.
    private func cancelFills(where drop: (TileKey, Ticket) -> Bool) {
        struct Job {
            let ticket: Ticket
            var keys: [TileKey] = []
            var dropped = true
        }
        var bySerial: [Int: Job] = [:]
        for (key, ticket) in fills {
            var entry = bySerial[ticket.serial] ?? Job(ticket: ticket)
            entry.keys.append(key)
            entry.dropped = entry.dropped && drop(key, ticket)
            bySerial[ticket.serial] = entry
        }
        for entry in bySerial.values where entry.dropped {
            entry.ticket.job.cancel()
            for key in entry.keys {
                fills[key] = nil
            }
        }
    }

    // MARK: Drawing elsewhere

    /// Draws what the layer shows of `viewRect` (view points) into `ctx`, addressed in view points with the
    /// page at `t`: the displayed level's tiles when they cover it, the vectors otherwise. The live layer's
    /// backdrop under multiply ink.
    func draw(in ctx: CGContext, at t: ViewTransform, viewRect: CGRect) {
        guard let content, t.scale > 0 else { return }
        let pageRect = t.toCanvas(viewRect).intersection(content.pageBounds)
        guard !pageRect.isNull, !pageRect.isEmpty else { return }
        if let level = displayedLevel {
            let keys = TileKey.keys(covering: pageRect, page: content.cacheID, level: level)
            let tiles = keys.count <= 64 ? cache.tiles(for: keys) : []
            if !keys.isEmpty, tiles.count == keys.count, tiles.allSatisfy({ $0 != nil }) {
                ctx.saveGState()
                ctx.clip(to: t.toView(pageRect))
                ctx.interpolationQuality = .high
                for (key, tile) in zip(keys, tiles) {
                    guard let image = tile?.image else { continue }
                    let rect = t.toView(key.rect)
                    ctx.saveGState()
                    // View space is y-down; Core Graphics draws images y-up.
                    ctx.translateBy(x: rect.minX, y: rect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                    ctx.restoreGState()
                }
                ctx.restoreGState()
                return
            }
        }
        ctx.saveGState()
        ctx.concatenate(t.affine)
        ctx.clip(to: pageRect)
        content.draw(ctx, pageRect, level(for: t))
        ctx.restoreGState()
    }

    /// The tiles on screen at the displayed level, for tests.
    var shownImages: [(key: TileKey, image: CGImage)] {
        current.shownImages
    }
}
