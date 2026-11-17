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
    /// True while the page's strokes are mid-edit (an erase or a lasso drag): a render then shows no
    /// revision of the document.
    var isEditingInk: Bool { get }
    /// True while a stroke is being drawn.
    var hasLiveStroke: Bool { get }
    /// Whether some of the stroke's samples still expect refined force or tilt.
    func hasOutstandingEstimates(for strokeID: UUID) -> Bool
    /// A render was asked for before the surface has a size: lay the view out, which sizes it.
    func renderCoordinatorNeedsLayout()
    /// `image` is on screen as the committed ink (anything drawing over it, like the live layer, may need it).
    func renderCoordinator(didPublish image: CGImage)
    /// A finished stroke is now in the committed ink, so the live layer can stop showing `canvasRect` for it.
    func renderCoordinatorDidDrawPending(canvasRect: CGRect)
    /// The whole page was drawn again: everything the live layer shows over it is out of date.
    func renderCoordinatorDidRedraw()
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
    /// update since applied): drawing it takes a bitmap at the first to the second.
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

/// The committed side of a canvas, pulled out of `CanvasView` (NOT-100): the surface finished ink is
/// drawn on, the geometry cache, the strokes waiting to be drawn into it, revision tracking, render
/// requests, the page's `CommittedRaster`, and the zoom window panel's renders.
///
/// It speaks in page rects (`invalidate(rect:)`, `strokeCommitted`, `visibleRect(for:)`) and publishes a
/// settled state (`isSettled`), so the tiled committed layer (NOT-102) can replace what's inside without
/// the view changing. Today it still wraps one screen-sized bitmap: an invalidated rect redraws the page.
///
/// Main thread only, apart from what it runs on its own queues.
@MainActor
final class RenderCoordinator {
    let document: CanvasDocument
    /// True for one page among several in continuous scrolling: no page raster is kept.
    let isEmbedded: Bool
    weak var host: RenderCoordinatorHost?

    /// The layer showing the committed ink. The host puts it in its view hierarchy; the coordinator sizes it
    /// (`resize(to:scale:)`) and moves it with the transform (`updateLayerTransform()`).
    let layer = CALayer()

    /// The transform the bitmap is (or will be, once queued jobs run) rendered at; pending strokes draw with it.
    private(set) var targetTransform = ViewTransform()
    /// The transform of the image currently in `layer.contents`.
    private(set) var displayedTransform = ViewTransform()
    /// The committed image on screen: the whole surface, at `displayedTransform`.
    private(set) var publishedImage: CGImage?
    /// True while a full render is running on the render queue.
    private(set) var isRendering = false
    private var renderRequested = false
    /// True while the page's `CommittedRaster` is being restored into the bitmap.
    private var rasterRestoreInFlight = false

    private var modifiedSinceSnapshot = Set<UUID>()
    /// Strokes whose geometry was dropped while `warmGeometry` was building it in the background.
    private var modifiedSinceWarmup = Set<UUID>()
    /// The document revision the committed bitmap holds once every job queued on `renderQueue` has run,
    /// or nil when it holds something no revision describes: strokes mid-erase or mid-drag, a finished
    /// stroke not drawn into it yet, an edit that's waiting for a full render.
    private var bitmapRevision: Int?
    /// The newest published image known to hold the whole page, fitted, at `revision`. When the page
    /// closes it becomes the document's `CommittedRaster`, so reopening the page needn't fill every stroke.
    private var rasterCandidate: RenderedPage?
    private struct RenderedPage {
        let image: CGImage
        let revision: Int
        let transform: ViewTransform
    }

    private let renderQueue = DispatchQueue(label: "InkCanvas.render", qos: .userInteractive)
    private var generation: UInt64 = 0
    private nonisolated(unsafe) var bitmap: CGContext? // touched only on renderQueue
    private(set) var pixelSize = CGSize.zero
    /// Device pixels per point of the surface.
    private(set) var scale: CGFloat = 2
    private(set) var geometryCache: [UUID: StrokeGeometry] = [:]

    /// Finished strokes not drawn into the committed ink yet, in commit order.
    private(set) var pending: [PendingStroke] = []
    private var isCommitScheduled = false

    /// The zoom window panel's renders, on a queue of their own.
    private let snapshotQueue = DispatchQueue(label: "InkCanvas.zoomRender", qos: .userInteractive)
    private nonisolated(unsafe) var snapshotBitmap: CGContext? // touched only on snapshotQueue

    init(document: CanvasDocument, embedded: Bool) {
        self.document = document
        isEmbedded = embedded
        layer.anchorPoint = .zero
    }

