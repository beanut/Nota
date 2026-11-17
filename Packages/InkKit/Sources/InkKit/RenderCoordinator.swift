import QuartzCore
import UIKit

/// What a `RenderCoordinator` needs from the view it draws a page's committed ink for. The coordinator
/// knows nothing of touches, gestures or tools: the host tells it where the page is and what changed,
/// and hears when pixels land.
@MainActor
protocol RenderCoordinatorHost: AnyObject {
    /// The transform the committed ink should end up sharp at: the view's current pan and zoom.
    var renderTransform: ViewTransform { get }
    /// The area the committed surface covers, in view points.
    var renderBounds: CGRect { get }
    /// The transform that shows the whole page (or, embedded, where the host put it).
    func fittedTransform() -> ViewTransform
    /// The scale whose tiles are kept for the page above other levels while the view is zoomed, and
    /// shown under the current level where it has no tiles yet: the fitted page, or in continuous
    /// scrolling the column at zoom 1.
    var restingScale: CGFloat { get }
    /// True while a pinch, pan or scroll is moving the view: nothing is filled at a scale still changing.
    var isMoving: Bool { get }
    /// True while the page's strokes are mid-edit (an erase or a lasso drag): a render then shows no
    /// revision of the document.
    var isEditingInk: Bool { get }
    /// True while a stroke is being drawn.
    var hasLiveStroke: Bool { get }
    /// Whether some of the stroke's samples still expect refined force or tilt.
    func hasOutstandingEstimates(for strokeID: UUID) -> Bool
    /// A render was asked for before the surface has a size: lay the view out, which sizes it.
    func renderCoordinatorNeedsLayout()
    /// The committed tiles on screen changed (`underlay`; anything drawing over them may need them).
    func renderCoordinatorDidPublish()
    /// A finished stroke is now in the committed ink, so the live layer can stop showing `canvasRect` for it.
    func renderCoordinatorDidDrawPending(canvasRect: CGRect)
}

/// A finished stroke that's waiting to be drawn into the committed ink, shown by the live layer meanwhile.
/// Waits up to its deadline for its samples' estimated force and tilt to be refined.
final class PendingStroke: @unchecked Sendable { // main thread only; render jobs carry it back there
    var live: LiveStroke
    var geometry: StrokeGeometry
    var bounds: CGRect
    var deadline: CFTimeInterval
    var submitted = false
    var geometryDirty = false
    /// The document's revision before the stroke was added, and with it added (and every estimate
    /// update since applied): drawing it takes a tile at the first to the second.
    let revisionBefore: Int
    var revisionAfter: Int

    init(live: LiveStroke, geometry: StrokeGeometry, deadline: CFTimeInterval, revisionBefore: Int,
         revisionAfter: Int) {
        self.live = live
        self.geometry = geometry
        bounds = geometry.bounds
        self.deadline = deadline
        self.revisionBefore = revisionBefore
        self.revisionAfter = revisionAfter
    }
}

/// How much filling the coordinator has done, for the benchmarks.
struct FillStats: Equatable {
    var jobs = 0
    var tilesFilled = 0
    var tilesRestored = 0
    /// Wall time of the render jobs, in milliseconds.
    var milliseconds = 0.0
}

/// The committed side of a canvas (NOT-100), drawn as page-space tiles (NOT-102): which tiles the view
/// needs, filling the missing and stale ones off the main thread into the shared `TileCache`, showing
/// them as layers, drawing finished strokes into the tiles they reach, the geometry cache, revision
/// tracking, the page's `TileRaster`, and the zoom window panel's renders.
///
/// Settled, the view shows the tiles of its own level (`scale × displayScale`, the offset on whole
/// device pixels), so its pixels are what drawing the page whole at that transform gives. A pan at that
/// level fills only tiles not cached yet; a pinch fills nothing until it ends, showing the last level
/// scaled over the resting (fitted) level; then the new level's visible tiles are filled and swapped in.
///
/// Main thread only, apart from what it runs on its render queue.
@MainActor
final class RenderCoordinator {
    let document: CanvasDocument
    /// True for one page among several in continuous scrolling: no page raster is kept.
    let isEmbedded: Bool
    weak var host: RenderCoordinatorHost?
    let cache: TileCache
    let filler: TileFiller

    /// The layer showing the committed ink. The host puts it in its view hierarchy; the coordinator sizes it
    /// (`resize(to:scale:)`) and lays its tiles out at the host's transform (`updateLayerTransform()`).
    let layer = CALayer()
    /// The displayed level's tiles, over the resting level's where the displayed level has none.
    private let current = TileLayerGrid()
    private let fallback = TileLayerGrid()
    private let fallbackHost = CALayer()
    private let fallbackMask = CAShapeLayer()

