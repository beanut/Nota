import UIKit

/// The live ink layer: the stroke under the Pencil, plus finished strokes still waiting for their
/// background rasterization.
///
/// A single full-screen `draw(_:)` view can't do this job cheaply. UIKit hands `draw(_:)` the whole bounds
/// whatever was invalidated, so every frame re-rasterized the entire in-progress stroke into a full-screen
/// backing store. Per-frame cost grew with stroke length, screen size and zoom-out.
///
/// Instead the view is a grid of small tile layers, and each stroke is split in two:
///  - **Baked**: chunks that are complete and settled. Each is rasterized exactly once, into a per-stroke,
///    per-tile bitmap, with `.copy` so runs replace what's under them exactly as the committed path does.
///  - **Hot**: the last chunk or two plus the provisional tail, re-filled on every redraw.
///
/// A redraw touches only the tiles under the new ink, and in each one blits the baked bitmap and fills the
/// hot runs. That is bounded by tile size and chunk size, not by how long the stroke is.
final class LiveInkView: UIView {
    struct Entry {
        let stroke: LiveStroke
        /// Pixel-eraser preview: paint this (paper) colour, since the live layer can't punch holes.
        let previewFill: CGColor?
    }

    /// Tile edge in view points. 256 pt is 512 px at 2×: about 1 MB per tile.
    static let tileSize: CGFloat = 256

    /// Strokes to show, bottom to top. Pulled at draw time so the view never holds stale state.
    var entries: () -> [Entry] = { [] }
    var paperColor: CGColor = UIColor.white.cgColor {
        didSet { cursorHalo.strokeColor = UIColor(cgColor: paperColor).withAlphaComponent(0.9).cgColor }
    }

    /// Draws the paper and its template into a tile, in view space at the given transform, limited to the
    /// rect. Without it the backdrop is plain `paperColor`.
    var drawPaper: ((CGContext, ViewTransform, CGRect) -> Void)?

    /// The committed image. Multiply ink needs the real backdrop to preview what will be committed.
    var underlay: CGImage? {
        didSet { for tile in tiles.values where tile.drewBackdrop {
            tile.setNeedsDisplay()
        } }
    }

    /// Canvas → view transform the tiles are rasterized at.
    private var bakeTransform = ViewTransform()
    private var scale: CGFloat = 2
    private let tileHost = CALayer()
    private var tiles: [TileKey: Tile] = [:]
    private var rasters: [ObjectIdentifier: [TileKey: BakedTile]] = [:]
    private let cursorHalo = CAShapeLayer()
    private let cursorLine = CAShapeLayer()

    private struct TileKey: Hashable { let col: Int, row: Int }

    /// One stroke's baked ink inside one tile.
    private final class BakedTile {
        var context: CGContext?
        /// For a raster brush (see `requestWax`): the settled chunks' wax on the GPU, the canvas rect
        /// still to redraw, whether a GPU job is out, and whether the GPU failed (then paths are filled).
        var field: WaxRenderer.WaxField?
        var waxPending = CGRect.null
        var waxInFlight = false
        var waxFailed = false
        /// Chunks below this index have been considered for this tile (and drawn if they reach it).
        var bakedThrough = 0
        /// Snapshot of `context`, made on demand and dropped whenever the context is drawn into.
        private var snapshot: CGImage?

        func invalidateImage() {
            snapshot = nil
        }

        var image: CGImage? {
            if snapshot == nil {
                snapshot = context?.makeImage()
            }
            return snapshot
        }
    }

    private final class Tile: CALayer {
        weak var owner: LiveInkView?
        var key = TileKey(col: 0, row: 0)
        var drewBackdrop = false

        override func draw(in ctx: CGContext) {
            owner?.draw(self, in: ctx)
        }