    private var transform: ViewTransform {
        host?.renderTransform ?? ViewTransform()
    }

    private var bounds: CGRect {
        host?.renderBounds ?? .zero
    }

    // MARK: - Settled state

    /// True when the committed layer shows the page as it is, sharp at the current transform: no render,
    /// raster restore or finished stroke on its way. What the canvas benchmarks wait for after an edit,
    /// a gesture or a page entering view.
    var isSettled: Bool {
        !isRendering && !renderRequested && !rasterRestoreInFlight && pending.isEmpty
            && displayedTransform == transform && targetTransform == transform
    }

    /// The part of the page the committed surface shows at `transform`, in page (canvas) points.
    func visibleRect(for transform: ViewTransform) -> CGRect {
        transform.toCanvas(CGRect(origin: .zero, size: bounds.size))
    }

    // MARK: - Surface

    static func pixelSize(of size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
    }

    /// The host's bounds or display scale may have changed: makes a surface for them if they did, filled
    /// from the page's raster when that matches, otherwise by a full render.
    func resize(to bounds: CGRect, scale newScale: CGFloat) {
        let pixels = Self.pixelSize(of: bounds.size, scale: newScale)
        guard pixels != pixelSize || newScale != scale else { return }
        pixelSize = pixels
        scale = newScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = bounds
        layer.position = .zero
        layer.contentsScale = newScale
        CATransaction.commit()
        makeBitmap()
        bitmapRevision = nil
        if !restoreCommittedRaster() {
            requestRender()
        }
    }

    private func makeBitmap() {
        let pixelSize = pixelSize
        let scale = scale
        renderQueue.sync {
            self.bitmap = CommittedRenderer.makeBitmap(pixelSize: pixelSize, scale: scale)
        }
    }

    /// Moves the published image to where the current transform puts it, until a render at that
    /// transform replaces it.
    func updateLayerTransform() {
        let t: CGAffineTransform
        let transform = transform
        if displayedTransform == transform {
            t = .identity
        } else {
            let k = transform.scale / displayedTransform.scale
            t = CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                  tx: transform.offset.x - displayedTransform.offset.x * k,
                                  ty: transform.offset.y - displayedTransform.offset.y * k)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(t)
        CATransaction.commit()
    }