    /// The level whose tiles are on screen (nil before any are).
    private(set) var displayedLevel: TileLevel?
    /// The last transform the tiles were laid out at while showing its own level.
    private(set) var displayedTransform = ViewTransform()
    /// True while a render job is running on the render queue.
    private(set) var isRendering = false
    private var renderRequested = false
    private var cancellation = RenderCancellation()
    private(set) var fillStats = FillStats()
    /// The page's revision at the last `invalidate`: one with the same revision changed ink the revision
    /// doesn't account for.
    private var lastInvalidatedRevision = -1
    /// What tiles filled mid-edit (an erase or a lasso drag under way, which change strokes without moving
    /// the revision on) are labelled: a new one at every change, so the tiles in view are known to show the
    /// latest change, while no revision describes them.
    private var editLabel = Tile.unknownRevision - 1
    /// The tiles on screen (both levels), which the cache mustn't evict.
    private var shownKeys = Set<TileKey>()
    /// Goes up whenever the cached tiles this view could show may have changed (a job landed, an edit), so
    /// a pan or pinch frame that only moves the view skips looking the tiles up again.
    private var contentVersion = 0
    /// What the last layout and fill request were for; equal again means nothing new to show or fill.
    private var lastLayout: LayoutKey?
    private var lastFillRequest: LayoutKey?
    /// Which tiles a layout or fill request covered, and against what.
    private struct LayoutKey: Equatable {
        let version: Int
        let revision: Int
        let shown: TileLevel?
        let want: TileLevel
        let cols: ClosedRange<Int>?
        let rows: ClosedRange<Int>?
        let moving: Bool
    }

    /// `level`'s tiles in view at `t` (with a tile's margin), against what's cached now. `want` is the level
    /// being asked for: a layout leaves it out (it only depends on the level shown), a fill request doesn't.
    private func layoutKey(level: TileLevel, transform t: ViewTransform, margin: Bool, want: TileLevel? = nil) -> LayoutKey {
        var rect = visibleRect(for: t)
        if margin {
            let pad = CGFloat(TileKey.side) / level.pixelsPerPoint
            rect = rect.insetBy(dx: -pad, dy: -pad)
        }
        let range = TileKey.range(covering: rect.intersection(document.pageBounds), level: level)
        return LayoutKey(version: contentVersion, revision: document.revision &* 31 &+ editLabel, shown: displayedLevel,
                         want: want ?? level, cols: range?.cols, rows: range?.rows,
                         moving: host?.isMoving ?? false)
    }

    /// The tiles held for this view may have changed: the next layout and fill request look again.
    private func contentChanged() {
        contentVersion &+= 1
    }

    private var modifiedSinceSnapshot = Set<UUID>()
    /// Strokes whose geometry was dropped while `warmGeometry` was building it in the background.
    private var modifiedSinceWarmup = Set<UUID>()

    private let renderQueue = DispatchQueue(label: "InkCanvas.render", qos: .userInteractive)
    private(set) var pixelSize = CGSize.zero
    /// Device pixels per point of the surface.
    private(set) var scale: CGFloat = 2
    private(set) var geometryCache: [UUID: StrokeGeometry] = [:]

    /// Finished strokes not drawn into the committed ink yet, in commit order.
    private(set) var pending: [PendingStroke] = []
    private var isCommitScheduled = false

    /// Owns the zoom window panel's interest in the cache.
    private let panelInterest = NSObject()

    init(document: CanvasDocument, embedded: Bool, cache: TileCache = .shared,
         filler: TileFiller = CoreGraphicsTileFiller()) {
        self.document = document
        isEmbedded = embedded
        self.cache = cache
        self.filler = filler
        layer.anchorPoint = .zero
        fallbackHost.anchorPoint = .zero
        fallbackMask.fillRule = .evenOdd
        fallbackHost.mask = fallbackMask
        fallbackHost.isHidden = true
        fallbackHost.addSublayer(fallback.layer)
        layer.addSublayer(fallbackHost)
        layer.addSublayer(current.layer)
    }

    deinit {
        cache.removeInterest(ObjectIdentifier(self))
        cache.removeInterest(ObjectIdentifier(panelInterest))
    }

    private var transform: ViewTransform {
        host?.renderTransform ?? ViewTransform()
    }

    private var bounds: CGRect {
        host?.renderBounds ?? .zero
    }

    private var page: UUID {
        document.cacheID
    }

    /// The level a view at `transform` shows.
    func level(for transform: ViewTransform) -> TileLevel {
        TileLevel(transform, displayScale: scale)
    }

    /// The level kept while zoomed: the fitted page's.
    var restingLevel: TileLevel {
        TileLevel(pixelsPerPoint: (host?.restingScale ?? 1) * scale)
    }