        /// Standalone layers animate `contents` by default; live ink must never cross-fade.
        override func action(forKey _: String) -> CAAction? {
            nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        tileHost.anchorPoint = .zero
        tileHost.actions = ["sublayers": NSNull(), "transform": NSNull()]
        layer.addSublayer(tileHost)
        // The hover cursor sits on paper, which is light in both appearances.
        let onPaper = UITraitCollection(userInterfaceStyle: .light)
        for (shape, width, color) in [(cursorHalo, 2.5, UIColor.white.withAlphaComponent(0.9)),
                                      (cursorLine, 1.0, UIColor.secondaryLabel.resolvedColor(with: onPaper))] {
            shape.fillColor = nil
            shape.lineWidth = width
            shape.strokeColor = color.cgColor
            shape.actions = ["path": NSNull()]
            layer.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        if newScale != scale {
            scale = newScale
            removeAllTiles()
            invalidateAll()
        }
    }

    // MARK: Invalidation

    /// Redraws the tiles under `canvasRect`.
    func invalidate(canvasRect: CGRect) {
        guard prune() else { return }
        markTiles(under: canvasRect)
        requestWax(under: canvasRect)
    }

    /// Call when strokes were added or removed wholesale. Redraws every tile any stroke reaches.
    func invalidateAll() {
        guard prune() else { return }
        for tile in tiles.values {
            tile.setNeedsDisplay()
        }
        for entry in entries() {
            for rect in entry.stroke.pieceBounds {
                markTiles(under: rect)
                requestWax(under: rect)
            }
        }
    }

    private func markTiles(under canvasRect: CGRect) {
        guard let rect = viewRect(under: canvasRect) else { return }
        for key in tileKeys(under: rect) {
            // Only the part of the tile under the new ink: Core Animation keeps the rest of the
            // tile's pixels and clips the redraw to this rect.
            let tile = tile(at: key)
            tile.setNeedsDisplay(rect.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY).intersection(tile.bounds))
        }
    }

    /// The view rect a redraw of `canvasRect` covers, inside the view; nil if none.
    private func viewRect(under canvasRect: CGRect) -> CGRect? {
        guard !canvasRect.isNull else { return nil }
        let rect = bakeTransform.toView(canvasRect).insetBy(dx: -3, dy: -3).intersection(bounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private func tileKeys(under viewRect: CGRect) -> [TileKey] {
        let size = Self.tileSize
        var keys: [TileKey] = []
        for row in Int(viewRect.minY / size) ... Int((viewRect.maxY - 0.001) / size) {
            for col in Int(viewRect.minX / size) ... Int((viewRect.maxX - 0.001) / size) {
                keys.append(TileKey(col: col, row: row))
            }
        }
        return keys
    }

    /// Call after `LiveStroke.refreshPoint` changed already-finalized segments: baked pixels under
    /// `canvasRect` may be stale, so those tiles re-bake from the stroke's first chunk.
    func geometryChanged(of stroke: LiveStroke, fromSegment segment: Int, canvasRect: CGRect) {
        guard !canvasRect.isNull, let baked = rasters[ObjectIdentifier(stroke)] else { return }
        let chunk = max(segment, 0) / LiveStroke.chunkSize
        let rect = bakeTransform.toView(canvasRect).insetBy(dx: -3, dy: -3)
        for (key, tile) in baked where tile.bakedThrough > chunk && frame(of: key).intersects(rect) {
            tile.bakedThrough = 0
            if tile.field != nil {
                // A raster tile keeps showing its wax; its field is rebuilt and the dirty rect redrawn.
                tile.field = nil
                continue
            }
            tile.invalidateImage()
            tile.context?.clear(bakeTransform.toCanvas(frame(of: key)).insetBy(dx: -1, dy: -1))
        }
    }

    /// Pan/zoom in progress: move the existing tiles with the canvas instead of re-rasterizing them.
    func follow(_ transform: ViewTransform) {
        guard transform != bakeTransform else { return }
        guard !tiles.isEmpty else {
            bakeTransform = transform
            return
        }
        let k = transform.scale / bakeTransform.scale
        tileHost.setAffineTransform(CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                                      tx: transform.offset.x - bakeTransform.offset.x * k,
                                                      ty: transform.offset.y - bakeTransform.offset.y * k))
    }

    /// The view transform has settled: rasterize at it from now on.
    func settle(at transform: ViewTransform) {
        guard transform != bakeTransform else { return }
        bakeTransform = transform
        removeAllTiles()
        invalidateAll()
    }

    /// Draws every tile waiting for display now instead of at the next Core Animation commit. The
    /// benchmarks call it after each replayed event to time the frame's live-layer fill with the event.
    func displayPendingTiles() {
        for tile in tiles.values {
            tile.displayIfNeeded()
        }
    }

    /// Bytes held by the tiles' backing stores and the baked per-stroke tile bitmaps.
    var tileMemory: Int {
        let tilePixels = Int((Self.tileSize * scale).rounded(.up))
        let tileBytes = tilePixels * tilePixels * 4
        let bakedCount = rasters.values.reduce(0) { $0 + $1.values.filter { $0.context != nil }.count }
        let fieldBytes = rasters.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + ($1.field?.bytes ?? 0) } }
        return (tiles.count + bakedCount) * tileBytes + fieldBytes
    }