    private func publish(image: CGImage, transform: ViewTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        publishedImage = image
        displayedTransform = transform
        updateLayerTransform()
        CATransaction.commit()
        host?.renderCoordinator(didPublish: image)
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

    /// The ink in `rect` (page points) changed. With one bitmap, the page is drawn again.
    func invalidate(rect _: CGRect) {
        requestRender()
    }

    /// The page's ink changed in ways no rect describes (an undo, a clear, another view's edit).
    func invalidateAll() {
        requestRender()
    }

    /// Asks for the committed ink sharp at the host's current transform: a full render, coalesced with one
    /// already running.
    func requestRender() {
        // No bitmap for this size yet (a new view, or one just resized): making one (`resize`) renders,
        // and rendering now would only fill the old one.
        guard pixelSize != .zero, pixelSize == Self.pixelSize(of: bounds.size, scale: scale) else {
            host?.renderCoordinatorNeedsLayout()
            return
        }
        if isRendering {
            renderRequested = true
        } else {
            startFullRender()
        }
    }

    /// Drops the results of renders and draws already under way when they land: what they show is out of
    /// date (a cancelled gesture's transform, a page that changed under them).
    func discardInFlight() {
        generation &+= 1
    }

    private func startFullRender() {
        generation &+= 1
        let currentGeneration = generation
        isRendering = true
        targetTransform = transform
        modifiedSinceSnapshot.removeAll()

        let currentBounds = bounds
        let targetTransform = targetTransform

        let unsubmittedIDs = Set(pending.filter { !$0.submitted }.map(\.live.stroke.id))
        let renderedRevision = unsubmittedIDs.isEmpty && !(host?.isEditingInk ?? false)
            ? document.revision : nil
        bitmapRevision = renderedRevision
        let itemsToRender = committedItems(skipping: unsubmittedIDs)

        let coveredPending = pending.filter(\.submitted)

        renderQueue.async { [weak self] in
            guard let self else { return }
            var computedGeometries: [(UUID, StrokeGeometry)] = []
            var image: CGImage?
            if let ctx = bitmap {
                computedGeometries = CommittedRenderer.render(itemsToRender, into: ctx, bounds: currentBounds,
                                                              transform: targetTransform)
                image = ctx.makeImage()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if generation == currentGeneration {
                    if let image {
                        publish(image: image, transform: targetTransform)
                    }
                    for (id, geom) in computedGeometries {
                        if geometryCache[id] == nil, !modifiedSinceSnapshot.contains(id) {
                            geometryCache[id] = geom
                        }
                    }
                    for item in coveredPending {
                        if let idx = pending.firstIndex(where: { $0 === item }) {
                            pending.remove(at: idx)
                        }
                        host?.renderCoordinatorDidDrawPending(canvasRect: item.bounds)
                    }
                    host?.renderCoordinatorDidRedraw()
                    if let image {
                        noteRendered(image, revision: renderedRevision, transform: targetTransform)
                    }
                }
                isRendering = false
                if renderRequested {
                    renderRequested = false
                    startFullRender()
                }
            }
        }
    }

    /// The document's strokes to render, with their cached geometry where there is some.
    func committedItems(skipping skipped: Set<UUID> = []) -> [CommittedRenderer.Item] {
        document.strokes.compactMap { stroke in
            guard !skipped.contains(stroke.id) else { return nil }
            let cached = geometryCache[stroke.id]
            return CommittedRenderer.Item(id: stroke.id, brush: stroke.brush, color: stroke.color,
                                          geometry: cached, stroke: cached == nil ? stroke : nil)
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

    private func submitPendingStroke(_ item: PendingStroke) {
        item.submitted = true
        let geom = item.live.geometry()
        item.geometry = geom
        item.bounds = geom.bounds
        geometryCache[item.live.stroke.id] = geom
        let runs = geom.runs
        let bounds = geom.bounds
        let brush = item.live.stroke.brush
        let color = item.live.stroke.color
        let targetTransform = targetTransform
        let currentGeneration = generation
        let isNext = bitmapRevision != nil && bitmapRevision == item.revisionBefore && item.revisionAfter >= 0
        bitmapRevision = isNext ? item.revisionAfter : nil
        let renderedRevision = bitmapRevision

        renderQueue.async { [weak self] in
            guard let self, let ctx = bitmap else { return }
            ctx.saveGState()
            ctx.concatenate(targetTransform.affine)
            if brush.usesPattern {
                PencilTexture.prepareContext(ctx, phase: targetTransform.offset)
            }
            StrokeRenderer.draw(runs: runs, clip: bounds.insetBy(dx: -2, dy: -2),
                                brush: brush, color: color, in: ctx)
            ctx.restoreGState()
            let image = ctx.makeImage()

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == currentGeneration, let image else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                publish(image: image, transform: targetTransform)
                if let idx = pending.firstIndex(where: { $0 === item }) {
                    pending.remove(at: idx)
                }
                host?.renderCoordinatorDidDrawPending(canvasRect: bounds)
                CATransaction.commit()
                noteRendered(image, revision: renderedRevision, transform: targetTransform)
            }
        }
    }

    // MARK: - Page raster

    /// Called with every image published from a render job that drew the page at `revision` (nil: not
    /// a whole revision). Keeps the newest whole, fitted one as the page's raster-to-be.
    private func noteRendered(_ image: CGImage, revision: Int?, transform: ViewTransform) {
        if !isEmbedded, let revision, revision == document.revision, bitmapRevision == revision, pending.isEmpty,
           !renderRequested, transform == host?.fittedTransform() {
            rasterCandidate = RenderedPage(image: image, revision: revision, transform: transform)
        } else if rasterCandidate?.revision != document.revision {
            rasterCandidate = nil // an older revision: no use to anyone, and it holds a screenful of pixels
        }
    }

    /// Puts the document's `CommittedRaster` into the fresh bitmap instead of a full render, when it
    /// shows the page as it is now at the transform and size the bitmap is for. Returns false if it can't.
    private func restoreCommittedRaster() -> Bool {
        guard let raster = document.committedRaster, !isRendering, pending.isEmpty,
              raster.matches(revision: document.revision, pixelSize: pixelSize, scale: scale,
                             transform: transform)
        else { return false }
        generation &+= 1
        let currentGeneration = generation
        let transform = transform
        targetTransform = transform
        bitmapRevision = raster.revision
        rasterRestoreInFlight = true
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let ctx = bitmap else {
                DispatchQueue.main.async { [weak self] in self?.rasterRestoreInFlight = false }
                return
            }
            let image = raster.restore(into: ctx) ? ctx.makeImage() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                rasterRestoreInFlight = false
                guard generation == currentGeneration else { return }
                guard let image else {
                    // Undecodable: draw the page the slow way after all.
                    document.committedRaster = nil
                    bitmapRevision = nil
                    requestRender()
                    return
                }
                publish(image: image, transform: transform)
                host?.renderCoordinatorDidRedraw()
                noteRendered(image, revision: raster.revision, transform: transform)
                warmGeometry()
            }
        }
        return true
    }

