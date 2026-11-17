import Compression
import CoreGraphics
import Foundation

/// One finished stroke as a tile draws it.
struct TileStroke {
    let geometry: StrokeGeometry
    let brush: BrushDescriptor
    let color: RGBA
}

/// Draws strokes into a tile. The committed layer's only backend in M1.5 is `CoreGraphicsTileFiller`
/// (NOT-99); a Metal filler would slot in behind this.
protocol TileFiller: Sendable {
    /// Draws `strokes`, in page order, into `ctx` (a bitmap from `TileBitmap.context(for:)`, addressed in
    /// page points), or only `region` (page points) of it, cleared first. Returns how many strokes reached it.
    /// Asks `isCancelled` between strokes and stops when it says so (the render job was dropped: what's in
    /// `ctx` is then unfinished and thrown away).
    @discardableResult
    func fill(_ key: TileKey, region: CGRect?, strokes: [TileStroke], into ctx: CGContext,
              isCancelled: () -> Bool) -> Int
}

extension TileFiller {
    /// `fill` to the end.
    @discardableResult
    func fill(_ key: TileKey, region: CGRect?, strokes: [TileStroke], into ctx: CGContext) -> Int {
        fill(key, region: region, strokes: strokes, into: ctx, isCancelled: { false })
    }
}

/// Fills tiles with Core Graphics, through `StrokeRenderer.draw`: the same `.copy` run rule, multiply
/// highlighter, pixel eraser, grain and wax as the live layer, so live and committed pixels match.
struct CoreGraphicsTileFiller: TileFiller {
    /// How far past a region its scratch bitmap is clipped, in pixels: the clip's own anti-aliased edge
    /// stays out of the pixels copied back.
    static let regionMargin: CGFloat = 4

    /// With a `region` (NOT-104's dirty rects), only the strokes that reach it are drawn, into a blank tile
    /// clipped to just around the region, and that tile's pixels in the region (grown to whole pixels)
    /// replace `ctx`'s: the tile is what filling it again would give, at the cost of the region.
    ///
    /// Not byte for byte: a clip moves Core Graphics' coverage by a level in a few pixels (about 20 of
    /// the half-million in the dirty-rect tests, never more than one level), so the tests hold refilled
    /// tiles to that. It doesn't build up over edits, as a region's pixels are drawn again from nothing
    /// each time. A stroke drawn through a transparency layer with a grain pattern (several runs of a
    /// textured brush) isn't clipped: its pattern would be laid from the clipped layer's corner, so its
    /// grain would shift inside the region.
    @discardableResult
    func fill(_ key: TileKey, region: CGRect?, strokes: [TileStroke], into ctx: CGContext,
              isCancelled: () -> Bool) -> Int {
        guard let region else {
            return draw(rect: key.rect, level: key.level, strokes: strokes, into: ctx, isCancelled: isCancelled)
        }
        let pixels = TileBitmap.pixelAligned(region, in: key)
        guard !pixels.isNull else { return 0 }
        let query = TileBitmap.strokeQuery(for: pixels, level: key.level)
        let reaching = strokes.filter { $0.geometry.bounds.insetBy(dx: -2, dy: -2).intersects(query) }
        guard let scratch = TileBitmap.context(for: key) else { return 0 }
        let margin = Self.regionMargin / key.level.pixelsPerPoint
        let drawn = draw(rect: key.rect, level: key.level, strokes: reaching, into: scratch,
                         clippedTo: pixels.insetBy(dx: -margin, dy: -margin), isCancelled: isCancelled)
        TileBitmap.copyPixels(of: pixels, in: key, from: scratch, to: ctx)
        return drawn
    }