    // MARK: - Settled state

    /// True when the committed layer shows the page as it is, sharp at the current transform: the tiles
    /// on screen are at the transform's own level, every one in view shows the page's revision, and no
    /// render or finished stroke is on its way. What the canvas benchmarks wait for after an edit, a
    /// gesture or a page entering view.
    var isSettled: Bool {
        guard !isRendering, !renderRequested, pending.isEmpty, pixelSize != .zero else { return false }
        let t = transform, want = level(for: t)
        guard displayedLevel == want, displayedTransform == t else { return false }
        let editing = host?.isEditingInk ?? false
        return cache.tiles(for: visibleKeys(at: t, level: want)).allSatisfy {
            $0?.revision == document.revision || (editing && $0?.revision == editLabel)
        }
    }

    /// The part of the page the committed surface shows at `transform`, in page (canvas) points.
    func visibleRect(for transform: ViewTransform) -> CGRect {
        transform.toCanvas(CGRect(origin: .zero, size: bounds.size))
    }

    /// The tiles of `level` the view shows at `transform` (from the middle out when `centreOut`). Only the
    /// page: ink off its edge is masked away.
    func visibleKeys(at transform: ViewTransform, level: TileLevel, centreOut: Bool = false) -> [TileKey] {
        let rect = visibleRect(for: transform).intersection(document.pageBounds)
        let keys = TileKey.keys(covering: rect, page: page, level: level)
        guard centreOut else { return keys }
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        return keys.sorted { distance($0.rect, middle) < distance($1.rect, middle) }
    }

    /// A ring of one tile around the visible ones, filled after them so a pan finds its next tiles cached.
    private func marginKeys(at transform: ViewTransform, level: TileLevel, inside visibleKeys: [TileKey]) -> [TileKey] {
        let pad = CGFloat(TileKey.side) / level.pixelsPerPoint
        let visible = visibleRect(for: transform)
        let inner = Set(visibleKeys)
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        return TileKey.keys(covering: visible.insetBy(dx: -pad, dy: -pad).intersection(document.pageBounds),
                            page: page, level: level)
            .filter { !inner.contains($0) }
            .sorted { distance($0.rect, middle) < distance($1.rect, middle) }
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x, dy = rect.midY - point.y
        return dx * dx + dy * dy
    }

    /// The scale of a level cached for this page that `scale` is within 2% of, if there is one: a
    /// gesture ending there snaps to it, so the tiles already drawn are reused.
    func cachedScale(near scale: CGFloat) -> CGFloat? {
        let wanted = TileLevel(pixelsPerPoint: scale * self.scale)
        let levels = cache.levels(page: page).union([restingLevel])
        return levels.filter { $0.isNear(wanted) }
            .min { abs($0.pixelsPerPoint - wanted.pixelsPerPoint) < abs($1.pixelsPerPoint - wanted.pixelsPerPoint) }
            .map { $0.pixelsPerPoint / self.scale }
    }

    // MARK: - Surface

    static func pixelSize(of size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
    }