    func setCursor(_ path: CGPath?) {
        cursorHalo.path = path
        cursorLine.path = path
    }

    // MARK: Tiles

    private func frame(of key: TileKey) -> CGRect {
        let size = Self.tileSize
        return CGRect(x: CGFloat(key.col) * size, y: CGFloat(key.row) * size, width: size, height: size)
    }

    private func tile(at key: TileKey) -> Tile {
        if let tile = tiles[key] {
            return tile
        }
        let tile = Tile()
        tile.owner = self
        tile.key = key
        tile.anchorPoint = .zero
        tile.frame = frame(of: key)
        tile.contentsScale = scale
        tiles[key] = tile
        tileHost.addSublayer(tile)
        return tile
    }

    private func removeAllTiles() {
        for tile in tiles.values {
            tile.removeFromSuperlayer()
        }
        tiles.removeAll()
        rasters.removeAll()
        tileHost.setAffineTransform(.identity)
    }

    /// Drops the baked bitmaps of strokes that are gone, and every tile once nothing is left to show.
    /// Returns false when there is nothing to draw.
    private func prune() -> Bool {
        let current = entries()
        if current.isEmpty {
            if !tiles.isEmpty || !rasters.isEmpty {
                removeAllTiles()
            }
            return false
        }
        if !rasters.isEmpty {
            let alive = Set(current.map { ObjectIdentifier($0.stroke) })
            rasters = rasters.filter { alive.contains($0.key) }
        }
        return true
    }

    // MARK: Drawing