    /// `fill` for any part of the page: `rect` (page points) is what `ctx` covers at `level`. Drawing the
    /// whole page this way gives what its tiles show, assembled (the tile tests compare the two). With
    /// `clippedTo`, each stroke is clipped to it too (`fill`'s region refills), but for the grain layers.
    @discardableResult
    func draw(rect pageRect: CGRect, level: TileLevel, strokes: [TileStroke],
              into ctx: CGContext, clippedTo region: CGRect? = nil, isCancelled: () -> Bool = { false }) -> Int {
        guard !pageRect.isNull, !pageRect.isEmpty else { return 0 }
        // Two pixels of anti-aliasing at this level, in page points.
        let reach = pageRect.insetBy(dx: -2 / level.pixelsPerPoint, dy: -2 / level.pixelsPerPoint)
        ctx.saveGState()
        var drawn = 0
        for stroke in strokes {
            if isCancelled() {
                break
            }
            let clip = stroke.geometry.bounds.insetBy(dx: -2, dy: -2)
            guard clip.intersects(reach) else { continue }
            let region = region.flatMap { Self.drawsGrainLayer(stroke) ? nil : $0 }
            if let region {
                ctx.saveGState()
                ctx.clip(to: region)
            }
            StrokeRenderer.draw(runs: stroke.geometry.runs, clip: clip.intersection(reach), brush: stroke.brush,
                                color: stroke.color, in: ctx)
            if region != nil {
                ctx.restoreGState()
            }
            drawn += 1
        }
        ctx.restoreGState()
        return drawn
    }

    /// Whether `stroke` fills a grain pattern through a transparency layer (`StrokeRenderer.fillPaths`:
    /// several runs, not all opaque), whose pattern a clip would shift.
    private static func drawsGrainLayer(_ stroke: TileStroke) -> Bool {
        let runs = stroke.geometry.runs
        return stroke.brush.usesPattern && runs.count > 1 && !runs.allSatisfy { $0.alpha >= 0.999 }
    }
}

/// Tile bitmaps: premultiplied BGRA like `CommittedRenderer.makeBitmap`, addressed in page points.
enum TileBitmap {
    /// `rect` (page points) grown to whole pixels of `key`'s tile and cut to the tile: a region whose
    /// edges fall between pixels, so refilling it leaves the pixels around it exactly as they were.
    /// `.null` if it misses the tile; `key.rect` itself if it covers it.
    static func pixelAligned(_ rect: CGRect, in key: TileKey) -> CGRect {
        let ppp = key.level.pixelsPerPoint, tile = key.pixelRect
        let minX = max(tile.minX, (rect.minX * ppp + 1e-6).rounded(.down))
        let minY = max(tile.minY, (rect.minY * ppp + 1e-6).rounded(.down))
        let maxX = min(tile.maxX, (rect.maxX * ppp - 1e-6).rounded(.up))
        let maxY = min(tile.maxY, (rect.maxY * ppp - 1e-6).rounded(.up))
        guard minX < maxX, minY < maxY else { return .null }
        if minX == tile.minX, minY == tile.minY, maxX == tile.maxX, maxY == tile.maxY {
            return key.rect
        }
        return CGRect(x: minX / ppp, y: minY / ppp, width: (maxX - minX) / ppp, height: (maxY - minY) / ppp)
    }

    /// Copies the pixels of `region` (page points on whole pixels of `key`'s tile, `pixelAligned`) from one
    /// tile bitmap of `key` (`context(for:)`) to another, byte for byte.
    static func copyPixels(of region: CGRect, in key: TileKey, from source: CGContext, to target: CGContext) {
        let ppp = key.level.pixelsPerPoint, tile = key.pixelRect
        let side = TileKey.side
        let x0 = max(0, Int((region.minX * ppp - tile.minX).rounded())), x1 = min(side, Int((region.maxX * ppp - tile.minX).rounded()))
        let y0 = max(0, Int((region.minY * ppp - tile.minY).rounded())), y1 = min(side, Int((region.maxY * ppp - tile.minY).rounded()))
        guard x0 < x1, y0 < y1, let from = source.data, let to = target.data, source.width == side, target.width == side,
              source.height == side, target.height == side, source.bitsPerPixel == 32, target.bitsPerPixel == 32
        else { return }
        // Row 0 of a tile bitmap's memory is the tile's top row (page y grows down it).
        let length = (x1 - x0) * 4
        for row in y0 ..< y1 {
            memcpy(to + row * target.bytesPerRow + x0 * 4, from + row * source.bytesPerRow + x0 * 4, length)
        }
    }