    /// The host's bounds or display scale may have changed: sizes the surface and shows the tiles for it,
    /// filling those that aren't cached.
    func resize(to bounds: CGRect, scale newScale: CGFloat) {
        let pixels = Self.pixelSize(of: bounds.size, scale: newScale)
        guard pixels != pixelSize || newScale != scale else { return }
        if newScale != scale {
            current.clear()
            fallback.clear()
            displayedLevel = nil
        }
        pixelSize = pixels
        scale = newScale
        contentChanged()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: bounds.size)
        layer.position = .zero
        fallbackHost.frame = layer.bounds
        fallbackMask.frame = layer.bounds
        CATransaction.commit()
        requestRender()
    }

    /// Lays the tiles out at the host's current transform: the displayed level's, moved and scaled, and
    /// the resting level's under them where they're missing. Switches to the transform's own level once
    /// its tiles in view are all cached (never mid-gesture at a moving scale).
    func updateLayerTransform() {
        guard pixelSize != .zero else { return }
        let t = transform, want = level(for: t)
        if displayedLevel != want, displayedLevel == nil || !(host?.isMoving ?? false),
           cache.tiles(for: visibleKeys(at: t, level: want)).allSatisfy({ $0 != nil }) {
            displayedLevel = want
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let shown = displayedLevel else {
            current.clear()
            hideFallback()
            shownKeys = []
            lastLayout = nil
            return
        }
        // A frame that only moves the view over the same tiles: move the grids, nothing else.
        let key = layoutKey(level: shown, transform: t, margin: false)
        if key == lastLayout {
            current.place(at: t, displayScale: scale)
            if !fallbackHost.isHidden {
                placeFallback(at: t)
            }
            if shown == want {
                displayedTransform = t
            }
            return
        }
        lastLayout = key
        let held = tiles(at: shown, covering: t)
        shownKeys = Set(held.present.map(\.key))
        let changed = current.show(held.present.compactMap { key, tile in tile.image.map { (key, $0) } }, level: shown,
                                   displayScale: scale)
        current.place(at: t, displayScale: scale)
        if held.complete || shown == restingLevel {
            hideFallback()
        } else {
            showFallback(at: t, under: held.present.map(\.key))
        }
        if shown == want {
            displayedTransform = t
        }
        if changed {
            host?.renderCoordinatorDidPublish()
        }
    }

    /// The cached tiles of `level` in view at `transform`, and whether every one in view is cached.
    private func tiles(at level: TileLevel, covering t: ViewTransform) -> (present: [(key: TileKey, tile: Tile)], complete: Bool) {
        let rect = visibleRect(for: t).intersection(document.pageBounds)
        guard let (cols, rows) = TileKey.range(covering: rect, level: level) else { return ([], true) }
        let expected = cols.count * rows.count
        if expected <= 400 {
            let keys = TileKey.keys(covering: rect, page: page, level: level)
            let held = cache.tiles(for: keys)
            let present = zip(keys, held).compactMap { key, tile in tile.map { (key, $0) } }
            return (present, present.count == expected)
        }
        // Zoomed far out over a fine level: look through what's cached rather than every key in view.
        let present = cache.tiles(page: page).filter {
            $0.key.level == level && cols.contains($0.key.col) && rows.contains($0.key.row)
        }.map { (key: $0.key, tile: $0.value) }
        return (present, present.count == expected)
    }

    private func hideFallback() {
        guard !fallbackHost.isHidden || fallback.level != nil else { return }
        fallbackHost.isHidden = true
        fallback.clear()
    }

    /// Shows the resting level under the displayed one, masked away wherever the displayed level has a
    /// tile (with ink or empty), so blurrier ink never shows around the sharp.
    private func showFallback(at t: ViewTransform, under covered: [TileKey]) {
        let resting = restingLevel
        let held = tiles(at: resting, covering: t).present
        guard !held.isEmpty else {
            hideFallback()
            return
        }
        fallbackHost.isHidden = false
        shownKeys.formUnion(held.map(\.key))
        fallback.show(held.compactMap { key, tile in tile.image.map { (key, $0) } }, level: resting, displayScale: scale)
        coveredRects = Self.merged(covered)
        placeFallback(at: t)
    }

    /// The displayed level's tiles under the resting level, as page rects (the mask's holes).
    private var coveredRects: [CGRect] = []

    private func placeFallback(at t: ViewTransform) {
        fallback.place(at: t, displayScale: scale)
        let path = CGMutablePath()
        path.addRect(layer.bounds.insetBy(dx: -1, dy: -1))
        for rect in coveredRects {
            // A pixel inside the tiles, so the resting level runs under their edge rather than leaving a hairline.
            path.addRect(t.toView(rect).insetBy(dx: 1 / scale, dy: 1 / scale))
        }
        fallbackMask.path = path
    }

    /// `keys` (one level) as few page rects as possible: runs of columns in a row, then equal runs in
    /// consecutive rows, so the mask has no edges between tiles.
    private static func merged(_ keys: [TileKey]) -> [CGRect] {
        struct Block {
            var rows: ClosedRange<Int>
            let cols: ClosedRange<Int>
        }
        var spans: [Block] = []
        for (row, inRow) in Dictionary(grouping: keys, by: \.row).sorted(by: { $0.key < $1.key }) {
            let cols = inRow.map(\.col).sorted()
            var start = cols[0], end = cols[0]
            for c in cols.dropFirst() {
                if c == end + 1 {
                    end = c
                } else {
                    spans.append(Block(rows: row ... row, cols: start ... end))
                    start = c
                    end = c
                }
            }
            spans.append(Block(rows: row ... row, cols: start ... end))
        }
        var blocks: [Block] = []
        for span in spans {
            if let i = blocks.firstIndex(where: { $0.rows.upperBound == span.rows.lowerBound - 1 && $0.cols == span.cols }) {
                blocks[i].rows = blocks[i].rows.lowerBound ... span.rows.upperBound
            } else {
                blocks.append(span)
            }
        }
        guard let level = keys.first?.level else { return [] }
        let s = CGFloat(TileKey.side) / level.pixelsPerPoint
        return blocks.map {
            CGRect(x: CGFloat($0.cols.lowerBound) * s, y: CGFloat($0.rows.lowerBound) * s,
                   width: CGFloat($0.cols.count) * s, height: CGFloat($0.rows.count) * s)
        }
    }

    /// The committed tiles on screen, in page space: what the live layer draws under multiply ink.
    var underlay: [(pageRect: CGRect, image: CGImage)] {
        current.shownImages.map { ($0.key.rect, $0.image) }
    }

    /// The committed ink on screen, assembled into one image the size of the surface at the transform it
    /// was laid out at (the benchmarks' and tests' pixel checks).
    func composedImage() -> CGImage? {
        guard let ctx = CommittedRenderer.makeBitmap(pixelSize: pixelSize, scale: scale) else { return nil }
        TileBitmap.compose(current.shownImages, at: displayedTransform, in: ctx)
        return ctx.makeImage()
    }

    // MARK: - Geometry

    /// Drops a stroke's cached geometry after the stroke changed.
    func forgetGeometry(_ id: UUID) {
        geometryCache[id] = nil
        modifiedSinceSnapshot.insert(id)
        modifiedSinceWarmup.insert(id)
    }

    func geometry(for stroke: Stroke) -> StrokeGeometry {
        if let g = geometryCache[stroke.id] {
            return g
        }
        let g = StrokeRenderer.geometry(for: stroke)
        geometryCache[stroke.id] = g
        return g
    }

    /// Caches geometry already built for a stroke (a stroke just finished, from its live geometry).
    func cache(_ geometry: StrokeGeometry, for id: UUID) {
        geometryCache[id] = geometry
    }

    // MARK: - Render requests

    /// The ink in `rect` (page points) changed. A change that moved the page's revision on leaves every
    /// tile at an older one stale (refilled when it's needed; NOT-104 keeps those outside `rect`); one that
    /// didn't (strokes removed or moved mid-gesture) marks the tiles under `rect` stale.
    func invalidate(rect: CGRect) {
        invalidate(rect as CGRect?)
    }

    /// The page's ink changed in ways no rect describes (an undo, a clear, another view's edit). Stale
    /// tiles stay on screen until their refills land.
    func invalidateAll() {
        invalidate(nil)
    }

    private func invalidate(_ rect: CGRect?) {
        contentChanged()
        if host?.isEditingInk ?? false {
            editLabel -= 1
        }
        if document.revision == lastInvalidatedRevision {
            cache.invalidate(page: page, rect: rect)
        }
        lastInvalidatedRevision = document.revision
        requestRender()
    }

    /// Asks for the committed ink sharp at the host's current transform: lays out what's cached and fills
    /// what's missing or stale in view (then a tile's margin around it), coalesced with a job running.
    func requestRender() {
        // No surface for this size yet (a new view, or one just resized): sizing it (`resize`) renders.
        guard pixelSize != .zero, pixelSize == Self.pixelSize(of: bounds.size, scale: scale) else {
            host?.renderCoordinatorNeedsLayout()
            return
        }
        updateLayerTransform()
        if isRendering {
            renderRequested = true
        } else {
            startRender()
        }
    }

    /// Stops the tiles of jobs under way that haven't started yet: what they'd draw is out of date (a
    /// cancelled gesture's transform, a page that changed under them). What they did draw is kept, as
    /// every tile records the revision it shows.
    func discardInFlight() {
        contentChanged()
        cancellation.cancel()
        cancellation = RenderCancellation()
    }

    /// The revision the tiles a job fills now will show: the page's, or when finished strokes are
    /// waiting to be drawn (the job leaves them out, as the live layer shows them), the revision before
    /// the first of them, if nothing else changed since.
    private func fillRevision(skipping waiting: [PendingStroke]) -> Int {
        if host?.isEditingInk ?? false {
            return editLabel
        }
        guard let first = waiting.first else { return document.revision }
        var revision = first.revisionBefore
        for stroke in waiting {
            guard stroke.revisionBefore == revision, stroke.revisionAfter >= 0 else { return Tile.unknownRevision }
            revision = stroke.revisionAfter
        }
        return revision == document.revision ? first.revisionBefore : Tile.unknownRevision
    }

    private func startRender() {
        let t = transform, want = level(for: t)
        // Nothing new since the last request covering these tiles: they're filled or being filled.
        let request = layoutKey(level: want, transform: t, margin: true, want: want)
        if request == lastFillRequest {
            return
        }
        lastFillRequest = request
        let resting = restingLevel
        // Nothing is filled at a scale still changing: the last level is shown scaled.
        if host?.isMoving ?? false, let shown = displayedLevel, shown != want {
            cache.setInterest(ObjectIdentifier(self), page: page, visible: shownKeys, resting: resting)
            return
        }
        let visible = visibleKeys(at: t, level: want, centreOut: true)
        let waiting = pending.filter { !$0.submitted }
        let revision = fillRevision(skipping: waiting)
        let margin = revision < 0 ? [] : marginKeys(at: t, level: want, inside: visible)
        let wanted = visible + margin
        cache.setInterest(ObjectIdentifier(self), page: page, visible: shownKeys.union(wanted), resting: resting)
        let current = document.revision
        let keys = zip(wanted, cache.tiles(for: wanted)).compactMap { key, tile -> TileKey? in
            guard let tile else { return key }
            if tile.revision == current || (revision != Tile.unknownRevision && tile.revision == revision) {
                return nil
            }
            return key
        }
        guard !keys.isEmpty else { return }

        isRendering = true
        modifiedSinceSnapshot.removeAll()
        let snapshot = InkSnapshot(strokes: document.strokes, index: document.strokeIndex, geometry: geometryCache,
                                   skipped: Set(waiting.map(\.live.stroke.id)))
        let raster = document.tileRaster
        let token = cancellation
        let job = FillJob(keys: keys, ink: snapshot, revision: revision, raster: raster, cache: cache, filler: filler,
                          cancellation: token)
        renderQueue.async { [weak self] in
            let result = Self.fill(job)
            DispatchQueue.main.async { [weak self] in
                self?.renderDidLand(result)
            }
        }
    }

    /// What a render job draws: these tiles, from this ink, labelled with this revision.
    private struct FillJob: @unchecked Sendable { // immutable; the filler and cache are thread-safe
        let keys: [TileKey]
        let ink: InkSnapshot
        let revision: Int
        let raster: TileRaster?
        let cache: TileCache
        let filler: TileFiller
        let cancellation: RenderCancellation
    }

    /// What a render job did.
    private struct FillResult {
        var filled = 0
        var restored = 0
        var geometry: [(UUID, StrokeGeometry)] = []
        var milliseconds = 0.0
    }

    /// Fills the job's tiles (or restores them from its raster) into its cache, on every core. Render
    /// queue only.
    private nonisolated static func fill(_ job: FillJob) -> FillResult {
        let keys = job.keys, revision = job.revision, raster = job.raster, cache = job.cache
        let filler = job.filler, cancellation = job.cancellation
        let start = DispatchTime.now().uptimeNanoseconds
        var result = FillResult()
        var toFill: [TileKey] = []
        for key in keys {
            if let raster, raster.holds(key, revision: revision), let tile = raster.restore(key) {
                cache.storeIfNewer(tile, for: key)
                result.restored += 1
            } else {
                toFill.append(key)
            }
        }
        if !toFill.isEmpty {
            var snapshot = job.ink
            result.geometry = snapshot.buildGeometry(reaching: toFill.map(\.rect))
            let ink = snapshot
            DispatchQueue.concurrentPerform(iterations: toFill.count) { i in
                guard !cancellation.isCancelled else { return }
                let key = toFill[i]
                cache.storeIfNewer(Self.draw(key, from: ink, revision: revision, filler: filler), for: key)
            }
            result.filled = cancellation.isCancelled ? 0 : toFill.count
        }
        result.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        return result
    }

    /// `key`'s tile drawn from scratch: the strokes the index finds reaching it, in page order.
    nonisolated static func draw(_ key: TileKey, from ink: InkSnapshot, revision: Int, filler: TileFiller) -> Tile {
        let strokes = ink.drawable(in: key.rect)
        guard !strokes.isEmpty, let ctx = TileBitmap.context(for: key) else {
            return Tile(image: nil, revision: revision)
        }
        filler.fill(key, region: nil, strokes: strokes, into: ctx)
        return Tile(image: ctx.makeImage(), revision: revision)
    }

    private func renderDidLand(_ result: FillResult) {
        isRendering = false
        contentChanged()
        for (id, geometry) in result.geometry where geometryCache[id] == nil && !modifiedSinceSnapshot.contains(id) {
            geometryCache[id] = geometry
        }
        fillStats.jobs += 1
        fillStats.tilesFilled += result.filled
        fillStats.tilesRestored += result.restored
        fillStats.milliseconds += result.milliseconds
        updateLayerTransform()
        if result.restored > 0 {
            warmGeometry()
        }
        if renderRequested {
            renderRequested = false
            startRender()
        }
    }

    // MARK: - Finished strokes

    /// A finished stroke was added to the document (`revisionBefore` is the revision before it): it's
    /// drawn into the committed ink once its estimates are in, and shown by the live layer until then.
    func strokeCommitted(_ live: LiveStroke, geometry: StrokeGeometry, revisionBefore: Int) {
        let deadline = CACurrentMediaTime() + 0.25
        pending.append(PendingStroke(live: live, geometry: geometry, deadline: deadline,
                                     revisionBefore: revisionBefore, revisionAfter: document.revision))
        schedulePendingCommit()
    }

    /// The pending stroke `id` that hasn't been sent to be drawn yet, if there is one.
    func awaitingStroke(_ id: UUID) -> PendingStroke? {
        pending.first { $0.live.stroke.id == id && !$0.submitted }
    }

    /// The pending stroke `id`, sent to be drawn or not.
    func pendingStroke(_ id: UUID) -> PendingStroke? {
        pending.first { $0.live.stroke.id == id }
    }

    /// Rebuilds the geometry of pending strokes whose samples were refined.
    func refreshPendingGeometry() {
        for p in pending where p.geometryDirty {
            p.geometryDirty = false
            let newGeom = p.live.geometry()
            p.geometry = newGeom
            p.bounds = newGeom.bounds
            forgetGeometry(p.live.stroke.id)
        }
    }

    /// Drops pending strokes that are about to be redrawn elsewhere (moved by the lasso or undone).
    func dropPending(_ ids: Set<UUID>) {
        pending.removeAll { ids.contains($0.live.stroke.id) }
    }

    /// Drops pending strokes that are no longer on the page.
    func dropPending(notIn strokeIDs: Set<UUID>) {
        pending.removeAll { !strokeIDs.contains($0.live.stroke.id) }
    }

    /// Sends the pending strokes whose estimates are in (or overdue) to be drawn, in order, and checks
    /// back for the rest.
    func schedulePendingCommit() {
        let now = CACurrentMediaTime()
        var hasWaiting = false

        for item in pending {
            if item.submitted {
                continue
            }
            let hasEstimates = host?.hasOutstandingEstimates(for: item.live.stroke.id) ?? false
            let ready = !hasEstimates || now >= item.deadline
            if ready {
                submitPendingStroke(item)
            } else {
                hasWaiting = true
                break
            }
        }

        if hasWaiting, !isCommitScheduled {
            isCommitScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self else { return }
                isCommitScheduled = false
                schedulePendingCommit()
            }
        }
    }

    /// Draws a finished stroke into every cached tile of the page it reaches, at every level, on the render
    /// queue. No cached tile has it yet (fills leave unsubmitted strokes out, and run in order with this),
    /// so drawing it on top is what filling the tile again would give, and it never blinks. Tiles it
    /// doesn't reach show the new revision as they are.
    private func submitPendingStroke(_ item: PendingStroke) {
        item.submitted = true
        let geom = item.live.geometry()
        item.geometry = geom
        item.bounds = geom.bounds
        geometryCache[item.live.stroke.id] = geom
        let stroke = TileStroke(geometry: geom, brush: item.live.stroke.brush, color: item.live.stroke.color)
        let from = item.revisionBefore
        let to = item.revisionAfter >= 0 ? item.revisionAfter : Tile.unknownRevision
        let reach = geom.bounds.insetBy(dx: -3, dy: -3)
        let cache = cache, filler = filler, page = page

        renderQueue.async { [weak self] in
            let reached = cache.tiles(page: page).filter { $0.key.rect.intersects(reach) }.map { ($0.key, $0.value) }
            DispatchQueue.concurrentPerform(iterations: reached.count) { i in
                let (key, tile) = reached[i]
                // Filled after the stroke was added (before it was handed over): it's in there already.
                if to != Tile.unknownRevision, tile.revision >= to {
                    return
                }
                let revision = tile.revision == from ? to : Tile.unknownRevision
                if tile.image == nil, stroke.brush.erases {
                    cache.store(Tile(image: nil, revision: revision), for: key)
                    return
                }
                guard let ctx = TileBitmap.context(for: key, startingFrom: tile.image) else { return }
                filler.fill(key, region: nil, strokes: [stroke], into: ctx)
                cache.store(Tile(image: ctx.makeImage(), revision: revision), for: key)
            }
            cache.advance(page: page, from: from, to: to, outside: reach)
            DispatchQueue.main.async { [weak self] in
                self?.pendingDidLand(item, bounds: geom.bounds)
            }
        }
    }

    private func pendingDidLand(_ item: PendingStroke, bounds: CGRect) {
        contentChanged()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let index = pending.firstIndex(where: { $0 === item }) {
            pending.remove(at: index)
        }
        updateLayerTransform()
        host?.renderCoordinatorDidDrawPending(canvasRect: bounds)
        CATransaction.commit()
        // Tiles filled while the stroke waited, after something else changed too, show no revision: draw
        // them again now that nothing is left out.
        if !isSettled, !isRendering, !pending.contains(where: { !$0.submitted }), !(host?.isEditingInk ?? false) {
            requestRender()
        }
    }

    // MARK: - Page raster

    /// Builds, in the background, the geometry of every stroke that has none cached: a page opened from
    /// its raster drew none, and erasing, the lasso and the next refill all need it.
    private func warmGeometry() {
        let strokes = document.strokes.filter { geometryCache[$0.id] == nil }
        guard !strokes.isEmpty else { return }
        modifiedSinceWarmup.removeAll()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let geometries = CommittedRenderer.geometries(for: strokes)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (stroke, geometry) in zip(strokes, geometries)
                    where geometryCache[stroke.id] == nil && !modifiedSinceWarmup.contains(stroke.id) {
                    geometryCache[stroke.id] = geometry
                }
            }
        }
    }

    /// The page is going away: leaves its resting-level tiles with the document as a `TileRaster`, for
    /// the next time it opens (should the cache have let them go by then). The cached tiles at the page's
    /// revision are used; any others are drawn in the background.
    func saveTileRaster() {
        guard !isEmbedded, let host, !host.isEditingInk, pixelSize != .zero else { return }
        let revision = document.revision, level = restingLevel, document = document
        guard document.tileRaster?.revision != revision || document.tileRaster?.level != level,
              document.strokes.contains(where: { !$0.brush.erases })
        else { return }
        let keys = TileKey.keys(covering: document.pageBounds, page: page, level: level)
        let snapshot = InkSnapshot(strokes: document.strokes, index: document.strokeIndex, geometry: geometryCache,
                                   skipped: [])
        let cache = cache, filler = filler
        DispatchQueue.global(qos: .utility).async {
            let held = cache.tiles(for: keys)
            let missing = zip(keys, held).filter { $0.1?.revision != revision }.map(\.0)
            var ink = snapshot
            _ = ink.buildGeometry(reaching: missing.map(\.rect))
            let filled = ink
            var drawn = [TileKey: Tile]()
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: missing.count) { i in
                let tile = Self.draw(missing[i], from: filled, revision: revision, filler: filler)
                cache.storeIfNewer(tile, for: missing[i])
                lock.withLock { drawn[missing[i]] = tile }
            }
            let tiles = zip(keys, held).map { key, tile in (key: key, image: (drawn[key] ?? tile)?.image) }
            let raster = TileRaster(tiles: tiles, revision: revision, level: level)
            DispatchQueue.main.async {
                guard let raster, document.revision == raster.revision else { return }
                document.tileRaster = raster
            }
        }
    }

    // MARK: - Snapshots (the zoom window's panel)

    /// The committed ink that reaches `bounds` (view points of an image of their own) at `transform`,
    /// assembled from the page's tiles at that scale (filled where they're missing), handed to
    /// `completion` on the main queue with the transform it's drawn at: `transform` with its offset on
    /// whole device pixels, so the tiles land on the image's pixels.
    func renderSnapshot(bounds: CGRect, transform: ViewTransform,
                        completion: @escaping (CGImage?, ViewTransform) -> Void) {
        let scale = scale
        let t = transform.snapped(toPixels: scale)
        let level = level(for: t)
        let pixels = Self.pixelSize(of: bounds.size, scale: scale)
        let keys = TileKey.keys(covering: t.toCanvas(bounds).intersection(document.pageBounds), page: page, level: level)
        cache.setInterest(ObjectIdentifier(panelInterest), page: page, visible: Set(keys), resting: nil)
        let revision = (host?.isEditingInk ?? false) ? Tile.unknownRevision : document.revision
        // The panel shows every stroke at once, waiting ones too; tiles like that aren't the canvas's to keep.
        let keeps = revision != Tile.unknownRevision && !pending.contains { !$0.submitted }
        let snapshot = InkSnapshot(strokes: document.strokes, index: document.strokeIndex, geometry: geometryCache,
                                   skipped: [])
        let cache = cache, filler = filler
        renderQueue.async {
            let held = cache.tiles(for: keys)
            let missing = zip(keys, held).filter { $0.1 == nil || $0.1?.revision != revision || !keeps }.map(\.0)
            var ink = snapshot
            _ = ink.buildGeometry(reaching: missing.map(\.rect))
            var tiles = Dictionary(uniqueKeysWithValues: zip(keys, held).compactMap { key, tile in tile.map { (key, $0) } })
            for key in missing {
                let tile = Self.draw(key, from: ink, revision: revision, filler: filler)
                tiles[key] = tile
                if keeps {
                    cache.storeIfNewer(tile, for: key)
                }
            }
            var image: CGImage?
            if let ctx = CommittedRenderer.makeBitmap(pixelSize: pixels, scale: scale) {
                TileBitmap.compose(tiles.compactMap { key, tile in tile.image.map { (key, $0) } }, at: t, in: ctx)
                image = ctx.makeImage()
            }
            DispatchQueue.main.async {
                completion(image, t)
            }
        }
    }

    /// Lets the cache evict the panel's tiles (the zoom window closed).
    func releaseSnapshots() {
        cache.removeInterest(ObjectIdentifier(panelInterest))
    }
}