    /// Builds, in the background, the geometry of every stroke that has none cached: a page opened from
    /// its raster drew none, and erasing, the lasso and the next full render all need it.
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

    /// The page is going away: leaves its committed layer with the document as a `CommittedRaster` for
    /// the next time it opens. The pixels on screen are used when they're known to be the whole page as
    /// it is; otherwise the page is drawn again, fitted, in the background.
    func saveCommittedRaster() {
        guard let host else { return }
        let revision = document.revision
        let transform = host.fittedTransform()
        let pixelSize = pixelSize, scale = scale
        let document = document
        guard pixelSize.width > 0, pixelSize.height > 0,
              !(document.committedRaster?.matches(revision: revision, pixelSize: pixelSize, scale: scale,
                                                  transform: transform) ?? false)
        else { return }
        let store: (CommittedRaster?) -> Void = { raster in
            DispatchQueue.main.async {
                guard let raster, document.revision == raster.revision else { return }
                document.committedRaster = raster
            }
        }
        if let candidate = rasterCandidate, candidate.revision == revision, candidate.transform == transform,
           !host.isEditingInk, pending.isEmpty, !host.hasLiveStroke {
            DispatchQueue.global(qos: .utility).async {
                store(CommittedRaster(image: candidate.image, revision: revision, transform: transform, scale: scale))
            }
            return
        }
        guard document.strokes.contains(where: { !$0.brush.erases }) else { return }
        let items = committedItems()
        DispatchQueue.global(qos: .utility).async {
            store(CommittedRaster(rendering: items, pixelSize: pixelSize, scale: scale, transform: transform,
                                  revision: revision))
        }
    }

    // MARK: - Snapshots (the zoom window's panel)

    /// Draws the committed ink that reaches `bounds` (view points of an image of their own) at `transform`
    /// into an image, on the snapshot queue, and hands it to `completion` on the main queue. One at a time:
    /// the caller waits for each before asking again.
    func renderSnapshot(bounds: CGRect, transform: ViewTransform, completion: @escaping (CGImage?) -> Void) {
        let scale = scale
        let pixels = Self.pixelSize(of: bounds.size, scale: scale)
        let visible = transform.toCanvas(bounds).insetBy(dx: -4, dy: -4)
        // Only the strokes that reach the box. Geometry not cached yet is culled by its points.
        let items: [CommittedRenderer.Item] = document.strokes.compactMap { stroke in
            if let geometry = geometryCache[stroke.id] {
                guard geometry.bounds.intersects(visible) else { return nil }
                return CommittedRenderer.Item(id: stroke.id, brush: stroke.brush, color: stroke.color,
                                              geometry: geometry, stroke: nil)
            }
            guard Self.roughBounds(of: stroke).intersects(visible) else { return nil }
            return CommittedRenderer.Item(id: stroke.id, brush: stroke.brush, color: stroke.color,
                                          geometry: nil, stroke: stroke)
        }
        snapshotQueue.async { [weak self] in
            guard let self else { return }
            if snapshotBitmap.map({ CGSize(width: $0.width, height: $0.height) }) != pixels {
                snapshotBitmap = CommittedRenderer.makeBitmap(pixelSize: pixels, scale: scale)
            }
            var image: CGImage?
            if let ctx = snapshotBitmap {
                CommittedRenderer.render(items, into: ctx, bounds: bounds, transform: transform)
                image = ctx.makeImage()
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    /// Frees the snapshot bitmap (the zoom window closed).
    func releaseSnapshots() {
        snapshotQueue.async { [weak self] in self?.snapshotBitmap = nil }
    }

    /// A stroke's points' bounds grown by its widest nib: never smaller than its ink.
    private static func roughBounds(of stroke: Stroke) -> CGRect {
        guard let first = stroke.points.first?.location else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in stroke.points {
            minX = min(minX, point.location.x)
            maxX = max(maxX, point.location.x)
            minY = min(minY, point.location.y)
            maxY = max(maxY, point.location.y)
        }
        let r = stroke.brush.maxWidth * 2
        return CGRect(x: minX - r, y: minY - r, width: maxX - minX + 2 * r, height: maxY - minY + 2 * r)
    }
}