    private func makeBakeContext(_ baked: BakedTile, for tileFrame: CGRect) -> CGContext? {
        if let ctx = baked.context {
            return ctx
        }
        let pixels = Int((Self.tileSize * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Same pixel grid and antialiasing as the committed bitmap, addressed in canvas space.
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -tileFrame.minX, y: -tileFrame.minY)
        ctx.concatenate(bakeTransform.affine)
        ctx.setShouldAntialias(true)
        ctx.setBlendMode(.copy)
        baked.context = ctx
        return ctx
    }

    // MARK: Raster brushes

    /// Whether any raster stroke still has GPU work out or waiting: its tiles aren't up to date yet.
    var rasterWorkPending: Bool {
        rasters.values.contains { $0.values.contains { $0.waxInFlight || !$0.waxPending.isNull } }
    }

    /// Asks the GPU for the wax of every raster stroke under `canvasRect`, tile by tile, without waiting.
    ///
    /// A raster stroke's wax at a pixel depends on every stamp over it, so it can't be baked as pixels chunk
    /// by chunk. Its stamps' wax combines by max, though, so each tile keeps the settled chunks' wax on the
    /// GPU (a `WaxField`) and a job adds only the hot stamps over it. The pixels come back on the main queue
    /// into the tile's baked bitmap, which the tile then draws like any baked ink. A touch event only
    /// encodes work, so it never waits for the GPU; the wax shows when the GPU is done, at most about a
    /// frame later. Each tile has at most one job out, and redraws asked for meanwhile wait for it.
    private func requestWax(under canvasRect: CGRect) {
        guard let wax = WaxRenderer.shared, let rect = viewRect(under: canvasRect) else { return }
        for entry in entries() where entry.stroke.stroke.brush.isRaster && entry.previewFill == nil {
            let stroke = entry.stroke
            for key in tileKeys(under: rect) {
                let tileCanvas = bakeTransform.toCanvas(frame(of: key))
                let dirty = canvasRect.intersection(tileCanvas.insetBy(dx: -1, dy: -1))
                guard !dirty.isNull, let baked = waxTile(stroke, key: key, wax: wax) else { continue }
                baked.waxPending = baked.waxPending.union(dirty)
                if !baked.waxInFlight {
                    submitWax(stroke, key: key, baked: baked, wax: wax)
                }
            }
        }
    }

    /// The stroke's state in one tile, its field brought up to date with any newly settled chunks.
    private func waxTile(_ stroke: LiveStroke, key: TileKey, wax: WaxRenderer) -> BakedTile? {
        let id = ObjectIdentifier(stroke)
        let baked = rasters[id]?[key] ?? BakedTile()
        rasters[id, default: [:]][key] = baked
        guard !baked.waxFailed, let ctx = makeBakeContext(baked, for: frame(of: key)) else { return nil }
        if baked.field == nil {
            baked.bakedThrough = 0
            let pixels = CGFloat(ctx.width)
            baked.field = wax.makeField(covering: CGRect(x: 0, y: 0, width: pixels, height: pixels),
                                        toDevice: ctx.userSpaceToDeviceSpaceTransform)
        }
        guard let field = baked.field else {
            baked.waxFailed = true
            return nil
        }
        let limit = stroke.bakeableChunkCount
        if baked.bakedThrough < limit {
            let tileCanvas = bakeTransform.toCanvas(frame(of: key)).insetBy(dx: -1, dy: -1)
            var runs: [StrokeRun] = []
            for chunk in baked.bakedThrough ..< limit where stroke.chunkBounds(chunk).intersects(tileCanvas) {
                runs.append(contentsOf: stroke.chunkRuns(chunk))
            }
            wax.bake(runs, into: field, ink: WaxRenderer.Ink(brush: stroke.stroke.brush, color: stroke.stroke.color))
            baked.bakedThrough = limit
        }
        return baked
    }

    /// Sends the tile's pending redraw to the GPU. When it's done, its pixels replace that part of the
    /// tile's bitmap, the tile redraws, and anything asked for in the meantime goes next.
    private func submitWax(_ stroke: LiveStroke, key: TileKey, baked: BakedTile, wax: WaxRenderer) {
        guard let field = baked.field, !baked.waxPending.isNull else { return }
        let region = baked.waxPending
        baked.waxPending = .null
        let hot = stroke.runs(intersecting: region, fromChunk: baked.bakedThrough)
        let ink = WaxRenderer.Ink(brush: stroke.stroke.brush, color: stroke.stroke.color)
        let id = ObjectIdentifier(stroke)
        baked.waxInFlight = wax.render(runs: hot, over: field, region: region.applying(field.toDevice),
                                       ink: ink) { [weak self, weak stroke, weak baked] images in
            guard let self, let stroke, let baked, rasters[id]?[key] === baked else { return }
            baked.waxInFlight = false
            if let images, let ctx = baked.context {
                WaxRenderer.draw(images, in: ctx, blend: .copy)
                baked.invalidateImage()
            } else {
                baked.waxFailed = true
            }
            markTiles(under: region)
            if !baked.waxFailed, !baked.waxPending.isNull, waxTile(stroke, key: key, wax: wax) != nil {
                submitWax(stroke, key: key, baked: baked, wax: wax)
            }
        }
        if !baked.waxInFlight {
            baked.waxFailed = true
            markTiles(under: region)
        }
    }

    /// Rasterizes any newly settled chunks of `entry` that reach this tile. Each chunk is drawn once.
    /// Not for a raster brush, whose settled chunks go to the GPU instead (`waxTile`): drawing them here would
    /// mark them done, so the tile's field would never get them.
    private func bake(_ entry: Entry, key: TileKey, tileFrame: CGRect, clip: CGRect) -> BakedTile? {
        let stroke = entry.stroke
        let id = ObjectIdentifier(stroke)
        let limit = stroke.bakeableChunkCount
        var baked = rasters[id]?[key]
        guard (baked?.bakedThrough ?? 0) < limit else { return baked }
        if baked == nil {
            let fresh = BakedTile()
            rasters[id, default: [:]][key] = fresh
            baked = fresh
        }
        guard let baked else { return nil }
        for chunk in baked.bakedThrough ..< limit where stroke.chunkBounds(chunk).intersects(clip) {
            guard let ctx = makeBakeContext(baked, for: tileFrame) else { break }
            let brush = stroke.stroke.brush
            let color = stroke.stroke.color
            if brush.usesPattern {
                PencilTexture.prepareContext(ctx, phase: CGPoint(x: bakeTransform.offset.x - tileFrame.minX,
                                                                 y: bakeTransform.offset.y - tileFrame.minY))
            }
            for run in stroke.chunkRuns(chunk) {
                let fill = entry.previewFill ?? StrokeRenderer.fillColor(for: brush, color: color, alpha: run.alpha)
                ctx.setFillColor(fill)
                ctx.addPath(run.path)
                ctx.fillPath(using: .winding)
            }
            baked.invalidateImage()
        }
        baked.bakedThrough = limit
        return baked
    }

    private func draw(_ tile: Tile, in ctx: CGContext) {
        let tileFrame = frame(of: tile.key)
        let tileClip = bakeTransform.toCanvas(tileFrame).insetBy(dx: -1, dy: -1)
        // The redraw is clipped to what was invalidated, so only hot runs reaching that part matter.
        let dirty = ctx.boundingBoxOfClipPath.offsetBy(dx: tileFrame.minX, dy: tileFrame.minY)
        let clip = bakeTransform.toCanvas(dirty).insetBy(dx: -1, dy: -1)

        struct Item {
            let entry: Entry
            let baked: CGImage?
            let hot: [StrokeRun]
        }
        var items: [Item] = []
        for entry in entries() {
            // A raster stroke shows the wax the GPU last sent back (see `requestWax`); without Metal, or if
            // the GPU failed, its paths are filled with the grain pattern instead. Its settled chunks are
            // never baked as paths: they'd land in the bitmap the wax comes back into, as pattern, and be
            // marked done, so the tile's GPU field would miss them and later wax would leave holes there.
            if entry.stroke.stroke.brush.isRaster, entry.previewFill == nil {
                let baked = rasters[ObjectIdentifier(entry.stroke)]?[tile.key]
                if WaxRenderer.shared != nil, baked?.waxFailed != true {
                    if let image = baked?.image {
                        items.append(Item(entry: entry, baked: image, hot: []))
                    }
                } else {
                    let hot = entry.stroke.runs(intersecting: clip)
                    if !hot.isEmpty {
                        items.append(Item(entry: entry, baked: nil, hot: hot))
                    }
                }
                continue
            }
            let baked = bake(entry, key: tile.key, tileFrame: tileFrame, clip: tileClip)
            let hot = entry.stroke.runs(intersecting: clip, fromChunk: entry.stroke.bakeableChunkCount)
            if baked?.image != nil || !hot.isEmpty {
                items.append(Item(entry: entry, baked: baked?.image, hot: hot))
            }
        }

        ctx.translateBy(x: -tileFrame.minX, y: -tileFrame.minY) // now in view space
        ctx.interpolationQuality = .none

        // Multiply needs the real backdrop to preview exactly what will be committed. Paper first so the
        // underlay is an opaque replica; otherwise translucent ink would double up over the committed layer.
        if dirty.contains(tileFrame) {
            tile.drewBackdrop = false
        }
        if let underlay, items.contains(where: { $0.entry.stroke.stroke.brush.blend == .multiply }) {
            tile.drewBackdrop = true
            if let drawPaper {
                drawPaper(ctx, bakeTransform, tileFrame)
            } else {
                ctx.setFillColor(paperColor)
                ctx.fill(tileFrame)
            }
            let size = CGSize(width: CGFloat(underlay.width) / scale, height: CGFloat(underlay.height) / scale)
            drawImage(underlay, in: CGRect(origin: .zero, size: size), ctx: ctx)
        }

        for item in items {
            let stroke = item.entry.stroke.stroke
            let preview = item.entry.previewFill
            let blend: CGBlendMode = preview == nil ? stroke.brush.blend.cgBlendMode : .normal
            // Opaque source-over ink composes the same with or without a group, so skip the offscreen layer.
            let direct = blend == .normal && (preview != nil || item.hot.allSatisfy { $0.alpha >= 0.999 })
            ctx.saveGState()
            ctx.setBlendMode(blend)
            if !direct {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            if let baked = item.baked {
                drawImage(baked, in: tileFrame, ctx: ctx)
            }
            if !item.hot.isEmpty {
                ctx.concatenate(bakeTransform.affine)
                if !direct {
                    ctx.setBlendMode(.copy)
                }
                if stroke.brush.usesPattern {
                    PencilTexture.prepareContext(ctx, phase: CGPoint(x: bakeTransform.offset.x - tileFrame.minX,
                                                                     y: bakeTransform.offset.y - tileFrame.minY))
                }
                for run in item.hot {
                    let fill = preview ?? StrokeRenderer.fillColor(for: stroke.brush, color: stroke.color,
                                                                   alpha: run.alpha)
                    ctx.setFillColor(fill)
                    ctx.addPath(run.path)
                    ctx.fillPath(using: .winding)
                }
            }
            if !direct {
                ctx.endTransparencyLayer()
            }
            ctx.restoreGState()
        }
    }

    /// Layer contexts are top-left origin; `CGContext.draw` expects bottom-left.
    private func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}