    /// The page rect to find the strokes that can put a pixel in `region` at `level` with: a stroke is
    /// drawn within its clip (`CoreGraphicsTileFiller`), and a pixel it touches can stick out a pixel more.
    static func strokeQuery(for region: CGRect, level: TileLevel) -> CGRect {
        let pad = 2 / level.pixelsPerPoint
        return region.insetBy(dx: -pad, dy: -pad)
    }

    /// A blank bitmap for `key`, or one starting from `image` (the tile's pixels so far).
    static func context(for key: TileKey, startingFrom image: CGImage? = nil) -> CGContext? {
        context(pixelRect: key.pixelRect, level: key.level, startingFrom: image)
    }

    /// A bitmap covering `pixelRect` (page pixels at `level`), addressed in page points with the grain
    /// pinned to the page, so any part of the page drawn into one matches the same part of any other.
    static func context(pixelRect: CGRect, level: TileLevel, startingFrom image: CGImage? = nil) -> CGContext? {
        let width = Int(pixelRect.width), height = Int(pixelRect.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CommittedRenderer.bitmapInfo)
        else { return nil }
        if let image {
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) // base space: upright
            ctx.setBlendMode(.normal)
        }
        // Top-left origin in page pixels, then page points.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -pixelRect.minX, y: -pixelRect.minY)
        ctx.scaleBy(x: level.pixelsPerPoint, y: level.pixelsPerPoint)
        ctx.setShouldAntialias(true)
        PencilTexture.pinToPage(ctx)
        return ctx
    }

    /// Draws `tiles` (one level) into `ctx`, a bitmap in view points (`CommittedRenderer.makeBitmap`), with
    /// the page at `transform`. At the tiles' own scale and a pixel-aligned offset, each pixel lands on one.
    static func compose(_ tiles: [(key: TileKey, image: CGImage)], at transform: ViewTransform, in ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        for (key, image) in tiles {
            let rect = transform.toView(key.rect)
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

/// The ink a render job draws from: the page's strokes and index at one moment, the geometry already
/// built, and the strokes to leave out (finished strokes the live layer still shows).
struct InkSnapshot: @unchecked Sendable { // immutable values; geometry paths are never mutated
    let strokes: [Stroke]
    let index: StrokeIndex
    var geometry: [UUID: StrokeGeometry]
    let skipped: Set<UUID>

    /// The page rect to ask the index for so every stroke reaching `rect` (with its clip pad) is found.
    private static func query(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -3, dy: -3)
    }

    /// The strokes reaching `rect` (page points), in page order, with their geometry; strokes without
    /// geometry are left out (`buildGeometry` first).
    func drawable(in rect: CGRect) -> [TileStroke] {
        index.strokes(in: Self.query(rect)).compactMap { position in
            let stroke = strokes[position]
            guard !skipped.contains(stroke.id), let geometry = geometry[stroke.id],
                  geometry.bounds.insetBy(dx: -3, dy: -3).intersects(rect)
            else { return nil }
            return TileStroke(geometry: geometry, brush: stroke.brush, color: stroke.color)
        }
    }

    /// The strokes reaching `rect` (page points) that a tile draws, in page order, geometry or not.
    func candidates(in rect: CGRect) -> [Stroke] {
        index.strokes(in: Self.query(rect)).compactMap { position in
            let stroke = strokes[position]
            return skipped.contains(stroke.id) ? nil : stroke
        }
    }

    /// The strokes reaching `rect` (page points), in page order, with their geometry from `store` (built
    /// there if no job has yet). Nil when `isCancelled` said stop first.
    func drawable(in rect: CGRect, store: GeometryStore, isCancelled: () -> Bool) -> [TileStroke]? {
        let strokes = candidates(in: rect)
        guard let geometry = store.geometry(for: strokes, isCancelled: isCancelled) else { return nil }
        return strokes.compactMap { stroke in
            guard let g = geometry[stroke.id], g.bounds.insetBy(dx: -3, dy: -3).intersects(rect) else { return nil }
            return TileStroke(geometry: g, brush: stroke.brush, color: stroke.color)
        }
    }

    /// Builds, on every core, the geometry of the strokes reaching `rects` that has none, and returns it.
    mutating func buildGeometry(reaching rects: [CGRect]) -> [(UUID, StrokeGeometry)] {
        var positions = Set<Int>()
        for rect in rects {
            positions.formUnion(index.strokes(in: Self.query(rect)))
        }
        let missing = positions.sorted().map { strokes[$0] }
            .filter { geometry[$0.id] == nil && !skipped.contains($0.id) }
        guard !missing.isEmpty else { return [] }
        let built = Array(zip(missing.map(\.id), CommittedRenderer.geometries(for: missing)))
        for (id, g) in built {
            geometry[id] = g
        }
        return built
    }
}

/// Stroke geometry shared by the render jobs of one fill: what the coordinator had cached, plus what the
/// jobs build. A stroke reaching several tiles is built once, by the first job to need it, and the others
/// wait for it. Building is serial within a job (the scheduler, not the job, decides how many cores
/// work); a cancelled job stops between strokes and leaves the rest to whoever needs them.
final class GeometryStore: @unchecked Sendable { // guarded by `condition`
    private let condition = NSCondition()
    private var geometry: [UUID: StrokeGeometry]
    private var building = Set<UUID>()
    private var built: [(UUID, StrokeGeometry)] = []
    /// The owner's geometry generation when the store was made: what's built for a stroke changed since
    /// isn't kept.
    let generation: Int

    init(geometry: [UUID: StrokeGeometry], generation: Int = 0) {
        self.geometry = geometry
        self.generation = generation
    }

    /// The geometry of `strokes`: building the ones nobody has, waiting for the ones another job is
    /// building. Nil if `isCancelled` said stop.
    func geometry(for strokes: [Stroke], isCancelled: () -> Bool) -> [UUID: StrokeGeometry]? {
        while true {
            condition.lock()
            var claimed: [Stroke] = []
            var waiting = false
            for stroke in strokes where geometry[stroke.id] == nil {
                if building.contains(stroke.id) {
                    waiting = true
                } else {
                    building.insert(stroke.id)
                    claimed.append(stroke)
                }
            }
            if claimed.isEmpty {
                defer { condition.unlock() }
                if !waiting {
                    var result: [UUID: StrokeGeometry] = [:]
                    for stroke in strokes {
                        result[stroke.id] = geometry[stroke.id]
                    }
                    return result
                }
                if isCancelled() {
                    return nil
                }
                condition.wait()
                continue
            }
            condition.unlock()
            for (i, stroke) in claimed.enumerated() {
                if isCancelled() {
                    condition.withLock {
                        for rest in claimed[i...] {
                            building.remove(rest.id)
                        }
                        condition.broadcast()
                    }
                    return nil
                }
                let g = StrokeRenderer.geometry(for: stroke)
                condition.withLock {
                    geometry[stroke.id] = g
                    built.append((stroke.id, g))
                    building.remove(stroke.id)
                    condition.broadcast()
                }
            }
        }
    }

    /// What the jobs built since the last call, for the owner's geometry cache.
    func takeBuilt() -> [(UUID, StrokeGeometry)] {
        condition.withLock {
            defer { built = [] }
            return built
        }
    }
}

/// A page's tiles at one level, compressed, so reopening the page puts the same pixels back instead of
/// filling every stroke again (page open under 150 ms). Kept by the document while the page is closed
/// and only good for the ink version it was taken at; any edit drops it. Lossless (LZFSE), about 5 MB for a
/// fitted 5k-stroke page. NOT-106 makes it the persisted cache and keeps it across edits.
struct TileRaster: @unchecked Sendable { // immutable
    /// The page's `CanvasDocument.inkVersion` that the pixels show.
    let revision: Int
    let level: TileLevel
    /// The tiles taken: those covering the page at `level`.
    let cols: ClosedRange<Int>
    let rows: ClosedRange<Int>
    /// Compressed pixels of the tiles with ink; a covered tile missing here is empty.
    private let compressed: [Int: Data]

    private static let bytesPerRow = TileKey.side * 4

    /// Compresses `tiles` (every tile of the page at `level`, nil for empty ones). Slow (a few ms a
    /// tile): run it off the main thread. Nil if a tile isn't laid out like a tile bitmap.
    init?(tiles: [(key: TileKey, image: CGImage?)], revision: Int, level: TileLevel) {
        guard let first = tiles.first else { return nil }
        var cols = first.key.col ... first.key.col, rows = first.key.row ... first.key.row
        var compressed: [Int: Data] = [:]
        let length = Self.bytesPerRow * TileKey.side
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { destination.deallocate() }
        for (key, image) in tiles {
            guard key.level == level else { return nil }
            cols = min(cols.lowerBound, key.col) ... max(cols.upperBound, key.col)
            rows = min(rows.lowerBound, key.row) ... max(rows.upperBound, key.row)
            guard let image else { continue }
            guard image.width == TileKey.side, image.height == TileKey.side, image.bytesPerRow == Self.bytesPerRow,
                  image.bitsPerPixel == 32, image.bitmapInfo.rawValue == CommittedRenderer.bitmapInfo,
                  let bytes = image.dataProvider?.data, CFDataGetLength(bytes) >= length
            else { return nil }
            let size = compression_encode_buffer(destination, length, CFDataGetBytePtr(bytes), length, nil,
                                                 COMPRESSION_LZFSE)
            guard size > 0 else { return nil }
            compressed[Self.slot(key.col, key.row)] = Data(bytes: destination, count: size)
        }
        guard tiles.count == cols.count * rows.count else { return nil }
        self.revision = revision
        self.level = level
        self.cols = cols
        self.rows = rows
        self.compressed = compressed
    }

    private static func slot(_ col: Int, _ row: Int) -> Int {
        row &* 1_000_003 &+ col
    }

    /// The compressed size.
    var byteCount: Int {
        compressed.values.reduce(0) { $0 + $1.count }
    }

    /// Whether this raster holds `key` as the page was at `revision`.
    func holds(_ key: TileKey, revision: Int) -> Bool {
        self.revision == revision && key.level == level && cols.contains(key.col) && rows.contains(key.row)
    }

    /// `key`'s tile, decompressed, or nil if this raster doesn't hold it or it doesn't decode.
    func restore(_ key: TileKey) -> Tile? {
        guard key.level == level, cols.contains(key.col), rows.contains(key.row) else { return nil }
        guard let data = compressed[Self.slot(key.col, key.row)] else {
            return Tile(image: nil, revision: revision)
        }
        let length = Self.bytesPerRow * TileKey.side
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: TileKey.side, height: TileKey.side, bitsPerComponent: 8,
                                  bytesPerRow: Self.bytesPerRow, space: space, bitmapInfo: CommittedRenderer.bitmapInfo),
              let target = ctx.data
        else { return nil }
        let decoded = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(target.assumingMemoryBound(to: UInt8.self), length, base, source.count,
                                             nil, COMPRESSION_LZFSE)
        }
        guard decoded == length, let image = ctx.makeImage() else { return nil }
        return Tile(image: image, revision: revision)
    }
}
