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
    @discardableResult
    func fill(_ key: TileKey, region: CGRect?, strokes: [TileStroke], into ctx: CGContext,
              isCancelled: () -> Bool) -> Int {
        draw(rect: key.rect, level: key.level, region: region, strokes: strokes, into: ctx, isCancelled: isCancelled)
    }

    /// `fill` for any part of the page: `rect` (page points) is what `ctx` covers at `level`. Drawing the
    /// whole page this way gives what its tiles show, assembled (the tile tests compare the two).
    @discardableResult
    func draw(rect pageRect: CGRect, level: TileLevel, region: CGRect? = nil, strokes: [TileStroke],
              into ctx: CGContext, isCancelled: () -> Bool = { false }) -> Int {
        let rect = region.map { $0.intersection(pageRect) } ?? pageRect
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        // Two pixels of anti-aliasing at this level, in page points.
        let reach = rect.insetBy(dx: -2 / level.pixelsPerPoint, dy: -2 / level.pixelsPerPoint)
        ctx.saveGState()
        if region != nil {
            ctx.clip(to: rect)
            ctx.clear(rect)
        }
        var drawn = 0
        for stroke in strokes {
            if isCancelled() {
                break
            }
            let clip = stroke.geometry.bounds.insetBy(dx: -2, dy: -2)
            guard clip.intersects(reach) else { continue }
            StrokeRenderer.draw(runs: stroke.geometry.runs, clip: clip.intersection(reach), brush: stroke.brush,
                                color: stroke.color, in: ctx)
            drawn += 1
        }
        ctx.restoreGState()
        return drawn
    }
}

/// Tile bitmaps: premultiplied BGRA like `CommittedRenderer.makeBitmap`, addressed in page points.
enum TileBitmap {
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
/// and only good for the revision it was taken at; any edit drops it. Lossless (LZFSE), about 5 MB for a
/// fitted 5k-stroke page. NOT-106 makes it the persisted cache and keeps it across edits.
struct TileRaster: @unchecked Sendable { // immutable
    /// The page's `CanvasDocument.revision` that the pixels show.
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
