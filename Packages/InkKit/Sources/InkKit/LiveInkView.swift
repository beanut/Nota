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
    var paperColor: CGColor = UIColor.white.cgColor
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
        for (shape, width, color) in [(cursorHalo, 2.5, UIColor.white.withAlphaComponent(0.9)),
                                      (cursorLine, 1.0, UIColor.darkGray)] {
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
            }
        }
    }

    private func markTiles(under canvasRect: CGRect) {
        guard !canvasRect.isNull else { return }
        let rect = bakeTransform.toView(canvasRect).insetBy(dx: -3, dy: -3).intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return }
        let size = Self.tileSize
        for row in Int(rect.minY / size) ... Int((rect.maxY - 0.001) / size) {
            for col in Int(rect.minX / size) ... Int((rect.maxX - 0.001) / size) {
                // Only the part of the tile under the new ink: Core Animation keeps the rest of the
                // tile's pixels and clips the redraw to this rect.
                let tile = tile(at: TileKey(col: col, row: row))
                tile.setNeedsDisplay(rect.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY)
                    .intersection(tile.bounds))
            }
        }
    }

    /// Call after `LiveStroke.refreshPoint` changed already-finalized segments: baked pixels under
    /// `canvasRect` may be stale, so those tiles re-bake from the stroke's first chunk.
    func geometryChanged(of stroke: LiveStroke, fromSegment segment: Int, canvasRect: CGRect) {
        guard !canvasRect.isNull, let baked = rasters[ObjectIdentifier(stroke)] else { return }
        let chunk = max(segment, 0) / LiveStroke.chunkSize
        let rect = bakeTransform.toView(canvasRect).insetBy(dx: -3, dy: -3)
        for (key, tile) in baked where tile.bakedThrough > chunk && frame(of: key).intersects(rect) {
            tile.bakedThrough = 0
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

    /// Rasterizes any newly settled chunks of `entry` that reach this tile. Each chunk is drawn once.
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
            let kind = stroke.stroke.tool
            let color = stroke.stroke.color
            if kind == .pencil {
                PencilTexture.prepareContext(ctx, phase: CGPoint(x: bakeTransform.offset.x - tileFrame.minX,
                                                                 y: bakeTransform.offset.y - tileFrame.minY))
            }
            for run in stroke.chunkRuns(chunk) {
                let fill = entry.previewFill ?? (kind == .pencil
                    ? PencilTexture.fillColor(for: color, alpha: run.alpha)
                    : color.cgColor(alpha: run.alpha))
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
        if let underlay, items.contains(where: { $0.entry.stroke.stroke.tool == .highlighter }) {
            tile.drewBackdrop = true
            ctx.setFillColor(paperColor)
            ctx.fill(tileFrame)
            let size = CGSize(width: CGFloat(underlay.width) / scale, height: CGFloat(underlay.height) / scale)
            drawImage(underlay, in: CGRect(origin: .zero, size: size), ctx: ctx)
        }

        for item in items {
            let stroke = item.entry.stroke.stroke
            let preview = item.entry.previewFill
            let blend: CGBlendMode = preview == nil ? stroke.tool.blendMode : .normal
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
                if stroke.tool == .pencil {
                    PencilTexture.prepareContext(ctx, phase: CGPoint(x: bakeTransform.offset.x - tileFrame.minX,
                                                                     y: bakeTransform.offset.y - tileFrame.minY))
                }
                for run in item.hot {
                    let fill = preview ?? (stroke.tool == .pencil
                        ? PencilTexture.fillColor(for: stroke.color, alpha: run.alpha)
                        : stroke.color.cgColor(alpha: run.alpha))
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
